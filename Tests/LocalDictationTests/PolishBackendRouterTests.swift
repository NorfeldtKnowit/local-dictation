import XCTest
@testable import LocalDictation

final class PolishBackendRouterTests: XCTestCase {
    func testEnglishFaithfulRoutesToApple() {
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "This is clearly an English sentence about improving dictation quality.",
            profile: .faithful), .apple)
    }

    func testDanishFaithfulRoutesToMLX() {
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "Det her er en dansk sætning om diktering, og den skal omskrives lokalt.",
            profile: .terse), .mlx)
    }

    func testUndetectableShortTextFoldsToApple() {
        // Too short for language ID — the cheap/fast backend takes it.
        XCTAssertEqual(PolishBackendRouter.backend(for: "ok", profile: .faithful), .apple)
    }

    func testStylisticAlwaysRoutesToMLXEvenForEnglish() {
        // Apple FM neutralises/echoes bold restyles, so every stylistic template
        // goes to Qwen regardless of language.
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "This is clearly an English sentence about improving dictation quality.",
            profile: .stylistic), .mlx)
    }

    func testTranslationAlwaysRoutesToMLXEvenForEnglish() {
        // Apple FM is English-only in practice, so it can't translate INTO
        // Swedish; translation always goes to Qwen regardless of input language.
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "This is clearly an English sentence about improving dictation quality.",
            profile: .translation), .mlx)
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "Det her er en dansk sætning der skal oversættes.",
            profile: .translation), .mlx)
    }
}
