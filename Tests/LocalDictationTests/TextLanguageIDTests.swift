import XCTest
@testable import LocalDictation

/// Exercises the OS-bundled NLLanguageRecognizer through our wrapper. These
/// use unambiguous full sentences, which the recognizer identifies stably
/// across macOS releases; short/ambiguous strings are exactly what the wrapper
/// is specified to refuse (nil / empty weights), so those cases are the tests.
final class TextLanguageIDTests: XCTestCase {
    private let danish = "Lad os lave en komplet omskrivning af forgreningen, og så starter vi forfra med det samme."
    private let english = "Let us do a complete rewrite of the branch, and then we start over right away."

    func testDanishSentenceIsDetected() {
        XCTAssertEqual(TextLanguageID.dominantLanguage(of: danish), "da")
    }

    func testEnglishSentenceIsDetected() {
        XCTAssertEqual(TextLanguageID.dominantLanguage(of: english), "en")
    }

    func testGarbledParakeetDanishStillReadsAsDanish() {
        // The real failure this feature routes on: Parakeet's high-confidence
        // Danish output is wrong ("komet … foreningen … forfar") but must
        // still LID as Danish (nb folds into da) for the rescue to fire.
        let garbled = "Lad os lave en komet omskrivning af foreningen, og så lader os starte forfar."
        XCTAssertEqual(TextLanguageID.dominantLanguage(of: garbled), "da")
    }

    func testTooShortReturnsNil() {
        XCTAssertNil(TextLanguageID.dominantLanguage(of: "Okay."))
        XCTAssertNil(TextLanguageID.dominantLanguage(of: "   "))
        XCTAssertNil(TextLanguageID.dominantLanguage(of: ""))
    }

    func testBokmalNormalizesToDanish() {
        XCTAssertEqual(TextLanguageID.normalized("nb"), "da")
        XCTAssertEqual(TextLanguageID.normalized("da"), "da")
        XCTAssertEqual(TextLanguageID.normalized("en"), "en")
    }

    func testWeightsOnMonolingualTextAreConcentrated() {
        let weights = TextLanguageID.languageWeights(of: danish + " " + danish)
        XCTAssertEqual(weights["da"] ?? 0, 1.0, accuracy: 0.001)
    }

    func testWeightsOnMixedTextSplitBySentence() {
        let weights = TextLanguageID.languageWeights(of: danish + " " + english)
        XCTAssertGreaterThan(weights["da"] ?? 0, 0.3)
        XCTAssertGreaterThan(weights["en"] ?? 0, 0.3)
    }

    func testWeightsSumToOne() {
        let weights = TextLanguageID.languageWeights(of: danish + " " + english)
        XCTAssertEqual(weights.values.reduce(0, +), 1.0, accuracy: 0.001)
    }

    func testWeightsOnEmptyTextAreEmpty() {
        XCTAssertTrue(TextLanguageID.languageWeights(of: "").isEmpty)
    }
}
