import XCTest
@testable import LocalDictation

final class HallucinationFilterTests: XCTestCase {
    func testDanishGhostDropped() {
        XCTAssertEqual(HallucinationFilter.clean("Tak for at se med"), "")
    }

    func testEnglishThanksForWatchingDropped() {
        XCTAssertEqual(HallucinationFilter.clean("Thanks for watching"), "")
    }

    func testCaseAndPunctuationInsensitive() {
        XCTAssertEqual(HallucinationFilter.clean("THANK YOU FOR WATCHING!"), "")
    }

    func testRealSentenceContainingPhraseKept() {
        // Whole-output matching only: a real sentence that embeds a blocked
        // phrase must survive.
        let text = "Thanks for watching the game with me tonight"
        XCTAssertEqual(HallucinationFilter.clean(text), text)
    }

    func testStandaloneTakForDetKept() {
        // Deliberately NOT blocklisted: a normal Danish one-word-ish reply.
        XCTAssertEqual(HallucinationFilter.clean("Tak for det"), "Tak for det")
    }

    func testStandaloneYouKept() {
        XCTAssertEqual(HallucinationFilter.clean("You"), "You")
    }

    func testRepetitionLoopDropped() {
        let loop = Array(repeating: "the", count: 20).joined(separator: " ")
        XCTAssertEqual(HallucinationFilter.clean(loop), "")
    }

    func testNormalLongSentenceKept() {
        let text = "This is a perfectly ordinary long sentence with plenty of distinct words in it today"
        XCTAssertEqual(HallucinationFilter.clean(text), text)
    }

    func testEmptyDropped() {
        XCTAssertEqual(HallucinationFilter.clean("   "), "")
    }
}
