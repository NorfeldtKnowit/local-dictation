import XCTest
@testable import LocalDictation

final class TranscriptPolisherLogicTests: XCTestCase {
    // The live-validation failure case from 2026-07-06 (English via Parakeet).
    private let disfluentRaw = "It it wor how good how good is the citation quality of this canorical example, I mean of this transcription."
    private let disfluentFixed = "How good is the dictation quality of this canonical example, I mean of this transcription."

    // MARK: worthPolishing

    func testShortTextNotWorthPolishing() {
        XCTAssertFalse(TranscriptPolisherLogic.worthPolishing("Hello there."))
    }

    func testNormalSentenceWorthPolishing() {
        XCTAssertTrue(TranscriptPolisherLogic.worthPolishing("Hello there, mate."))
    }

    func testOverlongTranscriptNotWorthPolishing() {
        // FoundationModels truncates SILENTLY at maximumResponseTokens and a
        // truncated rewrite passes the other guardrails — long dictations
        // must skip polish entirely rather than risk losing their tail.
        let long = String(repeating: "word ", count: 600)   // 3000 chars
        XCTAssertFalse(TranscriptPolisherLogic.worthPolishing(long))
    }

    // MARK: accepted rewrites

    func testGoodRewriteAccepted() {
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: disfluentFixed),
                       .accepted(disfluentFixed))
    }

    func testUnchangedCandidateAccepted() {
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: disfluentRaw),
                       .accepted(disfluentRaw))
    }

    func testSurroundingWhitespaceTrimmed() {
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: "\n " + disfluentFixed + " \n"),
                       .accepted(disfluentFixed))
    }

    func testModelAddedWrapperQuotesStripped() {
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: "\"" + disfluentFixed + "\""),
                       .accepted(disfluentFixed))
    }

    func testModelAddedSmartQuoteWrapperStripped() {
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: disfluentRaw,
                                                      candidate: "\u{201C}" + disfluentFixed + "\u{201D}"),
                       .accepted(disfluentFixed))
    }

    func testDictatedDialogueQuotesPreserved() {
        // Raw text that itself leads with a quote is the speaker's quote, not
        // a model wrapper — it must survive the unwrap untouched.
        let raw = "\"How good is the dictation quality of this example,\" I asked the team today."
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: raw, candidate: raw), .accepted(raw))
    }

    func testDanishRewriteStaysAccepted() {
        // Same-language Danish cleanup must pass the translation guard even if
        // NLLanguageRecognizer labels one side Bokmål (nb folds into da).
        let raw = "Komplet omskrivning af forgreningen, og så lader os starte forfar igen."
        let fixed = "Komplet omskrivning af forgreningen, så vi kan starte forfra igen."
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: raw, candidate: fixed), .accepted(fixed))
    }

    // MARK: rejected rewrites (each rule is a guardrail — non-negotiable)

    func testEmptyRewriteRejected() {
        guard case .rejected = TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: "") else {
            return XCTFail("empty rewrite must be rejected")
        }
    }

    func testWhitespaceOnlyRewriteRejected() {
        guard case .rejected = TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: " \n ") else {
            return XCTFail("whitespace-only rewrite must be rejected")
        }
    }

    func testAddedLineBreaksRejected() {
        // Multi-line answers to single-line input are the commentary tell
        // ("Here is the cleaned transcript:\n…").
        let candidate = "Here is the cleaned transcript:\n" + disfluentFixed
        guard case .rejected = TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: candidate) else {
            return XCTFail("added line breaks must be rejected")
        }
    }

    func testLengthBlowUpRejected() {
        let candidate = disfluentRaw + " And here is a whole extra invented sentence the speaker never said at all."
        guard case .rejected = TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: candidate) else {
            return XCTFail("growth beyond maxLengthRatio must be rejected")
        }
    }

    func testOverShrinkRejected() {
        guard case .rejected = TranscriptPolisherLogic.accept(raw: disfluentRaw, candidate: "Ok.") else {
            return XCTFail("shrink beyond minLengthRatio must be rejected")
        }
    }

    func testTranslationRejected() {
        let raw = "Komplet omskrivning af forgreningen, så vi kan starte forfra med det samme."
        let translated = "Complete rewrite of the branch, so we can start over right away."
        guard case .rejected = TranscriptPolisherLogic.accept(raw: raw, candidate: translated) else {
            return XCTFail("a translated rewrite must be rejected")
        }
    }

    func testSameLinePreambleRejected() {
        // Commentary without a newline slips past the line-break check; the
        // word-overlap guard must catch it.
        let raw = "I want to refactor the parser module and then add tests for it."
        let candidate = "Sure, I can help with that! Here is the cleaned-up version of your text: I want to refactor the parser."
        guard case .rejected = TranscriptPolisherLogic.accept(raw: raw, candidate: candidate) else {
            return XCTFail("a same-line preamble must be rejected")
        }
    }

    func testMinorityLanguageVanishingRejected() {
        // Mixed da/en utterance where the rewrite silently drops the Danish
        // half: word overlap is perfect (pure deletion) and the dominant
        // language compare would say "en == en" — only the per-language
        // vanish check can catch it.
        let raw = "Vi skal lige bruge en fallback strategi til parseren her. And then we ship the parser to production next week."
        let candidate = "And then we ship the parser to production next week."
        guard case .rejected = TranscriptPolisherLogic.accept(raw: raw, candidate: candidate) else {
            return XCTFail("a rewrite that erases one language of a mixed utterance must be rejected")
        }
    }

    func testMixedRewriteKeepingBothLanguagesAccepted() {
        let raw = "Vi skal lige bruge en fallback strategi til parseren her. And then we ship the parser to production next week."
        XCTAssertEqual(TranscriptPolisherLogic.accept(raw: raw, candidate: raw), .accepted(raw))
    }
}
