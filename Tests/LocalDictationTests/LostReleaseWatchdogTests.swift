import XCTest
@testable import LocalDictation

/// The watchdog's fire-time decision, with the physical key-state probe faked.
final class LostReleaseWatchdogTests: XCTestCase {
    func testStillHeldReArms() {
        // Genuine long hold: key physically down at the deadline → keep recording.
        let decision = LostReleaseWatchdog.decide(
            isRecording: true, recordingID: 7, firedID: 7,
            keyStillDown: { true })
        XCTAssertEqual(decision, .rearm)
    }

    func testReleasedEnds() {
        // Lost release: key is up but we still think we're recording → end.
        let decision = LostReleaseWatchdog.decide(
            isRecording: true, recordingID: 7, firedID: 7,
            keyStillDown: { false })
        XCTAssertEqual(decision, .endRecording)
    }

    func testNotRecordingIgnores() {
        // Normal end already happened before the timer fired.
        let decision = LostReleaseWatchdog.decide(
            isRecording: false, recordingID: 7, firedID: 7,
            keyStillDown: { true })
        XCTAssertEqual(decision, .ignore)
    }

    func testStaleUtteranceIDIgnores() {
        // An end/begin cycle happened in between: the timer belongs to an old
        // utterance and must not touch the new capture. The key probe must not
        // even be consulted.
        let decision = LostReleaseWatchdog.decide(
            isRecording: true, recordingID: 8, firedID: 7,
            keyStillDown: { XCTFail("key probe must not run for a stale ID"); return true })
        XCTAssertEqual(decision, .ignore)
    }
}
