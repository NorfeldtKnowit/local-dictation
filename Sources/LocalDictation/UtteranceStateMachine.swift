import Foundation

/// Pure recording/transcription bookkeeping with monotonic utterance IDs.
///
/// Decouples "am I capturing right now" (`isRecording`) from "how many
/// transcriptions are still in flight" (`inFlight`) so a new capture can begin
/// while a previous utterance is still being transcribed — the engines are
/// actors and each call uses a fresh decoder state, so there is no bleed. The
/// monotonic `recordingID` lets watchdogs and completion handlers refer to a
/// specific utterance without ambiguity across rapid press/release cycles.
struct UtteranceStateMachine: Equatable {
    enum Action: Equatable {
        case startCapture(id: UInt64)
        case stopCaptureAndProcess(id: UInt64)
        case ignore
    }

    private(set) var isRecording = false
    private(set) var recordingID: UInt64 = 0
    private(set) var inFlight: Set<UInt64> = []

    /// Set by `AppDelegate` once default engines have warmed up; `begin` is a
    /// no-op until then so a press before `model ready` can't start a doomed capture.
    var engineReady = false

    /// Hotkey press / toggle-on. Ignored while already recording or before readiness.
    mutating func begin() -> Action {
        guard engineReady, !isRecording else { return .ignore }
        recordingID &+= 1
        isRecording = true
        return .startCapture(id: recordingID)
    }

    /// Release / toggle-off / watchdog / runtime error. Ignored if not recording.
    mutating func end() -> Action {
        guard isRecording else { return .ignore }
        isRecording = false
        inFlight.insert(recordingID)
        return .stopCaptureAndProcess(id: recordingID)
    }

    /// Mark an utterance's transcription as finished (success, drop, or error).
    mutating func settled(_ id: UInt64) { inFlight.remove(id) }

    /// Menu-state precedence: listening (isRecording) outranks transcribing,
    /// which outranks idle. This flag feeds the "transcribing" rung.
    var isTranscribing: Bool { !inFlight.isEmpty }
}
