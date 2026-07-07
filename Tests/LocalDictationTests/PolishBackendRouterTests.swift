import XCTest
@testable import LocalDictation

final class PolishBackendRouterTests: XCTestCase {
    func testEnglishRoutesToApple() {
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "This is clearly an English sentence about improving dictation quality."), .apple)
    }

    func testDanishRoutesToMLX() {
        XCTAssertEqual(PolishBackendRouter.backend(
            for: "Det her er en dansk sætning om diktering, og den skal omskrives lokalt."), .mlx)
    }

    func testUndetectableShortTextFoldsToApple() {
        // Too short for language ID — the cheap/fast backend takes it.
        XCTAssertEqual(PolishBackendRouter.backend(for: "ok"), .apple)
    }
}
