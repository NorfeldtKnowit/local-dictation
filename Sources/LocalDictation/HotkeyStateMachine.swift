import Foundation

/// Pure press/release/disable bookkeeping for the Right Option push-to-talk key.
///
/// Extracted from `HotkeyMonitor` so the tricky "is this a press or a release,
/// and did the tap die mid-hold?" logic can be unit tested without a live
/// `CGEventTap`. `HotkeyMonitor` keeps all the tap create / re-enable / debounced
/// recreate / synthetic-release *plumbing*; it delegates only the `isDown`
/// decision to this struct.
struct HotkeyStateMachine: Equatable {
    enum Transition: Equatable { case pressed, released }

    /// Whether we currently believe the key is held.
    private(set) var isDown = false

    /// Feed a flagsChanged reading. `optionHeld` is the alternate-modifier bit
    /// for the Right Option key. Returns the transition to emit, or nil if the
    /// reading is a duplicate of the current state (no edge).
    mutating func handleFlagsChanged(optionHeld: Bool) -> Transition? {
        if optionHeld && !isDown {
            isDown = true
            return .pressed
        } else if !optionHeld && isDown {
            isDown = false
            return .released
        }
        return nil
    }

    /// The tap was disabled (timeout / user input). If we believed the key was
    /// held, the matching real release was almost certainly swallowed while the
    /// tap was dead — synthesize a release so recording can't get stuck on.
    /// A no-op (nil) if we were already idle.
    mutating func handleTapDisabledWhileHeld() -> Transition? {
        guard isDown else { return nil }
        isDown = false
        return .released
    }
}
