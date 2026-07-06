import XCTest
import FluidAudio
@testable import LocalDictation

final class EngineRouterTests: XCTestCase {
    func testDanishRoutesWhisper() {
        // Danish is in Parakeet's 28 but whisper-preferred: measured on real
        // utterances, Parakeet garbles Danish at high confidence while Whisper
        // pinned `da` gets it right — so the pin routes to Whisper.
        XCTAssertEqual(EngineRouter.route(language: "da", accuracyMode: false), .whisper)
    }

    func testAutoRoutesParakeet() {
        XCTAssertEqual(EngineRouter.route(language: "auto", accuracyMode: false), .parakeet)
    }

    func testEveryNonPreferredFluidAudioLanguageRoutesParakeet() {
        for lang in Language.allCases where !EngineRouter.whisperPreferred.contains(lang.rawValue) {
            XCTAssertEqual(
                EngineRouter.route(language: lang.rawValue, accuracyMode: false),
                .parakeet,
                "\(lang.rawValue) should route to Parakeet"
            )
        }
    }

    func testWhisperPreferredIsSubsetOfParakeetLanguages() {
        // The set only makes sense for languages Parakeet nominally supports;
        // anything else already routes to Whisper by absence. Guards against a
        // typo'd code silently doing nothing.
        XCTAssertTrue(EngineRouter.whisperPreferred.isSubset(of: EngineRouter.parakeetLanguages))
    }

    func testMenuLanguagesExcludePreferred() {
        XCTAssertTrue(EngineRouter.parakeetMenuLanguages.isDisjoint(with: EngineRouter.whisperPreferred))
        XCTAssertEqual(EngineRouter.parakeetMenuLanguages.union(EngineRouter.whisperPreferred),
                       EngineRouter.parakeetLanguages)
    }

    func testNorwegianRoutesWhisper() {
        // FluidAudio's Language enum contains NO Norwegian, so "no"/"nb" must fall to Whisper.
        XCTAssertEqual(EngineRouter.route(language: "no", accuracyMode: false), .whisper)
        XCTAssertEqual(EngineRouter.route(language: "nb", accuracyMode: false), .whisper)
    }

    func testJapaneseRoutesWhisper() {
        XCTAssertEqual(EngineRouter.route(language: "ja", accuracyMode: false), .whisper)
    }

    func testAccuracyModeForcesWhisper() {
        XCTAssertEqual(EngineRouter.route(language: "da", accuracyMode: true), .whisper)
        XCTAssertEqual(EngineRouter.route(language: "auto", accuracyMode: true), .whisper)
    }

    // MARK: - textRescuePlan

    func testAllDanishPlansWholeUtterance() {
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["da": 1.0], segmentCount: 1),
                       .wholeUtterance(pin: "da"))
    }

    func testAllEnglishPlansKeep() {
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["en": 1.0], segmentCount: 3), .keep)
    }

    func testEmptyWeightsPlansKeep() {
        // LID produced nothing (short/garbled text) — never rescue on no signal.
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: [:], segmentCount: 2), .keep)
    }

    func testMixedWithSegmentsPlansPerSegment() {
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["da": 0.5, "en": 0.5], segmentCount: 2),
                       .perSegment(pin: "da"))
    }

    func testMixedWithoutSegmentsFallsBackByMajority() {
        // No cut points: majority-Danish still re-runs whole; minority-Danish keeps
        // Parakeet's own (sloppy but bilingual) transcript.
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["da": 0.6, "en": 0.4], segmentCount: 1),
                       .wholeUtterance(pin: "da"))
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["da": 0.3, "en": 0.7], segmentCount: 0),
                       .keep)
    }

    func testTraceDanishBelowMixedShareIsNoise() {
        // One short misdetected sentence in an English utterance must not
        // trigger a rescue.
        XCTAssertEqual(EngineRouter.textRescuePlan(weights: ["da": 0.1, "en": 0.9], segmentCount: 4),
                       .keep)
    }
}
