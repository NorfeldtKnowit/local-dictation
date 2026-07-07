import XCTest
@testable import LocalDictation

final class ReviewQueueLogicTests: XCTestCase {
    private func request(_ id: UInt64, raw: String = "raw text", polished: String = "terse") -> ReviewRequest {
        ReviewRequest(id: id, raw: raw, polished: polished)
    }

    // MARK: - needsReview

    func testNeedsReviewOnlyForRealRewrites() {
        XCTAssertTrue(ReviewQueueLogic.needsReview(asrText: "a b c", text: "a c", polished: true))
        // Not polished (declined / off) — nothing to choose between.
        XCTAssertFalse(ReviewQueueLogic.needsReview(asrText: "a b c", text: "a b c", polished: false))
        // Polished flag but identical text can't happen in the pipeline
        // (verbatim echo isn't a rewrite), but the guard must hold anyway.
        XCTAssertFalse(ReviewQueueLogic.needsReview(asrText: "a b c", text: "a b c", polished: true))
        // Empty / suppressed outcomes never review.
        XCTAssertFalse(ReviewQueueLogic.needsReview(asrText: "", text: "", polished: false))
        // A (hypothetical) polished-from-empty outcome must not reach the
        // overlay either — the empty-asrText clause is its only guard.
        XCTAssertFalse(ReviewQueueLogic.needsReview(asrText: "", text: "x", polished: true))
    }

    // MARK: - timeout scaling

