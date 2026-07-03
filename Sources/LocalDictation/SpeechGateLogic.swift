import Foundation
import FluidAudio

/// Outcome of the pre-ASR speech gate.
/// - `pass`: enough speech; transcribe (after trimming to speech regions).
/// - `tooShort`: raw buffer below the accidental-tap floor; drop, no model touched.
/// - `silence`: VAD ran but found too little speech; drop (kills Whisper silence ghosts).
/// - `vadUnavailable`: VAD model absent/failed; fail OPEN and transcribe the raw buffer.
///
/// String-backed so the raw value IS the stable name the CLI emits in its JSON
/// and stderr summaries (and that `scripts/test-cli.sh` greps for) — one source
/// of truth, no separate name-mapping to drift.
enum GateDecision: String, Equatable, Sendable { case pass, tooShort, silence, vadUnavailable }

/// Pure, model-free gate logic. Kept separate from `SpeechGate` (the actor that
/// owns the VAD model) precisely so this decision + trim math is unit-testable
/// without downloading Silero. `SpeechGate` runs the model, then hands the raw
/// sample count and resulting segments here.
enum SpeechGateLogic {
    static let sampleRate = 16_000
    static let minRawSamples = 4_800          // 0.30 s — below this, skip VAD entirely (accidental tap)
    static let minSpeechSeconds = 0.35        // total VAD speech required (> Parakeet's ~0.30 s floor)

    /// Decide whether to transcribe. `segments == nil` means VAD was unavailable
    /// (never ran), which we treat as fail-open rather than as silence.
    static func decide(totalSamples: Int, segments: [VadSegment]?) -> GateDecision {
        guard totalSamples >= minRawSamples else { return .tooShort }
        guard let segments else { return .vadUnavailable }               // VAD down → fail OPEN
        let speech = segments.reduce(0.0) { $0 + $1.duration }
        return speech >= minSpeechSeconds ? .pass : .silence
    }

    /// Concatenate the padded speech regions into one buffer, dropping the
    /// silence between/around them (the single highest-leverage Whisper
    /// anti-ghost measure; also shrinks the ASR input). Padding is already
    /// applied by `VadSegmentationConfig.speechPadding`. Segment bounds are
    /// clamped into `samples` so a rounding overshoot can't crash.
    static func trim(_ samples: [Float], segments: [VadSegment]) -> [Float] {
        segments.flatMap { seg -> ArraySlice<Float> in
            let s = max(0, min(seg.startSample(sampleRate: sampleRate), samples.count))
            let e = max(s, min(seg.endSample(sampleRate: sampleRate), samples.count))
            return samples[s..<e]
        }
    }
}
