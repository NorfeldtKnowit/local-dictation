import XCTest
@testable import LocalDictation

final class FillerFilterTests: XCTestCase {
    // MARK: removal

    func testLeadingFillerRemovedAndCapitalPassedOn() {
        XCTAssertEqual(FillerFilter.strip("Um, so basically I want tests."),
                       "So basically I want tests.")
    }

    func testLeadingLowercaseFillerDoesNotForceCapital() {
        XCTAssertEqual(FillerFilter.strip("um so what now"), "so what now")
    }

    func testCommaPairCollapses() {
        XCTAssertEqual(FillerFilter.strip("I want to, uh, refactor the parser."),
                       "I want to refactor the parser.")
    }

    func testBareMidSentenceFillerRemoved() {
        XCTAssertEqual(FillerFilter.strip("en øh fallback"), "en fallback")
    }

    func testSentenceFinalFillerKeepsTerminator() {
        XCTAssertEqual(FillerFilter.strip("Refactor the parser, uh."),
                       "Refactor the parser.")
    }

    func testSentenceFinalFillerNeverDoublesTerminator() {
        // ASR often emits a trailing hesitation as its own sentence; the
        // previous sentence's terminator must not be doubled.
        XCTAssertEqual(FillerFilter.strip("Done. Uh."), "Done.")
        XCTAssertEqual(FillerFilter.strip("Okay! Um."), "Okay!")
        XCTAssertEqual(FillerFilter.strip("We shipped it. Um. Next week too."),
                       "We shipped it. Next week too.")
    }

    func testMidTextSentenceInitialFillerPassesCapital() {
        XCTAssertEqual(FillerFilter.strip("That's it. Um, next we ship."),
                       "That's it. Next we ship.")
    }

    func testListSeparatorCommaSurvivesFillerPair() {
        // "Bob," here is a real list separator, not a pause artifact — an
        // earlier comma in the utterance means we must not delete it.
        XCTAssertEqual(FillerFilter.strip("Invite Alice, Bob, uh, Charlie and Dave."),
                       "Invite Alice, Bob, Charlie and Dave.")
    }

    func testDanishLeadingFiller() {
        XCTAssertEqual(FillerFilter.strip("Øh, komplet omskrivning af forgreningen, så vi kan starte forfra."),
                       "Komplet omskrivning af forgreningen, så vi kan starte forfra.")
    }

    func testConsecutiveFillers() {
        XCTAssertEqual(FillerFilter.strip("I want to, uh, um, refactor it."),
                       "I want to refactor it.")
    }

    func testAllFillerUtteranceBecomesEmpty() {
        XCTAssertEqual(FillerFilter.strip("Uh, um."), "")
    }

    // MARK: preservation

    func testCleanTextReturnedUnchanged() {
        let text = "Please schedule the meeting for Tuesday at three."
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testNoFillerReturnsSameInstanceIncludingWhitespace() {
        let text = "line one\nline two  spaced"
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testFillersInsideWordsNeverTouched() {
        let text = "The serum in the gum made the høj kummefryser hum."
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testDanishErIsNeverAFiller() {
        let text = "Det er godt, og det er nok."
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testUhHuhKept() {
        let text = "She said uh-huh and moved on."
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testDiscourseWordsKept() {
        let text = "Altså, det giver jo mening."
        XCTAssertEqual(FillerFilter.strip(text), text)
    }

    func testEmptyStringUntouched() {
        XCTAssertEqual(FillerFilter.strip(""), "")
    }

    // MARK: mixed language

    func testMixedUtteranceOnlyFillerRemoved() {
        XCTAssertEqual(FillerFilter.strip("Vi skal lige bruge en, øh, fallback strategy for the parser."),
                       "Vi skal lige bruge en fallback strategy for the parser.")
    }
}