    func testTimeoutScalesWithLengthAndClamps() {
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 0), 5)      // floor
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 400), 10)   // 400/40
        XCTAssertEqual(ReviewQueueLogic.timeout(forCharacterCount: 100_000), 15) // ceiling
    }

    // MARK: - basic decide paths (each must emit exactly one .complete)

    func testChooseRawCompletesWithRawText() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1, raw: "the raw", polished: "the terse"))
        let commands = logic.choose(id: 1, .raw)
        XCTAssertEqual(commands, [.complete(id: 1, text: "the raw"), .hide])
    }

    func testChoosePolishedCompletesWithPolishedText() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1, raw: "the raw", polished: "the terse"))
        let commands = logic.choose(id: 1, .polished)
        XCTAssertEqual(commands, [.complete(id: 1, text: "the terse"), .hide])
    }

    func testDismissCompletesWithEmptyText() {
        // "" still advances the PasteSequencer — dismiss must never stall it.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        let commands = logic.choose(id: 1, .dismiss)
        XCTAssertEqual(commands, [.complete(id: 1, text: ""), .hide])
    }

    func testTimeoutCompletesWithPolishedAndStagesRawOnClipboard() {
        // Live verdict 2026-07-07: the countdown is too short to really read
        // both candidates, so the unattended default is the version review
        // exists FOR (terse) — with the raw one staged on the clipboard.
        // The copy must come BEFORE the complete so paste-mode's clipboard
        // snapshot/restore cycle leaves the raw text on the clipboard.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(7, raw: "the raw", polished: "the terse"))
        let commands = logic.deadmanFired(id: 7, hovering: false)
        XCTAssertEqual(commands, [.copyToClipboard("the raw"),
                                  .complete(id: 7, text: "the terse"), .hide])
    }

    // MARK: - show command

    func testFirstEnqueueShowsWithScaledTimeout() {
        var logic = ReviewQueueLogic()
        let text = String(repeating: "x", count: 400)
        let commands = logic.enqueue(request(1, raw: text))
        XCTAssertEqual(commands, [.show(request(1, raw: text), timeout: 10)])
    }

    // MARK: - decide exactly once

    func testSecondChoiceIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.choose(id: 1, .raw)
        XCTAssertEqual(logic.choose(id: 1, .polished), [])
    }

    func testStaleDeadmanIsIgnoredAfterChoice() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.choose(id: 1, .polished)
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
    }

    func testStaleDeadmanForPreviousRequestNeverDecidesCurrentOne() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.enqueue(request(2))        // queued behind 1
        _ = logic.choose(id: 1, .raw)               // finishes 1, shows 2
        // Request 1's deadman fires late — must not decide request 2.
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
        XCTAssertEqual(logic.showing?.id, 2)
    }

    func testStaleClickForPreviousRequestNeverDecidesCurrentOne() {
        // The click twin of the stale-deadman case: request 1 times out and
        // the queue auto-advances to 2; a click that was aimed at 1 (its ID
        // captured when the overlay was built) must no-op, not dismiss 2.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.enqueue(request(2))
        _ = logic.deadmanFired(id: 1, hovering: false)   // finishes 1, shows 2
        XCTAssertEqual(logic.choose(id: 1, .dismiss), [])
        XCTAssertEqual(logic.showing?.id, 2)
    }

    // MARK: - hover pause

    func testDeadmanWhileHoveringRearmsInsteadOfDeciding() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(3))
        let commands = logic.deadmanFired(id: 3, hovering: true)
        XCTAssertEqual(commands, [.rearmDeadman(id: 3, delay: ReviewQueueLogic.hoverGrace)])
        // Still showing; the re-armed deadman (no longer hovering) decides.
        XCTAssertEqual(logic.deadmanFired(id: 3, hovering: false),
                       [.copyToClipboard("raw text"), .complete(id: 3, text: "terse"), .hide])
    }

    func testHoverRearmIsBoundedSoTheQueueCannotStallForever() {
        // A pointer parked on the overlay defers the decision only
        // maxHoverRearms times; then the raw default wins even while hovering,
        // because every later utterance is queued behind this ID.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(4, raw: "the raw", polished: "the terse"))
        for _ in 0..<ReviewQueueLogic.maxHoverRearms {
            // Each re-arm emits exactly one .rearmDeadman and never a .complete.
            XCTAssertEqual(logic.deadmanFired(id: 4, hovering: true),
                           [.rearmDeadman(id: 4, delay: ReviewQueueLogic.hoverGrace)])
        }
        XCTAssertEqual(logic.deadmanFired(id: 4, hovering: true),
                       [.copyToClipboard("the raw"),
                        .complete(id: 4, text: "the terse"), .hide])
    }

    func testHoverRearmBudgetResetsForTheNextRequest() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.enqueue(request(2))
        for _ in 0..<ReviewQueueLogic.maxHoverRearms {
            _ = logic.deadmanFired(id: 1, hovering: true)
        }
        _ = logic.deadmanFired(id: 1, hovering: true)    // budget spent: decides 1, shows 2
        XCTAssertEqual(logic.showing?.id, 2)
        // Request 2 gets a fresh hover budget.
        XCTAssertEqual(logic.deadmanFired(id: 2, hovering: true),
                       [.rearmDeadman(id: 2, delay: ReviewQueueLogic.hoverGrace)])
    }

    // MARK: - FIFO

    func testTimeoutAdvancesToQueuedRequest() {
        // The queue must drain on TIMEOUT decisions too, not only clicks —
        // otherwise a timed-out head strands everything behind it.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1, raw: "first raw", polished: "first terse"))
        _ = logic.enqueue(request(2))
        let commands = logic.deadmanFired(id: 1, hovering: false)
        XCTAssertEqual(commands, [.copyToClipboard("first raw"),
                                  .complete(id: 1, text: "first terse"), .hide,
                                  .show(request(2), timeout: 5)])
    }

    // MARK: - timeout policy

    func testFixedPolicyOverridesLengthScaling() {
        var logic = ReviewQueueLogic()
        logic.policy = .fixed(30)
        let commands = logic.enqueue(request(1, raw: String(repeating: "x", count: 400)))
        XCTAssertEqual(commands, [.show(request(1, raw: String(repeating: "x", count: 400)),
                                        timeout: 30)])
    }

    func testNeverPolicyShowsWithoutDeadman() {
        var logic = ReviewQueueLogic()
        logic.policy = .never
        XCTAssertEqual(logic.enqueue(request(1)), [.show(request(1), timeout: nil)])
        // A click still decides normally.
        XCTAssertEqual(logic.choose(id: 1, .polished), [.complete(id: 1, text: "terse"), .hide])
    }

    func testPolicyAppliesToQueueAdvanceToo() {
        var logic = ReviewQueueLogic()
        logic.policy = .never
        _ = logic.enqueue(request(1))
        _ = logic.enqueue(request(2))
        let commands = logic.choose(id: 1, .raw)
        XCTAssertEqual(commands, [.complete(id: 1, text: "raw text"), .hide,
                                  .show(request(2), timeout: nil)])
    }

    func testPolicyDecodingFromMenuCodes() {
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "auto"), .auto)
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "never"), .never)
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "10"), .fixed(10))
        // Garbage falls back to auto rather than crashing or never-inserting.
        XCTAssertEqual(ReviewQueueLogic.TimeoutPolicy.from(code: "bogus"), .auto)
    }

    func testQueuedRequestShowsAfterCurrentDecides() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        XCTAssertEqual(logic.enqueue(request(2)), [])   // busy: queued, no command
        let commands = logic.choose(id: 1, .raw)
        XCTAssertEqual(commands, [.complete(id: 1, text: "raw text"), .hide,
                                  .show(request(2), timeout: 5)])
    }

    func testBurstDrainsInOrderAndCompletesEveryID() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(request(1))
        _ = logic.enqueue(request(2))
        _ = logic.enqueue(request(3))

        var completed: [UInt64] = []
        while let showing = logic.showing {
            for command in logic.choose(id: showing.id, .raw) {
                if case .complete(let id, _) = command { completed.append(id) }
            }
        }
        // Every allocated ID settles, in FIFO order — the sequencer contract.
        XCTAssertEqual(completed, [1, 2, 3])
        XCTAssertNil(logic.showing)
    }
}
