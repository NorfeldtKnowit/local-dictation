import Foundation

/// One utterance under review: the filtered ASR text (shown immediately) and
/// the rewrite, which STREAMS in after the HUD is already visible.
struct ReviewRequest: Equatable, Sendable {
    enum PolishState: Equatable, Sendable {
        /// The rewrite is still being generated (HUD shows a progress row).
        case pending
        /// Polish declined or echoed the raw text — nothing to review.
        case none
        /// A genuinely different rewrite, safe to paste (guardrail-checked).
        case rewrite(String)
    }

    let id: UInt64
    /// The filtered ASR text. Mutable because a Save of an edited RAW candidate
    /// replaces it with the user's text and re-polishes from there.
    var raw: String
    /// Uppercased display name of the polish template driving the rewrite row
    /// (e.g. "TERSE", "GENZ") — the second candidate's badge and countdown label.
    var badge: String = "TERSE"
    /// Template id that produced (or will produce) the rewrite row — carried so a
    /// Save of an edited RAW can re-polish with the same style. Display-only to
    /// the logic (like `badge`); only the coordinator interprets it.
    var templateID: String = ""
    var polish: PolishState = .pending
}

/// The pure half of the "Review Before Paste" overlay: FIFO of pending
/// utterances, one overlay at a time, and a decide-EXACTLY-once guarantee per
/// utterance ID — every request eventually emits `.complete(id:text:)`, or the
/// `PasteSequencer` behind it would stall forever (its documented contract).
///
/// Streaming flow: the HUD `.show`s with the raw text the moment ASR
/// finishes; the rewrite streams into it (display-only partials bypass this
/// logic); `polishFinished(id:polished:)` then either completes immediately
/// (no usable rewrite → paste raw, nothing to review) or arms the deadman per
/// the auto-insert policy. Liveness never depends on UI callbacks: deadman
/// firings come from an UNcancellable injected timer with stale firings
/// ignored by ID (`LostReleaseWatchdog`'s `firedID` idiom), and the pending
/// state is bounded by the polish backends' own timeouts (6 s FM / 30 s MLX),
/// after which `polishFinished` always arrives.
///
/// The unattended (timeout) decision is the REWRITE with the raw staged on
/// the clipboard: the user's live verdict (2026-07-07) was that the countdown
/// is too short to actually read both, so the default should be the version
/// review exists for — with raw one Cmd+V away.
struct ReviewQueueLogic {
    enum Command: Equatable {
        /// Present the overlay for `request` (rendering its `polish` state).
        /// Presentation only — deadman scheduling is a separate command.
        case show(ReviewRequest)
        /// Display the final accepted rewrite (replaces streamed partials).
        case updatePolished(id: UInt64, text: String)
        /// Schedule `deadmanFired(id:)` after `delay`, and show the countdown.
        /// nil delay = `.never` policy: no deadman, show the click prompt.
        case armDeadman(id: UInt64, delay: TimeInterval?)
        /// Stage this text on the clipboard (the raw candidate on a timeout
        /// auto-pick). Ordered BEFORE `.complete` so paste-mode's clipboard
        /// snapshot/restore ends with this text on the clipboard.
        case copyToClipboard(String)
        /// Hand the decided text to the paste sequencer ("" = dismissed).
        case complete(id: UInt64, text: String)
        /// Take the overlay down.
        case hide
    }

    enum Choice: Equatable {
        case raw
        case polished
        case dismiss
    }

    /// When (if ever) an unattended overlay decides itself.
    enum TimeoutPolicy: Equatable {
        case auto                    // length-scaled 5-15 s
        case fixed(TimeInterval)     // user-chosen from the menu
        case never                   // wait for a click

        /// Menu `representedObject` decoding: "auto" | "never" | seconds.
        static func from(code: String) -> TimeoutPolicy {
            switch code {
            case "auto":  return .auto
            case "never": return .never
            default:      return Double(code).map { .fixed($0) } ?? .auto
            }
        }
    }

    /// Reading time scales with transcript length: ~5 s for a short sentence,
    /// capped at 15 s so a forgotten overlay can't block later utterances long.
    static func timeout(forCharacterCount count: Int) -> TimeInterval {
        min(15, max(5, Double(count) / 40))
    }

    /// Deadman re-arm interval while the pointer hovers the overlay.
    static let hoverGrace: TimeInterval = 5

    /// Hovering can defer the decision only this many times (~20 s extra):
    /// the PasteSequencer flushes in strict ID order, so a pointer parked on
    /// the overlay must not be able to stall every later utterance forever.
    static let maxHoverRearms = 4

    /// Set from the menu's Review Auto-Insert choice; applies from the next
    /// deadman arming (one already scheduled stands).
    var policy: TimeoutPolicy = .auto

