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
        let result = await polisher.polish(raw, template: .terse) { partials.record($0) }

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

    /// English stylistic restyle on Qwen — the case that motivated routing
    /// stylistic templates to MLX (Apple's FM neutralises/echoes bold styles).
    /// Verifies Qwen produces a genuinely DIFFERENT rewrite for GenZ, Corporate
    /// and Marketing rather than echoing the input.
    func testEnglishStylisticRestylesActuallyChangeTheText() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCAL_DICTATION_MLX_SMOKE"] == "1",
            "set LOCAL_DICTATION_MLX_SMOKE=1 to run the model-touching MLX smoke test")

        let polisher = MLXPolisher()
        await polisher.warmUp()

        let raw = "Let's circle back on this one and let's double down on the quantum "
                + "computer LLM model for the third quarter or Q3."
        let styles: [(String, GuardrailProfile)] = [("GenZ", .stylistic),
                                                     ("Corporate", .stylistic),
                                                     ("Marketing", .stylistic)]
        for (name, profile) in styles {
            let template = PromptTemplate(id: name.lowercased(), name: name,
                                          instructions: instructions(for: name), profile: profile)
            let result = await polisher.polish(raw, template: template)
            XCTAssertNotNil(result, "\(name) declined on a clean English transcript")
            if let result {
                XCTAssertNotEqual(result, raw, "\(name) echoed the input — no restyle happened")
                print("MLX smoke — \(name): \(result)")
            }
        }
    }

    /// Load the real starter instructions from the store's compiled seeds.
    private func instructions(for name: String) -> String {
        PromptTemplateStore.starterTemplates.first { $0.name == name }?.body ?? ""
    }

    /// Danish stylistic restyles must STAY Danish (not translate to English).
    /// Regression for the prominent `languageRule` in the starter prompts: a
    /// translation trips the polish language-guard and reduces a restyle to a
    /// raw-only review. All five starters must produce Danish that passes.
    func testDanishStylisticRestylesStayDanish() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["LOCAL_DICTATION_MLX_SMOKE"] == "1",
            "set LOCAL_DICTATION_MLX_SMOKE=1 to run the model-touching MLX smoke test")
        let polisher = MLXPolisher()
        await polisher.warmUp()
        let raw = "Lad os tage på en udflugt sammen, hvor vi kan vise kærlighed til hinanden."
        for name in ["GenZ", "Millennial", "Boomer", "Corporate", "Marketing"] {
            let template = PromptTemplate(id: name.lowercased(), name: name,
                                          instructions: instructions(for: name), profile: .stylistic)
            let result = await polisher.polish(raw, template: template)
            XCTAssertNotNil(result, "\(name) declined a Danish restyle (likely translated to English)")
            if let result {
                XCTAssertNotNil(TextLanguageID.languageWeights(of: result)["da"],
                                "\(name) restyle is not Danish: \(result)")
                print("MLX smoke — \(name): \(result)")
            }
        }
    }
}
