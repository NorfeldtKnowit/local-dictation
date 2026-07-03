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

    func testDefaultsAutoAndAccuracyOff() {
        let setting = LanguageSetting(defaults: defaults)
        XCTAssertEqual(setting.language, "auto")
        XCTAssertFalse(setting.accuracyMode)
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
}
