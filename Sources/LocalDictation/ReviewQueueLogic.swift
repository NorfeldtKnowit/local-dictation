import Foundation

/// One utterance's review candidates: the filtered ASR text (the safe default
/// the timeout falls back to) and the terse LLM rewrite the user may prefer.
struct ReviewRequest: Equatable, Sendable {
    let id: UInt64
    let raw: String
    let polished: String
}

/// The pure half of the "Review Before Paste" overlay: FIFO of pending
/// utterances, one overlay at a time, and a decide-EXACTLY-once guarantee per
/// utterance ID — every request eventually emits `.complete(id:text:)`, or the
/// `PasteSequencer` behind it would stall forever (its documented contract).
///
/// Liveness never depends on UI callbacks: `.show`/`.rearmDeadman` instruct the
/// caller to schedule `deadmanFired(id:hovering:)` via an UNcancellable timer
/// (the `DispatchQueue.main.asyncAfter` pattern `PasteSequencer` uses); stale
/// firings are ignored by the ID guard, the same `firedID` idiom as
/// `LostReleaseWatchdog`. The timeout decision is the POLISHED text with the
/// raw staged on the clipboard: the user's live verdict (2026-07-07) was that
/// the countdown is too short to actually read both candidates, so the default
/// should be the version they enabled review FOR — with the raw one a Cmd+V
/// away if the rewrite lost something.
struct ReviewQueueLogic {
    enum Command: Equatable {
        /// Present the overlay for `request`; when `timeout` is non-nil, also
        /// schedule `deadmanFired(id: request.id)` after it (nil = `.never`
        /// policy: wait for a click, no deadman).
        case show(ReviewRequest, timeout: TimeInterval?)
        /// Re-schedule the deadman WITHOUT re-presenting (it fired while the
        /// pointer hovered the overlay — the user is reading, give them time).
        case rearmDeadman(id: UInt64, delay: TimeInterval)
        /// Stage this text on the clipboard (the raw candidate on a timeout
        /// auto-pick, so the un-chosen version stays recoverable). Ordered
        /// BEFORE the `.complete` so paste-mode's snapshot/restore cycle ends
        /// with this text on the clipboard.
        case copyToClipboard(String)
        /// Hand the decided text to the paste sequencer ("" = dismissed).
        case complete(id: UInt64, text: String)
        /// Take the overlay down (always paired with a `.complete`).
        case hide
    }

    /// When (if ever) an unattended overlay decides itself.
    enum TimeoutPolicy: Equatable {
        /// Length-scaled 5-15 s (see `timeout(forCharacterCount:)`).
        case auto
        /// A fixed number of seconds, user-chosen from the menu.
        case fixed(TimeInterval)
        /// No deadman at all: the overlay waits for a click. Later utterances
        /// queue behind it (visibly — the HUD is on screen), by explicit
        /// user choice.
        case never

        /// Menu `representedObject` decoding: "auto" | "never" | seconds.
        static func from(code: String) -> TimeoutPolicy {
            switch code {
            case "auto":  return .auto
            case "never": return .never
            default:      return Double(code).map { .fixed($0) } ?? .auto
            }
        }
    }

    enum Choice: Equatable {
        case raw
        case polished
        case dismiss
    }

    /// Only a polished outcome whose rewrite genuinely differs is worth a
    /// review round-trip; everything else should paste directly.
    static func needsReview(asrText: String, text: String, polished: Bool) -> Bool {
        polished && !asrText.isEmpty && asrText != text
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
    /// `.show` (a deadman already scheduled for the current overlay stands).
    var policy: TimeoutPolicy = .auto

    private(set) var showing: ReviewRequest?
    private var queue: [ReviewRequest] = []
    private var rearmsUsed = 0

    mutating func enqueue(_ request: ReviewRequest) -> [Command] {
        guard showing == nil else {
            queue.append(request)
            return []
        }
        showing = request
        rearmsUsed = 0
        return [.show(request, timeout: timeout(for: request))]
    }

    private func timeout(for request: ReviewRequest) -> TimeInterval? {
        switch policy {
        case .auto:              return Self.timeout(forCharacterCount: request.raw.count)
        case .fixed(let seconds): return seconds
        case .never:             return nil
        }
    }

    /// The user clicked a candidate (or the dismiss control). `id` is the
    /// request the click was VISUALLY aimed at (captured when the overlay was
    /// built): a click racing the auto-advance to a later request must no-op,
    /// not decide that request sight-unseen — the same stale-firing guard the
    /// deadman uses.
    mutating func choose(id: UInt64, _ choice: Choice) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        let text: String
        switch choice {
        case .raw:      text = current.raw
        case .polished: text = current.polished
        case .dismiss:  text = ""
        }
        return finish(current, text: text)
    }

    /// The scheduled deadman fired. Stale firings (the overlay already decided
    /// and possibly moved on to a later request) are identified by ID and
    /// ignored. A fire while hovering re-arms instead of deciding — but only
    /// `maxHoverRearms` times. The unattended decision is the POLISHED text,
    /// with the raw candidate staged on the clipboard for recovery.
    mutating func deadmanFired(id: UInt64, hovering: Bool) -> [Command] {
        guard let current = showing, current.id == id else { return [] }
        if hovering && rearmsUsed < Self.maxHoverRearms {
            rearmsUsed += 1
            return [.rearmDeadman(id: id, delay: Self.hoverGrace)]
        }
        return [.copyToClipboard(current.raw)] + finish(current, text: current.polished)
    }

    private mutating func finish(_ current: ReviewRequest, text: String) -> [Command] {
        showing = nil
        var commands: [Command] = [.complete(id: current.id, text: text), .hide]
        if !queue.isEmpty {
            let next = queue.removeFirst()
            showing = next
            rearmsUsed = 0
            commands.append(.show(next, timeout: timeout(for: next)))
        }
        return commands
    }
}
