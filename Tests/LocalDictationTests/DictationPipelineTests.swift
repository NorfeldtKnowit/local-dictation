import XCTest
@testable import LocalDictation

// MARK: - Fakes (no models, no downloads)

/// A `TranscriptionEngine` that records how it was called and returns a canned
/// string. Because it's an actor, tests read its counters/captures with `await`.
/// `outputsBySampleCount` lets one fake answer differently per input buffer —
/// how the code-switch tests distinguish whole-buffer vs per-segment calls.
private actor FakeEngine: TranscriptionEngine {
    nonisolated let kind: EngineKind
    private let output: String
    private let outputsBySampleCount: [Int: String]
    private let confidence: Double?
    private let transcribeError: Error?
    private var warmed: Bool

    private(set) var warmUpCount = 0
    private(set) var transcribeCount = 0
    private(set) var lastLanguage: String?
    private(set) var lastSampleCount = 0

    init(kind: EngineKind, output: String, startWarm: Bool = false,
         confidence: Double? = nil, transcribeError: Error? = nil,
         outputsBySampleCount: [Int: String] = [:]) {
        self.kind = kind
        self.output = output
        self.warmed = startWarm
        self.confidence = confidence
        self.transcribeError = transcribeError
        self.outputsBySampleCount = outputsBySampleCount
    }

    var isWarmedUp: Bool { warmed }

    func warmUp() async throws {
        warmUpCount += 1
        warmed = true
    }

    func transcribe(samples: [Float], language: String?) async throws -> EngineResult {
        transcribeCount += 1
        lastLanguage = language
        lastSampleCount = samples.count
        if let transcribeError { throw transcribeError }
        return EngineResult(text: outputsBySampleCount[samples.count] ?? output,
                            confidence: confidence)
    }
}

/// A `GateProviding` fake that returns one preset outcome for every call.
private struct FakeGate: GateProviding {
    let outcome: SpeechGate.Outcome
    func warmUp() async {}
    func evaluate(_ samples: [Float]) async -> SpeechGate.Outcome { outcome }
}

