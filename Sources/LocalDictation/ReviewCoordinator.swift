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
    /// Set by `AppDelegate`: re-run polish on the raw text with a different
    /// template (id) and stream it back via `polishPartial` + `repolishFinished`.
    /// The coordinator can't reach the pipeline/store, so this is the seam.
    var onRepolish: ((_ id: UInt64, _ raw: String, _ templateID: String) -> Void)?

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
        overlay.onBeginEdit = { [weak self] id in
            guard let self else { return }
            Log.info("review: editing id=\(id) (countdown suspended)", "review")
            self.run(self.logic.beginEdit(id: id))
        }
        overlay.onCancelEdit = { [weak self] id in
            guard let self else { return }
            Log.info("review: edit cancelled id=\(id) (countdown resumed)", "review")
            self.run(self.logic.cancelEdit(id: id))
        }
        // Copy: stage the edit on the clipboard, settle without pasting. Log only
        // the char count (privacy — matches TextInjector's prefix-only logging).
        overlay.onCopyEdit = { [weak self] id, text in
            guard let self else { return }
            Log.info("review: copied edit to clipboard id=\(id) (\(text.count) chars)", "review")
            self.run(self.logic.copyEdited(id: id, text: text))
        }
        // Save: a raw edit re-shows pending + re-polishes the NEW raw with the
        // current style; a styled edit updates the rewrite verbatim + re-diffs.
        overlay.onSaveEdit = { [weak self] id, text, editingRaw in
            guard let self else { return }
            if editingRaw {
                Log.info("review: saved edited RAW id=\(id) (\(text.count) chars) — re-polishing", "review")
                self.run(self.logic.saveEditedRaw(id: id, text: text))
                if let current = self.logic.showing, current.id == id {
                    self.onRepolish?(id, current.raw, current.templateID)
                }
            } else {
                Log.info("review: saved edited style id=\(id) (\(text.count) chars)", "review")
                self.run(self.logic.saveEditedPolished(id: id, text: text))
            }
        }
        overlay.onSelectStyle = { [weak self] id, templateID, name in
            guard let self, let current = self.logic.showing, current.id == id else { return }
            let badge = name.uppercased()
            Log.info("review: restyle id=\(id) -> \(templateID)", "review")
            // Drop to pending (suspends the deadman) + repaint with the new
            // badge, then ask AppDelegate to re-polish the RAW text.
            self.run(self.logic.beginRepolish(id: id, badge: badge, templateID: templateID))
            self.overlay.beginRepolish(id: id, badge: badge)
            self.onRepolish?(id, current.raw, templateID)
        }
    }

    /// Supplies the style list (id + display name) for the overlay's in-HUD
    /// style picker. Set by `AppDelegate` from `PromptTemplateStore`.
    func setStylesProvider(_ provider: @escaping () -> [(id: String, name: String)]) {
        overlay.stylesProvider = provider
    }

    /// Show the HUD for a finished utterance (raw text, rewrite pending).
    /// `badge` is the selected template's uppercased name for the rewrite row.
    func enqueue(id: UInt64, raw: String, badge: String = "TERSE", templateID: String = "") {
        run(logic.enqueue(id: id, raw: raw, badge: badge, templateID: templateID))
    }

    /// Display-only streaming update for the TERSE row (not guardrail-checked;
    /// never pasted — the final text arrives via `polishFinished`).
    func polishPartial(id: UInt64, text: String) {
        overlay.setPolished(id: id, text: text, final: false)
    }

    /// The polish stage settled (nil = decline/echo → raw shown for review).
    func polishFinished(id: UInt64, polished: String?) {
        if polished == nil {
            Log.info("review: no rewrite — showing RAW for review id=\(id)", "review")
        }
        run(logic.polishFinished(id: id, polished: polished))
    }

    /// A restyle's re-polish settled (nil = decline/echo → revert to the prior
    /// rewrite). Streaming partials still arrive via `polishPartial`.
    func repolishFinished(id: UInt64, polished: String?) {
        run(logic.repolishFinished(id: id, polished: polished))
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
            Log.info("review: picked=timeout(rewrite; raw -> clipboard) id=\(id)", "review")
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
