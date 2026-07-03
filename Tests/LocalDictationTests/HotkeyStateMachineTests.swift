import XCTest
@testable import LocalDictation

final class HotkeyStateMachineTests: XCTestCase {
    func testPressWhileUpEmitsPressed() {
        var sm = HotkeyStateMachine()
        XCTAssertEqual(sm.handleFlagsChanged(optionHeld: true), .pressed)
        XCTAssertTrue(sm.isDown)
    }

    func testReleaseWhileDownEmitsReleased() {
        var sm = HotkeyStateMachine()
        _ = sm.handleFlagsChanged(optionHeld: true)
        XCTAssertEqual(sm.handleFlagsChanged(optionHeld: false), .released)
        XCTAssertFalse(sm.isDown)
    }

    func testDuplicatePressIgnored() {
        var sm = HotkeyStateMachine()
        _ = sm.handleFlagsChanged(optionHeld: true)
        XCTAssertNil(sm.handleFlagsChanged(optionHeld: true))
        XCTAssertTrue(sm.isDown)
    }

    func testDuplicateReleaseIgnored() {
        var sm = HotkeyStateMachine()
        // Never pressed; a release reading is a no-op edge.
        XCTAssertNil(sm.handleFlagsChanged(optionHeld: false))
        XCTAssertFalse(sm.isDown)
    }

    func testTapDisabledWhileHeldSynthesizesRelease() {
        var sm = HotkeyStateMachine()
        _ = sm.handleFlagsChanged(optionHeld: true)
        XCTAssertEqual(sm.handleTapDisabledWhileHeld(), .released)
        XCTAssertFalse(sm.isDown)
    }

    func testTapDisabledWhileIdleNoop() {
        var sm = HotkeyStateMachine()
        XCTAssertNil(sm.handleTapDisabledWhileHeld())
        XCTAssertFalse(sm.isDown)
    }
}
