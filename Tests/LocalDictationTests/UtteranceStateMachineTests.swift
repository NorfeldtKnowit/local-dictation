import XCTest
@testable import LocalDictation

final class UtteranceStateMachineTests: XCTestCase {
    private func ready() -> UtteranceStateMachine {
        var sm = UtteranceStateMachine()
        sm.engineReady = true
        return sm
    }

    func testBeginBeforeReadyIgnored() {
        var sm = UtteranceStateMachine()   // engineReady == false
        XCTAssertEqual(sm.begin(), .ignore)
        XCTAssertFalse(sm.isRecording)
    }

    func testBeginFromIdleStartsCapture() {
        var sm = ready()
        XCTAssertEqual(sm.begin(), .startCapture(id: 1))
        XCTAssertTrue(sm.isRecording)
    }

    func testDoubleBeginIgnored() {
        var sm = ready()
        _ = sm.begin()
        XCTAssertEqual(sm.begin(), .ignore)
        XCTAssertEqual(sm.recordingID, 1)
    }

    func testEndWithoutBeginIgnored() {
        var sm = ready()
        XCTAssertEqual(sm.end(), .ignore)
        XCTAssertTrue(sm.inFlight.isEmpty)
    }

    func testPressReleasePressYieldsDistinctIDs() {
        var sm = ready()
        XCTAssertEqual(sm.begin(), .startCapture(id: 1))
        XCTAssertEqual(sm.end(), .stopCaptureAndProcess(id: 1))
        XCTAssertEqual(sm.begin(), .startCapture(id: 2))
    }

    func testBeginWhileTranscribingAllowed() {
        var sm = ready()
        _ = sm.begin()                                   // id 1
        XCTAssertEqual(sm.end(), .stopCaptureAndProcess(id: 1))
        XCTAssertTrue(sm.isTranscribing)                 // id 1 still in flight
        XCTAssertEqual(sm.begin(), .startCapture(id: 2)) // new capture allowed
    }

    func testSettledClearsInFlight() {
        var sm = ready()
        _ = sm.begin()
        _ = sm.end()
        sm.settled(1)
        XCTAssertFalse(sm.isTranscribing)
        XCTAssertTrue(sm.inFlight.isEmpty)
    }

    func testMenuPrecedenceListeningOverTranscribing() {
        var sm = ready()
        _ = sm.begin()
        _ = sm.end()
        _ = sm.begin()                                   // recording again while id 1 in flight
        XCTAssertTrue(sm.isRecording)                    // listening rung wins
        XCTAssertTrue(sm.isTranscribing)                 // and a transcription is still pending
    }
}
