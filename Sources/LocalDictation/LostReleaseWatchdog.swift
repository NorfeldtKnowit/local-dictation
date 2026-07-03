import Foundation

/// Pure decision for the lost-release watchdog: when the 120 s timer fires
/// while an utterance is (apparently) still being captured, the physical key
/// state disambiguates the two very different situations:
///
///  - Key still physically down → a GENUINE long hold. Ending it would truncate
///    the dictation mid-sentence and desync the hotkey state machine (the real
///    release would then arrive with nothing recording). Re-arm and keep going.
///  - Key up → the release event really was lost (secure-input focus steal,
///    dropped flagsChanged). End the recording, as the watchdog always did.
///
/// The key-state query is injected as a closure so this logic is unit-testable;
/// production passes `CGEventSource.keyState(.combinedSessionState, key: 61)`
/// (the API takes any virtual keycode, modifiers included — Right Option is 61,
/// the same keycode `HotkeyMonitor` watches).
enum LostReleaseWatchdog {
    enum Decision: Equatable {
        /// Timer fired for an utterance that already ended — do nothing.
        case ignore
        /// Key still physically held: genuine long hold — re-arm for another round.
        case rearm
        /// Key is up: the release was lost — force endRecording.
        case endRecording
    }

    /// - Parameters:
    ///   - isRecording: current capture flag from `UtteranceStateMachine`.
    ///   - recordingID: the utterance currently being captured.
    ///   - firedID: the utterance the timer was armed for.
    ///   - keyStillDown: physical key-state probe (injected).
    static func decide(isRecording: Bool,
                       recordingID: UInt64,
                       firedID: UInt64,
                       keyStillDown: () -> Bool) -> Decision {
        guard isRecording, recordingID == firedID else { return .ignore }
        return keyStillDown() ? .rearm : .endRecording
    }
}
