import XCTest
@testable import LocalDictation

final class LevelMeterMathTests: XCTestCase {
    func testSilenceIsZero() {
        XCTAssertEqual(LevelMeterMath.normalize(0), 0)
        XCTAssertEqual(LevelMeterMath.normalize(-1), 0)   // defensive clamp
    }

    func testQuietSpeechIsStillVisible() {
        // ~0.02 RMS is quiet-but-real speech; the bar must not vanish.
        XCTAssertGreaterThan(LevelMeterMath.normalize(0.02), 0.15)
    }

    func testLoudInputSaturatesAtOne() {
        XCTAssertEqual(LevelMeterMath.normalize(0.5), 1)
        XCTAssertEqual(LevelMeterMath.normalize(10), 1)
    }

    func testMonotonicallyIncreasing() {
        let values: [Float] = [0, 0.01, 0.05, 0.1, 0.2, 0.4]
        let mapped = values.map(LevelMeterMath.normalize)
        XCTAssertEqual(mapped, mapped.sorted())
    }
}
