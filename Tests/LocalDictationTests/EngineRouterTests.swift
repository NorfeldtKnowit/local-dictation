import XCTest
import FluidAudio
@testable import LocalDictation

final class EngineRouterTests: XCTestCase {
    func testDanishRoutesParakeet() {
        XCTAssertEqual(EngineRouter.route(language: "da", accuracyMode: false), .parakeet)
    }

    func testAutoRoutesParakeet() {
        XCTAssertEqual(EngineRouter.route(language: "auto", accuracyMode: false), .parakeet)
    }

    func testEveryFluidAudioLanguageRoutesParakeet() {
        for lang in Language.allCases {
            XCTAssertEqual(
                EngineRouter.route(language: lang.rawValue, accuracyMode: false),
                .parakeet,
                "\(lang.rawValue) should route to Parakeet"
            )
        }
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
}
