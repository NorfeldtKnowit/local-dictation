import Foundation

/// Glue between the pure `ReviewQueueLogic` and the world: executes its
/// commands against the overlay controller, schedules deadman firings through
/// an injected (deliberately uncancellable) timer, and hands every decided
/// text to the injected `complete` — which is `pasteSequencer.complete` in
/// production, so the sequencer's every-ID-settles contract is preserved on
/// every path (click, dismiss, timeout).
///
/// Streaming: `polishPartial` bypasses the logic entirely (display-only, ID-
/// guarded by the controller); only `polishFinished` — which the pipeline
/// always delivers, bounded by the backends' own timeouts — changes state.
///
/// Main-thread only, like `PasteSequencer`: `AppDelegate` drives it from the
/// main actor and the overlay controller is AppKit.
final class ReviewCoordinator {
    private var logic = ReviewQueueLogic()
    private let overlay: ReviewOverlayController
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let complete: (UInt64, String) -> Void

    init(overlay: ReviewOverlayController = ReviewOverlayController(),
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         complete: @escaping (UInt64, String) -> Void) {
        self.overlay = overlay
        self.schedule = schedule
        self.complete = complete
        overlay.onChoice = { [weak self] id, choice in
            guard let self else { return }
            Log.info("review: picked=\(choice) id=\(id)", "review")
            self.run(self.logic.choose(id: id, choice))
        }
    }

    /// Show the HUD for a finished utterance (raw text, rewrite pending).
    func enqueue(id: UInt64, raw: String) {
        run(logic.enqueue(id: id, raw: raw))
    }

    /// Display-only streaming update for the TERSE row (not guardrail-checked;
    /// never pasted — the final text arrives via `polishFinished`).
    func polishPartial(id: UInt64, text: String) {
        overlay.setPolished(id: id, text: text, final: false)
    }

    /// The polish stage settled (nil = decline/echo → nothing to review).
    func polishFinished(id: UInt64, polished: String?) {
        let commands = logic.polishFinished(id: id, polished: polished)
        if commands.contains(where: { if case .complete = $0 { return true }; return false }) {
            Log.info("review: no usable rewrite — inserted raw directly id=\(id)", "review")
        }
        run(commands)
    }

    /// Applies from the next deadman arming; one already scheduled stands.
    func setTimeoutPolicy(_ policy: ReviewQueueLogic.TimeoutPolicy) {
        logic.policy = policy
    }

    private func deadmanFired(id: UInt64) {
        // Geometry at decision time, not cached tracking-area state: a pointer
        // parked over the panel since before it appeared never crossed into it.
        let hovering = overlay.pointerIsOverPanel
        let commands = logic.deadmanFired(id: id, hovering: hovering)
        if commands.contains(where: { if case .complete = $0 { return true }; return false }) {
            Log.info("review: picked=timeout(terse; raw -> clipboard) id=\(id)", "review")
        }
        run(commands)
    }

    private func run(_ commands: [ReviewQueueLogic.Command]) {
        for command in commands {
            switch command {
            case .show(let request):
                overlay.show(request)
            case .updatePolished(let id, let text):
                overlay.setPolished(id: id, text: text, final: true)
            case .armDeadman(let id, let delay):
                if let delay {
                    overlay.resetCountdown(delay)
                    schedule(delay) { [weak self] in self?.deadmanFired(id: id) }
                } else {
                    overlay.showAwaitClick()
                }
            case .copyToClipboard(let text):
                TextInjector.copy(text)
            case .complete(let id, let text):
                complete(id, text)
            case .hide:
                overlay.hide()
            }
        }
    }
}