/// A `TranscriptPolishing` fake: canned result (nil == decline) + call capture.
private actor FakePolisher: TranscriptPolishing {
    private let result: String?
    private(set) var polishCount = 0
    private(set) var lastInput: String?
    private(set) var lastStyle: PolishStyle?

    init(result: String?) { self.result = result }

    func warmUp() async {}

    func polish(_ text: String, style: PolishStyle,
                onPartial: (@Sendable (String) -> Void)?) async -> String? {
        polishCount += 1
        lastInput = text
        lastStyle = style
        // Streaming fake: one partial (half the result) before the final, so
        // the review-path test can assert partials flow through.
        if let onPartial, let result {
            onPartial(String(result.prefix(result.count / 2)))
        }
        return result
    }
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

    // Real-shaped transcripts for the language-rescue tests. The garbled one is
    // (close to) Parakeet's actual high-confidence output on real Danish audio;
    // it must still LID as Danish for the rescue to fire.
    private let garbledDanish = "Lad os lave en komet omskrivning af foreningen, og så lader os starte forfar."
    private let cleanEnglish = "Let us do a complete rewrite of the branch, and then we start over right away."

    private func makePipeline(
        parakeet: FakeEngine,
        whisper: FakeEngine,
        gate: FakeGate,
        polisher: FakePolisher? = nil
    ) -> DictationPipeline {
        DictationPipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)
    }

    func testSilenceNeverCallsEngine() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "should not run", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .silence, audio: []))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.gate, .silence)
        XCTAssertEqual(out.text, "")
        XCTAssertNil(out.engine)   // no ASR ran — not a placeholder engine
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
        XCTAssertNil(out.engine)
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 0)
    }

    func testPassRoutesToConfiguredEngine() async throws {
        // Swedish + accuracy off → Parakeet. Distinct outputs prove which ran.
        // (Danish, though in Parakeet's set, is whisper-preferred — see below.)
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertEqual(out.text, "parakeet text")
        XCTAssertEqual(out.gate, .pass)
        let pCount = await parakeet.transcribeCount
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(pCount, 1)
        XCTAssertEqual(wCount, 0)
        // "sv" is a real pin, so the engine gets it as a hint (not nil).
        let hint = await parakeet.lastLanguage
        XCTAssertEqual(hint, "sv")
    }

    func testPinnedDanishRoutesWhisper() async throws {
        // Danish is whisper-preferred: the pin routes straight to Whisper with
        // the language forced — no Parakeet call, no rescue bookkeeping.
        let parakeet = FakeEngine(kind: .parakeet, output: "should not run", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "korrekt dansk", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "da", accuracyMode: false)

        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.text, "korrekt dansk")
        XCTAssertNil(out.rescue)
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 0)
        let wLang = await whisper.lastLanguage
        XCTAssertEqual(wLang, "da")
    }

    func testForcedEngineBypassesRouter() async throws {
        // "sv" would route to Parakeet, but --engine whisper forces Whisper.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(
            samples: passingAudio, language: "sv", accuracyMode: false, forcedEngine: .whisper)

        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.text, "whisper text")
        let pCount = await parakeet.transcribeCount
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(pCount, 0)
        XCTAssertEqual(wCount, 1)
    }

    func testPrepareEngineColdLoadCallbackFiresOncePerEngine() async throws {
        // Parakeet starts cold: the first prepareEngine fires the callback and
        // warms it; a second prepareEngine (now warm) must NOT fire again.
        let parakeet = FakeEngine(kind: .parakeet, output: "ok", startWarm: false)
        let whisper = FakeEngine(kind: .whisper, output: "ok", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)
        let recorder = ColdLoadRecorder()

        let first = try await pipeline.prepareEngine(language: "sv", accuracyMode: false,
                                                     onColdLoad: { recorder.record($0) })
        let second = try await pipeline.prepareEngine(language: "sv", accuracyMode: false,
                                                      onColdLoad: { recorder.record($0) })

        XCTAssertEqual(first, .parakeet)
        XCTAssertEqual(second, .parakeet)
        XCTAssertEqual(recorder.kinds, [.parakeet])
        let warmUps = await parakeet.warmUpCount
        XCTAssertEqual(warmUps, 2)   // warmUp called both times, but idempotent inside
    }

    func testPrepareEngineHonorsForcedEngineAndAccuracy() async throws {
        // "sv" would route to Parakeet, but a forced engine / Accuracy Mode must
        // warm Whisper only — a Whisper CLI run must not require Parakeet models.
        let parakeet = FakeEngine(kind: .parakeet, output: "ok", startWarm: false)
        let whisper = FakeEngine(kind: .whisper, output: "ok", startWarm: false)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let forced = try await pipeline.prepareEngine(language: "sv", accuracyMode: false,
                                                      forcedEngine: .whisper)
        XCTAssertEqual(forced, .whisper)
        let accuracy = try await pipeline.prepareEngine(language: "sv", accuracyMode: true)
        XCTAssertEqual(accuracy, .whisper)

        let pWarmUps = await parakeet.warmUpCount
        let wWarmUps = await whisper.warmUpCount
        XCTAssertEqual(pWarmUps, 0)
        XCTAssertEqual(wWarmUps, 2)
    }

    func testPrepareEnginePinnedDanishWarmsWhisper() async throws {
        // The GUI warms the routed engine before dictation; a Danish pin must
        // warm Whisper (its new route), not Parakeet.
        let parakeet = FakeEngine(kind: .parakeet, output: "ok", startWarm: false)
        let whisper = FakeEngine(kind: .whisper, output: "ok", startWarm: false)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let kind = try await pipeline.prepareEngine(language: "da", accuracyMode: false)

        XCTAssertEqual(kind, .whisper)
        let wWarmUps = await whisper.warmUpCount
        XCTAssertEqual(wWarmUps, 1)
    }

    func testProcessStillWarmsLazilyAsSafetyNet() async throws {
        // Callers are expected to prepareEngine first, but process must keep its
        // internal idempotent warm-up so a direct call on a cold engine still works.
        let parakeet = FakeEngine(kind: .parakeet, output: "ok", startWarm: false)
        let whisper = FakeEngine(kind: .whisper, output: "ok", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)
        let recorder = ColdLoadRecorder()

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false,
                                             onColdLoad: { recorder.record($0) })

        XCTAssertEqual(out.text, "ok")
        XCTAssertEqual(recorder.kinds, [.parakeet])
        let warmUps = await parakeet.warmUpCount
        XCTAssertEqual(warmUps, 1)
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
        // "sv" would route to Parakeet, but Accuracy Mode forces Whisper for all.
        let parakeet = FakeEngine(kind: .parakeet, output: "parakeet text", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "whisper text", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: true)

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

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.gate, .vadUnavailable)
        XCTAssertEqual(out.text, "parakeet text")
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 1)
    }

    // MARK: - Confidence rescue

    func testLowConfidenceRescuesToWhisper() async throws {
        // Parakeet below the rescue threshold (real-world case: Danish decoded
        // as English at conf 0.59) must be re-run through Whisper, whose text
        // and identity the outcome then carries, with the language hint intact.
        let parakeet = FakeEngine(kind: .parakeet, output: "wrong english", startWarm: true, confidence: 0.59)
        let whisper = FakeEngine(kind: .whisper, output: "rigtig svensk", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.text, "rigtig svensk")
        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.rescue, .confidence)
        XCTAssertTrue(out.rescued)
        let wLang = await whisper.lastLanguage
        XCTAssertEqual(wLang, "sv")
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 1)
    }

    func testHighConfidenceStaysOnParakeet() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "fin svensk text", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.text, "fin svensk text")
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertFalse(out.rescued)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    func testRescueWarmsColdWhisperAndFiresColdLoadCallback() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "iffy", startWarm: true, confidence: 0.10)
        let whisper = FakeEngine(kind: .whisper, output: "rescued", startWarm: false)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)
        let recorder = ColdLoadRecorder()

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false,
                                             onColdLoad: { recorder.record($0) })

        XCTAssertEqual(out.text, "rescued")
        XCTAssertEqual(out.rescue, .confidence)
        XCTAssertEqual(recorder.kinds, [.whisper])
        let wWarm = await whisper.warmUpCount
        XCTAssertGreaterThanOrEqual(wWarm, 1)
    }

    func testRescueFailureKeepsParakeetText() async throws {
        // A dubious transcript beats a lost utterance: if the Whisper re-run
        // throws, the outcome falls back to Parakeet's text, un-rescued.
        struct Boom: Error {}
        let parakeet = FakeEngine(kind: .parakeet, output: "dubious but present", startWarm: true, confidence: 0.30)
        let whisper = FakeEngine(kind: .whisper, output: "never returned", startWarm: true, transcribeError: Boom())
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.text, "dubious but present")
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertFalse(out.rescued)
    }

    func testForcedEngineNeverRescues() async throws {
        // An explicit --engine parakeet is a user decision; low confidence must
        // not silently substitute Whisper output.
        let parakeet = FakeEngine(kind: .parakeet, output: "forced parakeet", startWarm: true, confidence: 0.10)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false,
                                             forcedEngine: .parakeet)

        XCTAssertEqual(out.text, "forced parakeet")
        XCTAssertFalse(out.rescued)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    func testNilConfidenceNeverConfidenceRescues() async throws {
        // Engines that report no confidence (Whisper, or a future engine) must
        // never trigger the confidence-rescue path by accident.
        let parakeet = FakeEngine(kind: .parakeet, output: "no confidence signal", startWarm: true, confidence: nil)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.text, "no confidence signal")
        XCTAssertFalse(out.rescued)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    // MARK: - Language rescue (text LID)

    func testAutoDanishTranscriptRescuesThroughWhisper() async throws {
        // The core Danish-quality fix: Parakeet is HIGH confidence but its
        // transcript reads as Danish → the whole buffer re-runs through
        // Whisper pinned to "da" (which Whisper honours, unlike Parakeet).
        let parakeet = FakeEngine(kind: .parakeet, output: garbledDanish, startWarm: true, confidence: 0.96)
        let whisper = FakeEngine(kind: .whisper, output: "korrekt dansk tekst", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, "korrekt dansk tekst")
        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.rescue, .language)
        let wLang = await whisper.lastLanguage
        XCTAssertEqual(wLang, "da")
        let wSamples = await whisper.lastSampleCount
        XCTAssertEqual(wSamples, passingAudio.count)   // whole buffer, not a segment
    }

    func testAutoEnglishTranscriptStaysOnParakeet() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: cleanEnglish, startWarm: true, confidence: 0.93)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, cleanEnglish)
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    func testLanguageRescueFailureKeepsParakeetText() async throws {
        struct Boom: Error {}
        let parakeet = FakeEngine(kind: .parakeet, output: garbledDanish, startWarm: true, confidence: 0.96)
        let whisper = FakeEngine(kind: .whisper, output: "never returned", startWarm: true, transcribeError: Boom())
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, garbledDanish)
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
    }

    func testPinnedLanguageNeverTextRescues() async throws {
        // A pinned Parakeet language is the user's explicit choice: even if the
        // transcript reads as Danish, no LID rescue may fire outside auto mode.
        let parakeet = FakeEngine(kind: .parakeet, output: garbledDanish, startWarm: true, confidence: 0.96)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "sv", accuracyMode: false)

        XCTAssertEqual(out.text, garbledDanish)
        XCTAssertNil(out.rescue)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    // MARK: - Code-switch rescue

    /// Two VAD segments with distinct sizes so the fakes can tell them apart:
    /// 16 k samples of "Danish" speech, then 24 k of "English".
    private var danishSegment: [Float] { [Float](repeating: 0.1, count: 16_000) }
    private var englishSegment: [Float] { [Float](repeating: 0.1, count: 24_000) }
    private var mixedWhole: [Float] { danishSegment + englishSegment }   // 40 k

    private var mixedTranscript: String { garbledDanish + " " + cleanEnglish }

    func testCodeSwitchRescuesDanishRunThroughWhisper() async throws {
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 0.83,
            outputsBySampleCount: [
                40_000: mixedTranscript,       // whole-buffer pass detects the mix
                16_000: garbledDanish,         // segment 1 LIDs as Danish
                24_000: cleanEnglish,          // segment 2 LIDs as English
            ])
        let whisper = FakeEngine(kind: .whisper, output: "Ren dansk sætning her.", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: mixedWhole,
                                           segments: [danishSegment, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: mixedWhole, language: "auto", accuracyMode: false)

        // Danish segment re-done by Whisper (pinned da), English kept from Parakeet.
        XCTAssertEqual(out.text, "Ren dansk sætning her. " + cleanEnglish)
        XCTAssertEqual(out.engine, .whisper)
        XCTAssertEqual(out.rescue, .codeSwitch)
        let wLang = await whisper.lastLanguage
        XCTAssertEqual(wLang, "da")
        let wSamples = await whisper.lastSampleCount
        XCTAssertEqual(wSamples, 16_000)      // only the Danish run, not the whole buffer
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 3)             // whole + 2 segments
    }

    func testCodeSwitchMergesConsecutiveDanishSegmentsIntoOneWhisperCall() async throws {
        // da(16k) + da(8k) + en(24k): the two Danish segments must merge into ONE
        // 24 k Whisper call (context preserved, one model invocation).
        let shortDanish = [Float](repeating: 0.1, count: 8_000)
        let whole = danishSegment + shortDanish + englishSegment   // 48 k
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 0.83,
            outputsBySampleCount: [
                48_000: mixedTranscript,
                16_000: garbledDanish,
                8_000: "Og så en dansk sætning mere lige her.",
                24_000: cleanEnglish,
            ])
        let whisper = FakeEngine(kind: .whisper, output: "Samlet dansk tekst.", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: whole,
                                           segments: [danishSegment, shortDanish, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: whole, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, "Samlet dansk tekst. " + cleanEnglish)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 1)
        let wSamples = await whisper.lastSampleCount
        XCTAssertEqual(wSamples, 24_000)      // 16 k + 8 k merged
    }

    func testCodeSwitchWithNoDanishSegmentsKeepsWholeTranscript() async throws {
        // Whole-buffer text looked mixed, but per-segment LID found no Danish
        // segment: keep the original whole-buffer transcript (re-segmented
        // Parakeet text would only add join artifacts), report no rescue.
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 0.83,
            outputsBySampleCount: [
                40_000: mixedTranscript,
                16_000: cleanEnglish,
                24_000: "And this segment is also clearly in English throughout.",
            ])
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: mixedWhole,
                                           segments: [danishSegment, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: mixedWhole, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, mixedTranscript)
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }

    func testCodeSwitchFailureKeepsWholeTranscript() async throws {
        struct Boom: Error {}
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 0.83,
            outputsBySampleCount: [
                40_000: mixedTranscript,
                16_000: garbledDanish,
                24_000: cleanEnglish,
            ])
        let whisper = FakeEngine(kind: .whisper, output: "never returned", startWarm: true, transcribeError: Boom())
        let gate = FakeGate(outcome: .init(decision: .pass, audio: mixedWhole,
                                           segments: [danishSegment, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: mixedWhole, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, mixedTranscript)
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
    }

    func testSegmentScanCatchesDanishSentenceParakeetDropped() async throws {
        // Observed live: on a Danish+English clip Parakeet emitted ONLY the
        // English sentence at confidence 1.00, so the whole-buffer transcript
        // shows no mixing at all. With 2+ gate segments the pipeline must
        // spend a per-segment scan anyway and recover the dropped Danish.
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 1.00,
            outputsBySampleCount: [
                40_000: cleanEnglish,          // whole buffer: Danish sentence silently dropped
                16_000: garbledDanish,         // per-segment it CAN'T drop it
                24_000: cleanEnglish,
            ])
        let whisper = FakeEngine(kind: .whisper, output: "Ren dansk sætning her.", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: mixedWhole,
                                           segments: [danishSegment, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: mixedWhole, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, "Ren dansk sætning her. " + cleanEnglish)
        XCTAssertEqual(out.rescue, .codeSwitch)
        let wLang = await whisper.lastLanguage
        XCTAssertEqual(wLang, "da")
    }

    func testPureEnglishMultiSegmentStaysOnParakeet() async throws {
        // The segment scan must be a no-op for ordinary multi-sentence English
        // dictation: scan runs (cheap), finds nothing preferred, keeps the
        // whole-buffer transcript, and never touches Whisper.
        let englishTwo = "And this segment is also clearly in English throughout."
        let parakeet = FakeEngine(
            kind: .parakeet, output: "unused", startWarm: true, confidence: 0.95,
            outputsBySampleCount: [
                40_000: cleanEnglish + " " + englishTwo,
                16_000: cleanEnglish,
                24_000: englishTwo,
            ])
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: mixedWhole,
                                           segments: [danishSegment, englishSegment]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: mixedWhole, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.text, cleanEnglish + " " + englishTwo)
        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
        let pCount = await parakeet.transcribeCount
        XCTAssertEqual(pCount, 3)             // whole + 2-segment scan
    }

    // MARK: - Polish (layer 4)

    func testPolishRewriteUsedWhenEnabled() async throws {
        let asrText = "So basically I want to refactor the parser module."
        let parakeet = FakeEngine(kind: .parakeet, output: asrText, startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: "I want to refactor the parser module.")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                             polish: true)

        XCTAssertEqual(out.text, "I want to refactor the parser module.")
        XCTAssertTrue(out.polished)
        // The polisher must see the FILTERED text (layers 1-3 already applied).
        let input = await polisher.lastInput
        XCTAssertEqual(input, asrText)
    }

    func testOutcomeCarriesPrePolishText() async throws {
        // The review overlay needs BOTH candidates: asrText must hold the
        // filtered layers-1-3 text even when polish rewrote `text`.
        let asrText = "So basically I want to refactor the parser module."
        let parakeet = FakeEngine(kind: .parakeet, output: asrText, startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: "I want to refactor the parser module.")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                             polish: true)

        XCTAssertTrue(out.polished)
        XCTAssertEqual(out.asrText, asrText)
        XCTAssertEqual(out.text, "I want to refactor the parser module.")
    }

    func testPolishStyleDefaultsToStandardAndPlumbsTerse() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "some plain dictated text here", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: "some plain dictated text")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        _ = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                       polish: true)
        var style = await polisher.lastStyle
        XCTAssertEqual(style, .standard)

        _ = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                       polish: true, polishStyle: .terse)
        style = await polisher.lastStyle
        XCTAssertEqual(style, .terse)
    }

    func testPolishOffByDefault() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "plain text output here", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: "should never be used")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false)

        XCTAssertEqual(out.text, "plain text output here")
        XCTAssertFalse(out.polished)
        let count = await polisher.polishCount
        XCTAssertEqual(count, 0)
    }

    func testPolishDeclineKeepsFilteredText() async throws {
        // nil from the polisher (unavailable / rejected / timeout) must keep
        // the filtered ASR text and report polished=false — never a drop.
        let parakeet = FakeEngine(kind: .parakeet, output: "keep me exactly as is", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: nil)
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                             polish: true)

        XCTAssertEqual(out.text, "keep me exactly as is")
        XCTAssertFalse(out.polished)
        let count = await polisher.polishCount
        XCTAssertEqual(count, 1)
    }

    func testGatedUtteranceNeverPolished() async throws {
        let parakeet = FakeEngine(kind: .parakeet, output: "unused", startWarm: true)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .silence, audio: []))
        let polisher = FakePolisher(result: "should never be used")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false,
                                             polish: true)

        XCTAssertEqual(out.text, "")
        XCTAssertFalse(out.polished)
        let count = await polisher.polishCount
        XCTAssertEqual(count, 0)
    }

    func testFilterSuppressedUtteranceNeverPolished() async throws {
        // A hallucination-filtered ghost is empty text: polish must not run on
        // it (nothing to refine, and the model could invent content from "").
        let parakeet = FakeEngine(kind: .parakeet, output: "thanks for watching", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let polisher = FakePolisher(result: "should never be used")
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate, polisher: polisher)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                             polish: true)

        XCTAssertEqual(out.text, "")
        XCTAssertTrue(out.filtered)
        XCTAssertFalse(out.polished)
        let count = await polisher.polishCount
        XCTAssertEqual(count, 0)
    }

    func testPolishWithoutPolisherIsANoOp() async throws {
        // A pipeline built without a polisher (CLI fakes, future fronts) must
        // treat polish=true as a silent no-op, not a crash or a drop.
        let parakeet = FakeEngine(kind: .parakeet, output: "still the parakeet text", startWarm: true, confidence: 0.95)
        let whisper = FakeEngine(kind: .whisper, output: "unused", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "en", accuracyMode: false,
                                             polish: true)

        XCTAssertEqual(out.text, "still the parakeet text")
        XCTAssertFalse(out.polished)
    }

    func testMixedTranscriptWithoutSegmentBoundariesKeepsParakeet() async throws {
        // Mixed text but the gate produced no cut points (e.g. VAD merged all
        // speech into one region) and Danish is not the majority: keeping
        // Parakeet's own code-switched text is the lesser evil.
        let parakeet = FakeEngine(
            kind: .parakeet, output: garbledDanish + " " + cleanEnglish + " " + cleanEnglish,
            startWarm: true, confidence: 0.85)
        let whisper = FakeEngine(kind: .whisper, output: "should not run", startWarm: true)
        let gate = FakeGate(outcome: .init(decision: .pass, audio: passingAudio,
                                           segments: [passingAudio]))
        let pipeline = makePipeline(parakeet: parakeet, whisper: whisper, gate: gate)

        let out = try await pipeline.process(samples: passingAudio, language: "auto", accuracyMode: false)

        XCTAssertEqual(out.engine, .parakeet)
        XCTAssertNil(out.rescue)
        let wCount = await whisper.transcribeCount
        XCTAssertEqual(wCount, 0)
    }
}
