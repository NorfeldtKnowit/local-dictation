import XCTest
@testable import LocalDictation

final class ReviewQueueLogicTests: XCTestCase {
    private func shown(_ logic: ReviewQueueLogic) -> UInt64? { logic.showing?.id }

    // MARK: - timeout scaling & policy decoding

    func testTimeoutScalesWithLengthAndClamps() {
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 0), 5)      // floor
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 400), 10)   // 400/40
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 100_000), 15) // ceiling
    }

    func testPolicyDecodingFromMenuCodes() {
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "auto"), .auto)
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "never"), .never)
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "10"), .fixed(10))
        // Garbage falls back to auto rather than crashing or never-inserting.
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "bogus"), .auto)
    }

    // MARK: - streaming lifecycle

    func testEnqueueShowsImmediatelyWithPendingRewrite() {
        var logic = ReviewQueueLogic()
        let commands = logic.enqueue(id: 1, raw: "the raw")
        XCTAssertEqual(commands, [.show(ReviewRequest(id: 1, raw: "the raw"))])
        XCTAssertEqual(logic.showing?.polish, .pending)
    }

    func testPolishFinishedWithRewriteUpdatesAndArmsDeadman() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw text of this utterance")
        let commands = logic.polishFinished(id: 1, polished: "the terse")
        XCTAssertEqual(commands, [.updatePolished(id: 1, text: "the terse"),
                                  .armDeadman(id: 1, delay: 5)])   // auto policy, short text
        XCTAssertEqual(logic.showing?.polish, .rewrite("the terse"))
    }

    func testPolishDeclineCompletesWithRawImmediately() {
        // nil rewrite = nothing to choose between; don't make the user wait.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        let commands = logic.polishFinished(id: 1, polished: nil)
        XCTAssertEqual(commands, [.complete(id: 1, text: "the raw"), .hide])
    }

    func testVerbatimEchoCompletesWithRawImmediately() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "already terse")
        let commands = logic.polishFinished(id: 1, polished: "already terse")
        XCTAssertEqual(commands, [.complete(id: 1, text: "already terse"), .hide])
    }

    func testStalePolishFinishedIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.choose(id: 1, .raw)                    // user beat the rewrite
        XCTAssertEqual(logic.polishFinished(id: 1, polished: "late rewrite"), [])
    }

    // MARK: - choices (each must emit exactly one .complete)

    func testChooseRawWorksWhileRewriteStillPending() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        XCTAssertEqual(logic.choose(id: 1, .raw),
                       [.complete(id: 1, text: "the raw"), .hide])
    }

    func testChoosePolishedBeforeRewriteExistsIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        XCTAssertEqual(logic.choose(id: 1, .polished), [])
        XCTAssertEqual(shown(logic), 1)                  // still showing
    }

    func testChoosePolishedAfterRewrite() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        XCTAssertEqual(logic.choose(id: 1, .polished),
                       [.complete(id: 1, text: "the terse"), .hide])
    }

    func testDismissCompletesWithEmptyText() {
        // "" still advances the PasteSequencer — dismiss must never stall it.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        XCTAssertEqual(logic.choose(id: 1, .dismiss),
                       [.complete(id: 1, text: ""), .hide])
    }

    func testSecondChoiceIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.choose(id: 1, .raw)
        XCTAssertEqual(logic.choose(id: 1, .raw), [])
    }

    func testStaleClickForPreviousRequestNeverDecidesCurrentOne() {
        // Request 1 completes and the queue auto-advances to 2; a click that
        // was aimed at 1 (its ID captured when the overlay was built) must
        // no-op, not dismiss 2.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.polishFinished(id: 1, polished: nil)   // finishes 1, shows 2
        XCTAssertEqual(logic.choose(id: 1, .dismiss), [])
        XCTAssertEqual(shown(logic), 2)
    }

    // MARK: - deadman (only ever armed once a rewrite exists)

    func testTimeoutCompletesWithRewriteAndStagesRawOnClipboard() {
        // Live verdict 2026-07-07: the unattended default is the rewrite —
        // the version review exists FOR — with raw staged on the clipboard.
        // The copy comes BEFORE the complete so paste-mode's clipboard
        // snapshot/restore cycle leaves the raw text on the clipboard.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 7, raw: "the raw")
        _ = logic.polishFinished(id: 7, polished: "the terse")
        XCTAssertEqual(logic.deadmanFired(id: 7, hovering: false),
                       [.copyToClipboard("the raw"),
                        .complete(id: 7, text: "the terse"), .hide])
    }

    func testStaleDeadmanIsIgnoredAfterChoice() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.polishFinished(id: 1, polished: "terse")
        _ = logic.choose(id: 1, .polished)
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
    }

    func testDeadmanWhileHoveringRearmsInsteadOfDeciding() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 3, raw: "the raw")
        _ = logic.polishFinished(id: 3, polished: "the terse")
        XCTAssertEqual(logic.deadmanFired(id: 3, hovering: true),
                       [.armDeadman(id: 3, delay: ReviewQueueLogic.hoverGrace)])
        XCTAssertEqual(logic.deadmanFired(id: 3, hovering: false),
                       [.copyToClipboard("the raw"),
                        .complete(id: 3, text: "the terse"), .hide])
    }

    func testHoverRearmIsBoundedSoTheQueueCannotStallForever() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 4, raw: "the raw")
        _ = logic.polishFinished(id: 4, polished: "the terse")
        for _ in 0..<ReviewQueueLogic.maxHoverRearms {
            XCTAssertEqual(logic.deadmanFired(id: 4, hovering: true),
                           [.armDeadman(id: 4, delay: ReviewQueueLogic.hoverGrace)])
        }
        XCTAssertEqual(logic.deadmanFired(id: 4, hovering: true),
                       [.copyToClipboard("the raw"),
                        .complete(id: 4, text: "the terse"), .hide])
    }

    // MARK: - timeout policy

    func testFixedPolicyOverridesLengthScaling() {
        var logic = ReviewQueueLogic()
        logic.policy = .fixed(30)
        _ = logic.enqueue(id: 1, raw: String(repeating: "x", count: 400))
        let commands = logic.polishFinished(id: 1, polished: "terse")
        XCTAssertEqual(commands.last, .armDeadman(id: 1, delay: 30))
    }

    func testNeverPolicyArmsNoDeadman() {
        var logic = ReviewQueueLogic()
        logic.policy = .never
        _ = logic.enqueue(id: 1, raw: "raw")
        let commands = logic.polishFinished(id: 1, polished: "terse")
        XCTAssertEqual(commands, [.updatePolished(id: 1, text: "terse"),
                                  .armDeadman(id: 1, delay: nil)])
        // A click still decides normally.
        XCTAssertEqual(logic.choose(id: 1, .polished),
                       [.complete(id: 1, text: "terse"), .hide])
    }

    // MARK: - FIFO

    func testQueuedRequestShowsAfterCurrentDecides() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        XCTAssertEqual(logic.enqueue(id: 2, raw: "raw two"), [])   // busy: queued
        let commands = logic.choose(id: 1, .raw)
        XCTAssertEqual(commands, [.complete(id: 1, text: "raw one"), .hide,
                                  .show(ReviewRequest(id: 2, raw: "raw two"))])
    }

    func testQueuedRequestsPolishSettlesWhileWaiting() {
        // Rewrite finishing for a QUEUED request must not disturb the shown
        // one, and must be rendered (with deadman) when its turn comes.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        XCTAssertEqual(logic.polishFinished(id: 2, polished: "terse two"), [])
        let commands = logic.choose(id: 1, .raw)
        XCTAssertEqual(commands, [
            .complete(id: 1, text: "raw one"), .hide,
            .show(ReviewRequest(id: 2, raw: "raw two", polish: .rewrite("terse two"))),
            .armDeadman(id: 2, delay: 5),
        ])
    }

    func testQueuedRequestWithDeclinedPolishNeverFlashesAnOverlay() {
        // A queued request whose rewrite settled as "nothing to review" is
        // completed directly on its turn — no single-candidate overlay.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.enqueue(id: 3, raw: "raw three")
        _ = logic.polishFinished(id: 2, polished: nil)
        let commands = logic.choose(id: 1, .dismiss)
        XCTAssertEqual(commands, [
            .complete(id: 1, text: ""), .hide,
            .complete(id: 2, text: "raw two"),          // drained, never shown
            .show(ReviewRequest(id: 3, raw: "raw three")),
        ])
    }

    func testBurstDrainsInOrderAndCompletesEveryID() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.enqueue(id: 2, raw: "raw")
        _ = logic.enqueue(id: 3, raw: "raw")

        var completed: [UInt64] = []
        while let id = shown(logic) {
            for command in logic.choose(id: id, .raw) {
                if case .complete(let done, _) = command { completed.append(done) }
            }
        }
        // Every allocated ID settles, in FIFO order — the sequencer contract.
        XCTAssertEqual(completed, [1, 2, 3])
        XCTAssertNil(logic.showing)
    }
}
