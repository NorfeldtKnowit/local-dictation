import XCTest
@testable import LocalDictation

/// Model-touching smoke test for the MLX Qwen polish backend. Downloads
/// ~2.5 GB on first run and generates on the GPU, so it runs only when
/// explicitly asked — same manual/nightly tier as `scripts/test-cli.sh`:
///
///     LOCAL_DICTATION_MLX_SMOKE=1 swift test --filter MLXPolisherSmoke
///
/// Running it also warms the shared HubApi cache, so the GUI's first Danish
/// review doesn't pay the download.
final class MLXPolisherSmokeTests: XCTestCase {
    /// Thread-safe partial capture (onPartial fires from the generation task).
    private final class PartialBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _last = ""
        private var _count = 0
        func record(_ text: String) { lock.lock(); _last = text; _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
        var last: String { lock.lock(); defer { lock.unlock() }; return _last }
    }

    func testDanishTerseRewriteStreamsAndPassesGuardrails() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCAL_DICTATION_MLX_SMOKE"] == "1",
            "set LOCAL_DICTATION_MLX_SMOKE=1 to run the model-touching MLX smoke test")

        let polisher = MLXPolisher()
        // Warm outside polish() so the one-time download isn't judged against
        // the 30 s polish ceiling.
        await polisher.warmUp()

        // Restart-heavy real-shaped Danish dictation — the case this backend
        // exists for (Apple's FM is English-only in practice).
        let raw = "Det, der forvirrer mig, er, det, der forvirrer mig, er mere bare, "
                + "at fra jeg trykker på knappen, så går der lidt tid, og så siger den en lyd."

        let partials = PartialBox()
        let result = await polisher.polish(raw, style: .terse) { partials.record($0) }

        // A decline here means load/generation/guardrails failed — exactly
        // what this smoke test exists to catch before a deploy.
        XCTAssertNotNil(result, "MLX polish declined on a clean Danish transcript")
        XCTAssertGreaterThan(partials.count, 0, "no streaming partials arrived")
        if let result {
            XCTAssertLessThan(result.count, raw.count,
                              "terse rewrite should condense a restart-heavy transcript")
            print("MLX smoke — raw:      \(raw)")
            print("MLX smoke — terse:    \(result)")
            print("MLX smoke — partials: \(partials.count)")
        }
    }
}
