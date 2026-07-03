import XCTest
@testable import LocalDictation

// MARK: - Fakes (no models, no downloads)

/// A `TranscriptionEngine` that records how it was called and returns a canned
/// string. Because it's an actor, tests read its counters/captures with `await`.
private actor FakeEngine: TranscriptionEngine {
    nonisolated let kind: EngineKind
    private let output: String
    private var warmed: Bool

    private(set) var warmUpCount = 0
    private(set) var transcribeCount = 0
    private(set) var lastLanguage: String?
    private(set) var lastSampleCount = 0

    init(kind: EngineKind, output: String, startWarm: Bool = false) {
        self.kind = kind
        self.output = output
        self.warmed = startWarm
    }

    var isWarmedUp: Bool { warmed }

    func warmUp() async throws {
        warmUpCount += 1
        warmed = true
    }

    func transcribe(samples: [Float], language: String?) async throws -> String {
        transcribeCount += 1
        lastLanguage = language
        lastSampleCount = samples.count
        return output
    }
}

/// A `GateProviding` fake that returns one preset outcome for every call.
private struct FakeGate: GateProviding {
    let outcome: SpeechGate.Outcome
    func warmUp() async {}
    func evaluate(_ samples: [Float]) async -> SpeechGate.Outcome { outcome }
}

/// Thread-safe recorder for the `@Sendable` cold-load callback (which is a
/// synchronous closure, so it can't `await` into an actor).
private final class ColdLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _kinds: [EngineKind] = []
    func record(_ kind: EngineKind) { lock.lock(); _kinds.append(kind); lock.unlock() }
    var kinds: [EngineKind] { lock.lock(); defer { lock.unlock() }; return _kinds }
}

// MARK: - Tests

final class DictationPipelineTests: XCTestCase {
    /// A comfortably-passing speech buffer (used when the gate decision is faked).
    private let passingAudio = [Float](repeating: 0.1, count: 16_000)

    private func makePipeline(
        parakeet: FakeEngine,
        whisper: FakeEngine,
        gate: FakeGate
    ) -> DictationPipeline {
        DictationPipeline(parakeet: parakeet, whisper: whisper, gate: gate)
    }

    func testSilenceNeverCallsEngine() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "should not run", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .silence, audio: []))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false)

        XCTAssertEqual(out.gate, .silence)
        XCTAssertEqual(out.text, "")
        XCTAssertFalse(out.filtered)
        XCTAssertEqual(out.inferenceSeconds, 0)
        let pCount = await parakeet.transcribeCount
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(pCount, 0)
        XCTAssertEqual(wCount, 0)
    }

    func testTooShortSkipsVad() async throws {
        // A `.tooShort` gate decision must short-circuit exactly like silence:
        // empty text, no engine touched.
        let parakeet = FakeEngine(kind: .parakeet, output: "x", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "x", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .tooShort, audio: []))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: [0, 0, 0], language: "auto", accuracyMode: false)

        XCTAssertEqual(out.gate, .tooShort)
        XCTAssertEqual(out.text, "")
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 0)
    }

    func testPassRoutesToConfiguredEngine() async throws {
        // Danish + accuracy off → Parakeet. Distinct outputs prove which ran.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false)

        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertEqual(out.text, "parakeet text")
        XCTAssertEqual(out.gate, .pass)
        let pCount = await parakeet.transcribeCount
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(pCount, 1)
        XCTAssertEqual(wCount, 0)
        // "da" is a real pin, so the engine gets it as a hint (not nil).
        let hint = await parakeet.lastLanguage
        XCTAssertEqual(hint, "da")
    }

    func testForcedEngineBypassesRouter() async throws {
        // "da" would route to Parakeet, but --engine whisper forces Whisper.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(
            samples: passingAudio, language: "da", accuracyMode: false, forcedEngine: .whisper)

        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.text, "whisper text")
        let pCount = await parakeet.transcribeCount
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(pCount, 0)
        XCTAssertEqual(wCount, 1)
    }

    func testColdLoadCallbackFiresOncePerEngine() async throws {
        // Parakeet starts cold: the first process fires the callback, warms it,
        // and a second process (now warm) must NOT fire again.
        let parakeet = FakeEngine(kind: .parakeet, output: "ok", startWarm: false)
        let whisper = FakeEngine(kind: .whisper, output: "ok", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)
        let recorder = ColdLoadRecorder()

        _ = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false,
                                       onColdLoad: { recorder.record($0) })
        _ = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false,
                                       onColdLoad: { recorder.record($0) })

        XCTAssertEqual(recorder.kinds, [.parakeet])
        let warmUps = await parakeet.warmUpCount
        XCTAssertEqual(warmUps, 2)   // warmUp called both times, but idempotent inside
    }

    func testHallucinationFilteredOutcome() async throws {
        // ASR emits a known silence-ghost phrase; the filter must suppress it and
        // flag `filtered` so the caller can tell "ghost dropped" from "real silence".
        let parakeet = FakeEngine(kind: .parakeet, output: "thanks for watching", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false)

        XCTAssertEqual(out.text, "")
        XCTAssertTrue(out.filtered)
        XCTAssertEqual(out.gate, .pass)
        XCTAssertEqual(out.engine, .parakeet)
    }

    func testAccuracyModeOverridesLanguage() async throws {
        // "da" would route to Parakeet, but Accuracy Mode forces Whisper for all.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: true)

        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.text, "whisper text")
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 1)
    }

    func testVadUnavailableStillTranscribes() async throws {
        // Fail-open: when VAD is unavailable the raw buffer is transcribed anyway.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .vadUnavailable, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false)

        XCTAssertEqual(out.gate, .vadUnavailable)
        XCTAssertEqual(out.text, "parakeet text")
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 1)
    }
}
