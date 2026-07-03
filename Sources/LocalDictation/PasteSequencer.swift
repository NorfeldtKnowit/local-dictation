import Foundation

/// Reorders utterance outcomes into strict utterance-ID order before pasting,
/// and enforces a minimum spacing between consecutive actual pastes.
///
/// Why it exists: overlapping utterances (a new capture may start while the
/// previous one is still transcribing) finish in COMPLETION order, not spoken
/// order — a slow Whisper utterance followed by a fast Parakeet one would paste
/// backwards. And two pastes fired < 200 ms apart interleave with
/// `TextInjector`'s pasteboard save → Cmd+V → restore window (0.20 s), so the
/// second utterance can paste the restored OLD clipboard instead of its text.
///
/// Rules (pure, unit-tested — see `PasteSequencerTests`):
///  - `complete(id:text:)` buffers text under its monotonic utterance ID
///    (`UtteranceStateMachine` allocates 1, 2, 3, …).
///  - The flush loop pastes strictly in ID order; a missing ID blocks the queue
///    until it completes.
///  - Empty text (gated / hallucination-filtered / errored / never-captured
///    utterances) still ADVANCES the sequence — it just doesn't paste.
///  - Consecutive actual pastes are >= `minSpacing` apart (default 300 ms, safely
///    past the 200 ms pasteboard-restore window); the continuation of a spaced
///    flush is handed to the injected `schedule` closure.
///
/// All side effects (clock, timer, the actual paste) are injected closures so
/// the ordering/spacing logic is testable without AppKit. `AppDelegate` owns the
/// single instance and drives it from the main actor; the type itself is not
/// thread-safe and must be used from one serial context.
final class PasteSequencer {
    private let minSpacing: TimeInterval
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let paste: (String) -> Void

    /// The next utterance ID allowed to paste. IDs below it are already settled.
    private var nextID: UInt64
    /// Completed-but-not-yet-flushed outcomes, keyed by utterance ID.
    private var pending: [UInt64: String] = [:]
    /// When the last actual paste happened (nil until the first one).
    private var lastPasteAt: Date?
    /// True while a spacing continuation is scheduled; suppresses re-entry so
    /// only one timer chain drives the flush at a time.
    private var flushScheduled = false

    /// - Parameters:
    ///   - firstID: the first utterance ID that will ever complete
    ///     (`UtteranceStateMachine` starts at 1).
    ///   - minSpacing: minimum interval between consecutive actual pastes.
    ///   - now: clock (injectable for tests).
    ///   - schedule: run a closure after a delay (production: main-queue
    ///     `asyncAfter`; tests: capture + fire manually).
    ///   - paste: the actual injection (production: `TextInjector.paste`).
    init(firstID: UInt64 = 1,
         minSpacing: TimeInterval = 0.3,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         paste: @escaping (String) -> Void) {
        self.nextID = firstID
        self.minSpacing = minSpacing
        self.now = now
        self.schedule = schedule
        self.paste = paste
    }

    /// Record utterance `id`'s final text ("" for gated/empty/error outcomes —
    /// those still advance the sequence) and flush whatever is now in order.
    func complete(id: UInt64, text: String) {
        guard id >= nextID else { return }   // double-settle guard; already flushed
        pending[id] = text
        flush()
    }

    private func flush() {
        guard !flushScheduled else { return }   // a spacing timer already owns the queue
        while let text = pending[nextID] {
            if text.isEmpty {
                // Advance-on-empty: nothing to paste, but later IDs must not
                // wait behind a gated/errored utterance forever.
                pending.removeValue(forKey: nextID)
                nextID &+= 1
                continue
            }
            let sinceLast = lastPasteAt.map { now().timeIntervalSince($0) } ?? .infinity
            if sinceLast < minSpacing {
                // Too soon after the previous paste — resume once the
                // pasteboard-restore window has safely passed.
                flushScheduled = true
                schedule(minSpacing - sinceLast) { [weak self] in
                    guard let self else { return }
                    self.flushScheduled = false
                    self.flush()
                }
                return
            }
            pending.removeValue(forKey: nextID)
            nextID &+= 1
            lastPasteAt = now()
            paste(text)
        }
    }
}
