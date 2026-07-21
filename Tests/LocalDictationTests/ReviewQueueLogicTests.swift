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

    func testPolishDeclineShowsRawOnlyForReview() {
        // nil rewrite = no distinct candidate, but "Review Before Paste" must
        // STILL review: keep the overlay up (raw-only) and arm the deadman —
        // never silently paste.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        let commands = logic.polishFinished(id: 1, polished: nil)
        XCTAssertEqual(commands, [.show(ReviewRequest(id: 1, raw: "the raw", polish: .none)),
                                  .armDeadman(id: 1, delay: 5)])
    }

    func testVerbatimEchoShowsRawOnlyForReview() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "already terse")
        let commands = logic.polishFinished(id: 1, polished: "already terse")
        XCTAssertEqual(commands, [.show(ReviewRequest(id: 1, raw: "already terse", polish: .none)),
                                  .armDeadman(id: 1, delay: 5)])
    }

    func testRawOnlyDeadmanInsertsRawWithoutClipboardStaging() {
        // The raw-only auto-insert IS the raw, so nothing is staged on the
        // clipboard (unlike a rewrite auto-pick, which stages raw for recovery).
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: nil)
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false),
                       [.complete(id: 1, text: "the raw"), .hide])
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
        _ = logic.choose(id: 1, .dismiss)                // decide 1, advances to 2
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

    // MARK: - edit before insert: Copy (clipboard, no paste)

    func testCopyEditedStagesClipboardAndSettlesWithoutPasting() {
        // Copy stages the edited text on the clipboard and completes with "" so
        // the sequencer advances but nothing pastes (the caret has moved). The
        // clipboard command is FIRST so the empty complete can't clobber it.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.copyEdited(id: 1, text: "my hand edit"),
                       [.copyToClipboard("my hand edit"),
                        .complete(id: 1, text: ""), .hide])
    }

    func testCopyEmptyEditJustDismisses() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.copyEdited(id: 1, text: ""),
                       [.complete(id: 1, text: ""), .hide])
    }

    func testCopyEditedForStaleIdIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.choose(id: 1, .dismiss)                // decide 1, advances to 2
        XCTAssertEqual(logic.copyEdited(id: 1, text: "x"), [])
        XCTAssertEqual(shown(logic), 2)
    }

    func testCopyEditedDrainsQueue() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.polishFinished(id: 1, polished: "terse one")
        _ = logic.polishFinished(id: 2, polished: "terse two")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.copyEdited(id: 1, text: "edited one"), [
            .copyToClipboard("edited one"),
            .complete(id: 1, text: ""), .hide,
            .show(ReviewRequest(id: 2, raw: "raw two", polish: .rewrite("terse two"))),
            .armDeadman(id: 2, delay: 5),
        ])
    }

    func testStaleDeadmanIgnoredAfterCopy() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.polishFinished(id: 1, polished: "terse")
        _ = logic.beginEdit(id: 1)
        _ = logic.copyEdited(id: 1, text: "edited")
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
    }

    // MARK: - edit before insert: Save (fold back into review)

    func testSaveEditedRawGoesPendingAndReShowsThenRepolishArms() {
        // Saving an edited RAW replaces raw, drops to pending (suspending the
        // deadman) and re-shows so the caller can re-polish the NEW raw.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "old raw", templateID: "terse")
        _ = logic.polishFinished(id: 1, polished: "old terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.saveEditedRaw(id: 1, text: "new raw"),
                       [.show(ReviewRequest(id: 1, raw: "new raw", templateID: "terse", polish: .pending))])
        // Pending suspends the deadman until the re-polish settles.
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
        // The re-polish of the new raw then updates + re-arms.
        XCTAssertEqual(logic.repolishFinished(id: 1, polished: "new terse"),
                       [.updatePolished(id: 1, text: "new terse"),
                        .armDeadman(id: 1, delay: 5)])
    }

    func testSaveEditedRawDeclineFallsToRawOnlyOfNewRaw() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "old raw")
        _ = logic.polishFinished(id: 1, polished: "old terse")
        _ = logic.beginEdit(id: 1)
        _ = logic.saveEditedRaw(id: 1, text: "new raw")
        // A declined re-polish must NOT revert to the old rewrite (it was for the
        // old raw) — it degrades to a raw-only review of the NEW raw.
        XCTAssertEqual(logic.repolishFinished(id: 1, polished: nil),
                       [.show(ReviewRequest(id: 1, raw: "new raw", polish: .none)),
                        .armDeadman(id: 1, delay: 5)])
    }

    func testSaveEditedStyledUpdatesVerbatimAndReArms() {
        // Saving an edited styled candidate sets it as the rewrite verbatim (no
        // guardrails — the user authored it) and re-arms the countdown.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.saveEditedPolished(id: 1, text: "my styled edit 🎉"),
                       [.show(ReviewRequest(id: 1, raw: "the raw", polish: .rewrite("my styled edit 🎉"))),
                        .armDeadman(id: 1, delay: 5)])
        // The edited rewrite is what a click / timeout now inserts.
        XCTAssertEqual(logic.choose(id: 1, .polished),
                       [.complete(id: 1, text: "my styled edit 🎉"), .hide])
    }

    func testSaveEditedStyledEmptyDegradesToRawOnly() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.saveEditedPolished(id: 1, text: ""),
                       [.show(ReviewRequest(id: 1, raw: "the raw", polish: .none)),
                        .armDeadman(id: 1, delay: 5)])
    }

    func testSaveEditedForStaleIdIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.choose(id: 1, .dismiss)                // decide 1, advances to 2
        XCTAssertEqual(logic.saveEditedRaw(id: 1, text: "x"), [])
        XCTAssertEqual(logic.saveEditedPolished(id: 1, text: "y"), [])
        XCTAssertEqual(shown(logic), 2)
    }

    func testBeginEditForWrongIdIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        XCTAssertEqual(logic.beginEdit(id: 99), [])
    }

    func testBeginEditSuspendsDeadman() {
        // While editing, a fired deadman is ignored AND not re-armed — nothing
        // auto-inserts the in-progress text.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: true), [])
        XCTAssertEqual(shown(logic), 1)   // still showing, still editable
    }

    func testCancelEditReArmsCountdown() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw")
        _ = logic.polishFinished(id: 1, polished: "the terse")
        _ = logic.beginEdit(id: 1)
        XCTAssertEqual(logic.cancelEdit(id: 1), [.armDeadman(id: 1, delay: 5)])
        // Editing cleared: the deadman now decides normally again.
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false),
                       [.copyToClipboard("the raw"),
                        .complete(id: 1, text: "the terse"), .hide])
    }

    func testCancelEditWhenNotEditingIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.polishFinished(id: 1, polished: "terse")
        XCTAssertEqual(logic.cancelEdit(id: 1), [])   // never entered edit
    }

    // MARK: - restyle (re-polish with a different template)

    func testBeginRepolishSuspendsDeadmanThenRepolishReArms() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw text here")
        _ = logic.polishFinished(id: 1, polished: "terse version")
        // Restyle drops to pending, so a deadman that fires mid-repolish no-ops.
        XCTAssertEqual(logic.beginRepolish(id: 1, badge: "BOOMER"), [])
        XCTAssertEqual(logic.deadmanFired(id: 1, hovering: false), [])
        // The new rewrite replaces the row and re-arms the countdown.
        XCTAssertEqual(logic.repolishFinished(id: 1, polished: "Certainly, the raw text."),
                       [.updatePolished(id: 1, text: "Certainly, the raw text."),
                        .armDeadman(id: 1, delay: 5)])
        // The new rewrite is what a click now inserts.
        XCTAssertEqual(logic.choose(id: 1, .polished),
                       [.complete(id: 1, text: "Certainly, the raw text."), .hide])
    }

    func testRepolishDeclineRevertsToPriorRewrite() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "the raw text here")
        _ = logic.polishFinished(id: 1, polished: "terse version")
        _ = logic.beginRepolish(id: 1, badge: "BOOMER")
        // nil (guardrail reject / unavailable) must NOT collapse the overlay —
        // it reverts to the pre-restyle rewrite and re-arms.
        XCTAssertEqual(logic.repolishFinished(id: 1, polished: nil),
                       [.updatePolished(id: 1, text: "terse version"),
                        .armDeadman(id: 1, delay: 5)])
    }

    func testBeginRepolishForStaleIdIsIgnored() {
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw")
        _ = logic.polishFinished(id: 1, polished: "terse")
        XCTAssertEqual(logic.beginRepolish(id: 99, badge: "BOOMER"), [])
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

    func testQueuedRequestWithDeclinedPolishIsShownRawOnlyForReview() {
        // A queued request whose rewrite settled as "nothing to review" is now
        // SHOWN raw-only on its turn (not silently completed) — "Review Before
        // Paste" reviews every utterance. It arms the deadman like any settled
        // request; id 3 stays queued behind it.
        var logic = ReviewQueueLogic()
        _ = logic.enqueue(id: 1, raw: "raw one")
        _ = logic.enqueue(id: 2, raw: "raw two")
        _ = logic.enqueue(id: 3, raw: "raw three")
        _ = logic.polishFinished(id: 2, polished: nil)
        let commands = logic.choose(id: 1, .dismiss)
        XCTAssertEqual(commands, [
            .complete(id: 1, text: ""), .hide,
            .show(ReviewRequest(id: 2, raw: "raw two", polish: .none)),
            .armDeadman(id: 2, delay: 5),
        ])
        XCTAssertEqual(shown(logic), 2)
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