    private(set) var showing: ReviewRequest?
    private var queue: [ReviewRequest] = []
    private var rearmsUsed = 0
    /// True while the shown request is being hand-edited in the overlay. The
    /// countdown is fully suspended: a deadman that fires mid-edit is ignored
    /// and NOT re-armed, so nothing auto-inserts while the user is typing.
    /// Cleared on cancel (re-arms) or on any settle. An abandoned edit leaves
    /// the utterance pending and later ones queued behind it — the same,
    /// already-sanctioned tradeoff as the `.never` auto-insert policy.
    private var isEditing = false
    /// The rewrite that was on screen when a restyle (re-polish) began, kept so
    /// a declined/echoed re-polish reverts to it instead of collapsing the
    /// overlay. Cleared once the re-polish settles or the request finishes.
    private var priorRewrite: String?

    mutating func enqueue(id: UInt64, raw: String, badge: String = "TERSE",
                          templateID: String = "") -> [Command] {
        let request = ReviewRequest(id: id, raw: raw, badge: badge, templateID: templateID)
        guard showing == nil else {
            queue.append(request)
            return []
        }
        showing = request
        rearmsUsed = 0
        return [.show(request)]
    }

    /// The polish stage settled for utterance `id` (always happens — the
    /// backends have their own timeouts). A real rewrite updates the display
    /// and arms the deadman. nil / verbatim echo means there is no distinct
    /// rewrite — but "Review Before Paste" must STILL let the user review, so
    /// the overlay stays up showing the RAW alone (editable/dismissable, with
    /// the deadman auto-inserting raw); it never silently pastes. Applies
    /// equally to a request still waiting in the queue.
    mutating func polishFinished(id: UInt64, polished: String?) -> [Command] {
        if var current = showing, current.id == id {
            guard let polished, polished != current.raw else {
                current.polish = .none
                showing = current
                return [.show(current),
                        .armDeadman(id: id, delay: deadmanDelay(for: current))]
            }
            current.polish = .rewrite(polished)
            showing = current
            return [.updatePolished(id: id, text: polished),
                    .armDeadman(id: id, delay: deadmanDelay(for: current))]
        }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            if let polished, polished != queue[index].raw {
                queue[index].polish = .rewrite(polished)
            } else {
                queue[index].polish = .none
            }
        }
        return []
    }

    /// The user clicked a candidate (or the dismiss control). `id` is the
    /// request the click was VISUALLY aimed at (captured when the overlay was
    /// built): a click racing the auto-advance to a later request must no-op,
    /// not decide that request sight-unseen. Choosing the rewrite before it
    /// exists is also a no-op.
    mutating func choose(id: UInt64, _ choice: Choice) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        let text: String
        switch choice {
        case .raw:
            text = current.raw
        case .polished:
            guard case .rewrite(let rewrite) = current.polish else { return [] }
            text = rewrite
        case .dismiss:
            text = ""
        }
        return finish(current, text: text)
    }

    /// The user chose "Copy" in the inline editor: stage the edited text on the
    /// clipboard and settle the utterance WITHOUT pasting. Editing almost always
    /// moves the caret in the target app, so a synthetic paste would land in the
    /// wrong place — copy, then let the user paste where they now are. Completing
    /// with "" keeps the sequencer's every-ID-settles contract; because an empty
    /// complete never pastes (so never snapshots/restores the pasteboard), the
    /// staged clipboard text survives. `copyToClipboard` is ordered FIRST for the
    /// same reason. An empty edit is just a dismiss. A no-op for a stale/queued id.
    mutating func copyEdited(id: UInt64, text: String) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        guard !text.isEmpty else { return finish(current, text: "") }
        return [.copyToClipboard(text)] + finish(current, text: "")
    }

    /// The user opened the inline editor for the shown request. Suspends the
    /// countdown (see `isEditing`); a no-op for a stale/queued id.
    mutating func beginEdit(id: UInt64) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        isEditing = true
        return []
    }

    /// The user backed out of the editor without committing. Resumes the
    /// normal countdown from scratch; a no-op for a stale/queued id or when
    /// not editing.
    mutating func cancelEdit(id: UInt64) -> [Command] {
        guard isEditing, let current = showing, current.id == id else { return [] }
        isEditing = false
        return [.armDeadman(id: id, delay: deadmanDelay(for: current))]
    }

    /// The user chose "Save" while editing the RAW candidate. The edited text
    /// becomes the new raw and the row drops back to `.pending` (which suspends
    /// the deadman, exactly like a restyle) so the caller can re-polish the NEW
    /// raw with the current style; the streamed rewrite flows back through
    /// `repolishFinished`. `priorRewrite` is cleared: a declined re-polish must
    /// fall to a raw-only review of the NEW raw, never revert to a rewrite of the
    /// old one. A no-op for a stale/queued id.
    mutating func saveEditedRaw(id: UInt64, text: String) -> [Command] {
        guard var current = showing, current.id == id else { return [] }
        isEditing = false
        priorRewrite = nil
        current.raw = text
        current.polish = .pending
        showing = current
        return [.show(current)]
    }

    /// The user chose "Save" while editing the styled candidate. The edited text
    /// becomes the rewrite VERBATIM — the user authored it, so the polish
    /// guardrails don't apply — and the HUD re-renders (raw↔terse diff) and
    /// re-arms the countdown. An emptied edit degrades to a raw-only review
    /// rather than showing an empty rewrite row. A no-op for a stale/queued id.
    mutating func saveEditedPolished(id: UInt64, text: String) -> [Command] {
        guard var current = showing, current.id == id else { return [] }
        isEditing = false
        priorRewrite = nil
        current.polish = text.isEmpty ? .none : .rewrite(text)
        showing = current
        return [.show(current), .armDeadman(id: id, delay: deadmanDelay(for: current))]
    }

    /// The user picked a different polish style for the shown request. Stashes
    /// the current rewrite (so a declined re-polish can revert) and drops the
    /// row back to `.pending` with the new badge — which also suspends the
    /// deadman, since `deadmanFired` only fires on a settled `.rewrite`. The
    /// caller (AppDelegate) then re-runs polish on the raw and reports back via
    /// `repolishFinished`. A no-op for a stale/queued id.
    mutating func beginRepolish(id: UInt64, badge: String, templateID: String = "") -> [Command] {
        guard var current = showing, current.id == id else { return [] }
        if case .rewrite(let rewrite) = current.polish { priorRewrite = rewrite }
        current.badge = badge
        current.templateID = templateID
        current.polish = .pending
        showing = current
        return []
    }

    /// A restyle's re-polish settled. A usable rewrite replaces the row and
    /// re-arms the countdown; a decline/echo reverts to the pre-restyle rewrite
    /// (never collapses the overlay the user is actively working). A no-op for a
    /// stale/queued id.
    mutating func repolishFinished(id: UInt64, polished: String?) -> [Command] {
        guard var current = showing, current.id == id else { return [] }
        if let polished, polished != current.raw {
            current.polish = .rewrite(polished)
            showing = current
            priorRewrite = nil
            return [.updatePolished(id: id, text: polished),
                    .armDeadman(id: id, delay: deadmanDelay(for: current))]
        }
        // Declined/echoed re-polish: revert to the pre-restyle rewrite if there
        // was one, else fall back to raw-only review (same as a first-polish
        // decline) — never collapse the overlay the user is working.
        if let prior = priorRewrite {
            current.polish = .rewrite(prior)
            showing = current
            priorRewrite = nil
            return [.updatePolished(id: id, text: prior),
                    .armDeadman(id: id, delay: deadmanDelay(for: current))]
        }
        current.polish = .none
        showing = current
        return [.show(current),
                .armDeadman(id: id, delay: deadmanDelay(for: current))]
    }

    /// The scheduled deadman fired. Stale firings are identified by ID and
    /// ignored; it is only ever armed once a rewrite exists. A fire while
    /// hovering re-arms instead of deciding — but only `maxHoverRearms`
    /// times. The unattended decision is the REWRITE, with the raw candidate
    /// staged on the clipboard for recovery.
    mutating func deadmanFired(id: UInt64, hovering: Bool) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        // What the unattended timeout inserts: the rewrite if there is one, else
        // the raw (a raw-only review of a declined polish). Still pending =
        // nothing settled yet, so the fire is a no-op.
        let autoText: String
        switch current.polish {
        case .rewrite(let rewrite): autoText = rewrite
        case .none:                 autoText = current.raw
        case .pending:              return []
        }
        // Editing fully suspends the countdown: ignore the fire and do NOT
        // re-arm, so the user's in-progress text is never auto-inserted.
        if isEditing { return [] }
        if hovering && rearmsUsed < Self.maxHoverRearms {
            rearmsUsed += 1
            return [.armDeadman(id: id, delay: Self.hoverGrace)]
        }
        // A rewrite auto-pick stages raw on the clipboard for recovery; a
        // raw-only pick already IS the raw, so there is nothing to stage.
        if case .none = current.polish {
            return finish(current, text: autoText)
        }
        return [.copyToClipboard(current.raw)] + finish(current, text: autoText)
    }

    private func deadmanDelay(for request: ReviewRequest) -> TimeInterval? {
        switch policy {
        case .auto:               return Self.timeout(forCharacterCount: request.raw.count)
        case .fixed(let seconds): return seconds
        case .never:              return nil
        }
    }

    private mutating func finish(_ current: ReviewRequest, text: String) -> [Command] {
        showing = nil
        isEditing = false
        priorRewrite = nil
        var commands: [Command] = [.complete(id: current.id, text: text), .hide]
        // Show the next queued request. A settled one (rewrite OR declined
        // raw-only) is shown and armed; a still-pending one is shown and arms
        // when its polish settles. "Review Before Paste" reviews every
        // utterance — including declined ones (raw-only), which is why a `.none`
        // is no longer drained silently.
        if !queue.isEmpty {
            let next = queue.removeFirst()
            showing = next
            rearmsUsed = 0
            commands.append(.show(next))
            switch next.polish {
            case .rewrite, .none:
                commands.append(.armDeadman(id: next.id, delay: deadmanDelay(for: next)))
            case .pending:
                break
            }
        }
        return commands
    }
}
