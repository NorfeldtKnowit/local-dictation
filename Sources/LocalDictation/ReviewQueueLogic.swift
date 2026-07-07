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
    let raw: String
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

    mutating func enqueue(id: UInt64, raw: String) -> [Command] {
        let request = ReviewRequest(id: id, raw: raw)
        guard showing == nil else {
            queue.append(request)
            return []
        }
        showing = request
        rearmsUsed = 0
        return [.show(request)]
    }

    /// The polish stage settled for utterance `id` (always happens — the
    /// backends have their own timeouts). nil / verbatim echo means there is
    /// nothing to choose between: the shown request completes with raw
    /// immediately. A real rewrite updates the display and arms the deadman.
    /// Applies equally to a request still waiting in the queue.
    mutating func polishFinished(id: UInt64, polished: String?) -> [Command] {
        if var current = showing, current.id == id {
            guard let polished, polished != current.raw else {
                return finish(current, text: current.raw)
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

    /// The scheduled deadman fired. Stale firings are identified by ID and
    /// ignored; it is only ever armed once a rewrite exists. A fire while
    /// hovering re-arms instead of deciding — but only `maxHoverRearms`
    /// times. The unattended decision is the REWRITE, with the raw candidate
    /// staged on the clipboard for recovery.
    mutating func deadmanFired(id: UInt64, hovering: Bool) -> [Command] {
        guard let current = showing, current.id == id,
              case .rewrite(let rewrite) = current.polish else { return [] }
        if hovering && rearmsUsed < Self.maxHoverRearms {
            rearmsUsed += 1
            return [.armDeadman(id: id, delay: Self.hoverGrace)]
        }
        return [.copyToClipboard(current.raw)] + finish(current, text: rewrite)
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
        var commands: [Command] = [.complete(id: current.id, text: text), .hide]
        // Drain queued requests whose polish already settled with nothing to
        // review — showing them would flash a single-candidate overlay.
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if next.polish == .none {
                commands.append(.complete(id: next.id, text: next.raw))
                continue
            }
            showing = next
            rearmsUsed = 0
            commands.append(.show(next))
            if case .rewrite = next.polish {
                commands.append(.armDeadman(id: next.id, delay: deadmanDelay(for: next)))
            }
            break
        }
        return commands
    }
}
