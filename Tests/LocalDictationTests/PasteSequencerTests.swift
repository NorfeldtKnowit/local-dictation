import XCTest
@testable import LocalDictation

/// Pure ordering/spacing tests for `PasteSequencer` — no AppKit, no real timers.
/// The harness injects a manual clock and captures scheduled continuations so
/// tests advance time and fire them deterministically.
final class PasteSequencerTests: XCTestCase {
    /// Deterministic test double: manual clock + captured timer callbacks.
    private final class Harness {
        var nowSeconds: TimeInterval = 0
        var pasted: [String] = []
        /// (delay, action) pairs handed to `schedule`, in call order.
        var scheduled: [(delay: TimeInterval, action: () -> Void)] = []
        let sequencer: PasteSequencer

        init(minSpacing: TimeInterval = 0.3) {
            var getNow: () -> Date = { Date(timeIntervalSinceReferenceDate: 0) }
            var doPaste: (String) -> Void = { _ in }
            var doSchedule: (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }
            sequencer = PasteSequencer(
                minSpacing: minSpacing,
                now: { getNow() },
                schedule: { delay, action in doSchedule(delay, action) },
                paste: { doPaste($0) }
            )
            getNow = { [weak self] in Date(timeIntervalSinceReferenceDate: self?.nowSeconds ?? 0) }
            doPaste = { [weak self] in self?.pasted.append($0) }
            doSchedule = { [weak self] delay, action in self?.scheduled.append((delay, action)) }
        }

        /// Fire the oldest scheduled continuation, advancing the clock by its delay.
        func fireNextTimer() {
            guard !scheduled.isEmpty else { return XCTFail("no timer scheduled") }
            let (delay, action) = scheduled.removeFirst()
            nowSeconds += delay
            action()
        }
    }

    func testInOrderCompletionPastesImmediately() {
        let h = Harness()
        h.sequencer.complete(id: 1, text: "one")
        XCTAssertEqual(h.pasted, ["one"])
        // Well past the spacing window, the next in-order paste is immediate.
        h.nowSeconds = 10
        h.sequencer.complete(id: 2, text: "two")
        XCTAssertEqual(h.pasted, ["one", "two"])
        XCTAssertTrue(h.scheduled.isEmpty)
    }

    func testOutOfOrderCompletionBuffersUntilEarlierIDArrives() {
        let h = Harness()
        // Utterance 2 (fast Parakeet) finishes before 1 (slow Whisper): it must
        // buffer, not paste — completion order never beats spoken order.
        h.sequencer.complete(id: 2, text: "second")
        XCTAssertEqual(h.pasted, [])
        h.nowSeconds = 10
        h.sequencer.complete(id: 1, text: "first")
        // "first" pastes immediately; "second" is now due but inside the spacing
        // window, so it drains via the scheduled continuation.
        XCTAssertEqual(h.pasted, ["first"])
        XCTAssertEqual(h.scheduled.count, 1)
        h.fireNextTimer()
        XCTAssertEqual(h.pasted, ["first", "second"])
    }

    func testEmptyOutcomeAdvancesSequence() {
        let h = Harness()
        // Utterance 1 was gated out (empty text) — 2 must not stall behind it.
        h.sequencer.complete(id: 2, text: "two")
        XCTAssertEqual(h.pasted, [])
        h.sequencer.complete(id: 1, text: "")
        XCTAssertEqual(h.pasted, ["two"])
    }

    func testSpacingEnforcedBetweenConsecutivePastes() {
        let h = Harness()
        h.sequencer.complete(id: 1, text: "one")
        XCTAssertEqual(h.pasted, ["one"])
        // 0.1 s later — inside the 0.3 s window: must schedule, not paste.
        h.nowSeconds = 0.1
        h.sequencer.complete(id: 2, text: "two")
        XCTAssertEqual(h.pasted, ["one"])
        XCTAssertEqual(h.scheduled.count, 1)
        XCTAssertEqual(h.scheduled[0].delay, 0.2, accuracy: 0.0001)
        // The continuation fires at t=0.3 and delivers the delayed paste.
        h.fireNextTimer()
        XCTAssertEqual(h.pasted, ["one", "two"])
    }

    func testBackToBackBurstDrainsInOrderWithSpacing() {
        let h = Harness()
        // Three utterances complete out of order at t=0.
        h.sequencer.complete(id: 3, text: "three")
        h.sequencer.complete(id: 1, text: "one")   // pastes immediately
        h.sequencer.complete(id: 2, text: "two")   // in window → scheduled
        XCTAssertEqual(h.pasted, ["one"])
        XCTAssertEqual(h.scheduled.count, 1)
        h.fireNextTimer()                          // t=0.3 → pastes "two", reschedules for "three"
        XCTAssertEqual(h.pasted, ["one", "two"])
        XCTAssertEqual(h.scheduled.count, 1)
        h.fireNextTimer()                          // t=0.6 → pastes "three"
        XCTAssertEqual(h.pasted, ["one", "two", "three"])
        XCTAssertTrue(h.scheduled.isEmpty)
    }

    func testDoubleCompleteOfFlushedIDIsIgnored() {
        let h = Harness()
        h.sequencer.complete(id: 1, text: "one")
        h.nowSeconds = 10
        h.sequencer.complete(id: 1, text: "one again")
        XCTAssertEqual(h.pasted, ["one"])
    }

    func testStaleIDBelowSequenceIsIgnored() {
        let h = Harness(minSpacing: 0)
        h.sequencer.complete(id: 1, text: "")
        h.sequencer.complete(id: 2, text: "two")
        XCTAssertEqual(h.pasted, ["two"])
        // A late duplicate of an already-advanced ID must not rewind anything.
        h.sequencer.complete(id: 1, text: "ghost")
        h.sequencer.complete(id: 3, text: "three")
        XCTAssertEqual(h.pasted, ["two", "three"])
    }
}
