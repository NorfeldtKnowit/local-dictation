import XCTest
@testable import LocalDictation

final class TranscriptDiffLogicTests: XCTestCase {
    /// Resolve highlight ranges back to their substrings so assertions read
    /// as the words a user would see marked.
    private func marked(_ ranges: [Range<String.Index>], in text: String) -> [String] {
        ranges.map { String(text[$0]) }
    }

    func testIdenticalTextsHighlightNothing() {
        let text = "send the report on Monday"
        let h = TranscriptDiffLogic.highlights(raw: text, terse: text)
        XCTAssertTrue(h.rawDeletions.isEmpty)
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }

    func testWhitespaceOnlyDifferencesHighlightNothing() {
        let h = TranscriptDiffLogic.highlights(raw: "hello   world\nagain",
                                               terse: "hello world again")
        XCTAssertTrue(h.rawDeletions.isEmpty)
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }

    func testCondensationMarksDroppedRunAsOneRange() {
        let raw = "I think that we should just go"
        let terse = "we should just go"
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        XCTAssertEqual(marked(h.rawDeletions, in: raw), ["I think that"])
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }

    func testReplacementMarksBothSides() {
        let raw = "send it monday"
        let terse = "send it Monday."
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        XCTAssertEqual(marked(h.rawDeletions, in: raw), ["monday"])
        XCTAssertEqual(marked(h.terseInsertions, in: terse), ["Monday."])
    }

    func testInsertionOnlyMarksNothingInRaw() {
        let raw = "call now"
        let terse = "please call now"
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        XCTAssertTrue(h.rawDeletions.isEmpty)
        XCTAssertEqual(marked(h.terseInsertions, in: terse), ["please"])
    }

    func testCoalescingDoesNotBridgeKeptWords() {
        let raw = "alpha beta gamma"
        let terse = "beta"
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        XCTAssertEqual(marked(h.rawDeletions, in: raw), ["alpha", "gamma"])
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }

    func testEmptyRawMarksWholeTerse() {
        let terse = "hello there"
        let h = TranscriptDiffLogic.highlights(raw: "", terse: terse)
        XCTAssertTrue(h.rawDeletions.isEmpty)
        XCTAssertEqual(marked(h.terseInsertions, in: terse), ["hello there"])
    }

    func testEmptyTerseMarksWholeRaw() {
        let raw = "hello there"
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: "")
        XCTAssertEqual(marked(h.rawDeletions, in: raw), ["hello there"])
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }

    func testMultiByteCharactersKeepRangesAligned() {
        let raw = "vi ses i morgen 🎉 måske"
        let terse = "vi ses i morgen"
        let h = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        XCTAssertEqual(marked(h.rawDeletions, in: raw), ["🎉 måske"])
        XCTAssertTrue(h.terseInsertions.isEmpty)
    }
}
