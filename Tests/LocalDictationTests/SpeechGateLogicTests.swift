import XCTest
import FluidAudio
@testable import LocalDictation

final class SpeechGateLogicTests: XCTestCase {
    // Helper: build a VadSegment spanning [start, end] seconds.
    private func seg(_ start: Double, _ end: Double) -> VadSegment {
        VadSegment(startTime: start, endTime: end)
    }

    func testBelowMinRawSamplesTooShort() {
        // Fewer than 0.30 s of raw audio: skip VAD entirely.
        let d = SpeechGateLogic.decide(totalSamples: 1_000, segments: [seg(0, 1)])
        XCTAssertEqual(d, .tooShort)
    }

    func testEmptySegmentsSilence() {
        let d = SpeechGateLogic.decide(totalSamples: 32_000, segments: [])
        XCTAssertEqual(d, .silence)
    }

    func testTotalSpeechBelowThresholdSilence() {
        // 0.20 s of speech < 0.35 s floor.
        let d = SpeechGateLogic.decide(totalSamples: 32_000, segments: [seg(0.0, 0.20)])
        XCTAssertEqual(d, .silence)
    }

    func testSufficientSpeechPasses() {
        // 0.50 s of speech spread over two segments >= 0.35 s.
        let d = SpeechGateLogic.decide(totalSamples: 32_000, segments: [seg(0.0, 0.25), seg(0.5, 0.75)])
        XCTAssertEqual(d, .pass)
    }

    func testNilSegmentsVadUnavailable() {
        let d = SpeechGateLogic.decide(totalSamples: 32_000, segments: nil)
        XCTAssertEqual(d, .vadUnavailable)
    }

    func testTrimConcatenatesSegments() {
        // 1 s buffer at 16 kHz; keep [0, 0.25) and [0.5, 0.75) -> 4000 + 4000 samples.
        let samples = [Float](repeating: 1.0, count: 16_000)
        let out = SpeechGateLogic.trim(samples, segments: [seg(0.0, 0.25), seg(0.5, 0.75)])
        XCTAssertEqual(out.count, 8_000)
    }

    func testTrimClampsOutOfRangeSegments() {
        // Segment end overshoots the buffer; trim must clamp, not crash.
        let samples = [Float](repeating: 1.0, count: 16_000)   // 1 s
        let out = SpeechGateLogic.trim(samples, segments: [seg(0.9, 5.0)])
        XCTAssertEqual(out.count, 16_000 - Int(0.9 * 16_000))  // 1600 samples
    }
}
