import XCTest
@testable import LocalDictation

final class LanguageSettingTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LanguageSettingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultsAutoAccuracyOffPolishOn() {
        let setting = LanguageSetting(defaults: defaults)
        XCTAssertEqual(setting.language, "auto")
        XCTAssertFalse(setting.accuracyMode)
        XCTAssertTrue(setting.polishTranscript)   // default-ON, opt-out toggle
        XCTAssertFalse(setting.copyInsteadOfPaste)
        XCTAssertFalse(setting.reviewBeforePaste)
        XCTAssertEqual(setting.reviewAutoInsert, "auto")
        XCTAssertEqual(setting.selectedTemplate, "terse")
    }

    func testReviewAutoInsertPersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.reviewAutoInsert = "never"
        XCTAssertEqual(LanguageSetting(defaults: defaults).reviewAutoInsert, "never")
    }

    func testSelectedTemplatePersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.selectedTemplate = "genz"
        XCTAssertEqual(LanguageSetting(defaults: defaults).selectedTemplate, "genz")
    }

    func testPinPersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.language = "da"
        // A freshly constructed view over the same store must observe the write.
        XCTAssertEqual(LanguageSetting(defaults: defaults).language, "da")
    }

    func testAccuracyPersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.accuracyMode = true
        XCTAssertTrue(LanguageSetting(defaults: defaults).accuracyMode)
    }

    func testReviewPersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.reviewBeforePaste = true
        XCTAssertTrue(LanguageSetting(defaults: defaults).reviewBeforePaste)
    }

    func testCopyModePersists() {
        let setting = LanguageSetting(defaults: defaults)
        setting.copyInsteadOfPaste = true
        XCTAssertTrue(LanguageSetting(defaults: defaults).copyInsteadOfPaste)
    }

    func testPolishOptOutPersists() {
        // The non-default value (false) is the one that must round-trip: it
        // proves the object probe distinguishes "set to false" from "never set".
        let setting = LanguageSetting(defaults: defaults)
        setting.polishTranscript = false
        XCTAssertFalse(LanguageSetting(defaults: defaults).polishTranscript)
    }
}
