import Foundation

/// Glue between the pure `ReviewQueueLogic` and the world: executes its
/// commands against the overlay controller, schedules deadman firings through
/// an injected (deliberately uncancellable) timer, and hands every decided
/// text to the injected `complete` — which is `pasteSequencer.complete` in
/// production, so the sequencer's every-ID-settles contract is preserved on
/// every path (click, dismiss, timeout).
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

    func enqueue(id: UInt64, raw: String, polished: String) {
        run(logic.enqueue(ReviewRequest(id: id, raw: raw, polished: polished)))
    }

    /// Applies from the next overlay; a deadman already in flight stands.
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
            case .show(let request, let timeout):
                overlay.show(request, timeout: timeout)
                if let timeout {
                    schedule(timeout) { [weak self] in self?.deadmanFired(id: request.id) }
                }
            case .rearmDeadman(let id, let delay):
                overlay.resetCountdown(delay)
                schedule(delay) { [weak self] in self?.deadmanFired(id: id) }
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
