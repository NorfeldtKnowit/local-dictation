import Foundation
import FluidAudio

/// A source of pre-ASR gate decisions. This tiny seam exists purely so
/// `DictationPipeline` can be unit-tested with a fake gate that returns canned
/// `SpeechGate.Outcome`s, without ever downloading the Silero VAD model.
/// `SpeechGate` (the real, model-backed actor below) is the only production
/// conformer.
///
/// `warmUp()` is part of the seam because the pipeline warms the gate as one of
/// its launch-time defaults (alongside Parakeet); fakes implement it as a no-op.
protocol GateProviding: Sendable {
    /// Best-effort model load. Fail-open, never throws (see `SpeechGate.warmUp`).
    func warmUp() async
    /// Gate + trim one utterance.
    func evaluate(_ samples: [Float]) async -> SpeechGate.Outcome
}

/// Degradable pre-ASR speech gate. Owns FluidAudio's Silero VAD model and runs
/// it once per utterance to (a) reject silence / accidental taps before any
/// expensive ASR call and (b) trim the buffer down to the padded speech regions
/// — the single highest-leverage measure against Whisper silence "ghost"
/// hallucinations (phantom subtitles, "thanks for watching", …).
///
/// The gate is deliberately an OPTIONAL guard, never a hard dependency. If the
/// Silero model can't be downloaded/loaded (offline first launch, corrupt
/// cache, …) the gate fails OPEN: it passes the raw buffer straight through so
/// dictation still works, just without silence trimming. That is why `warmUp()`
/// never throws to its caller and `evaluate()` never throws at all — a missing
/// VAD must never be able to break dictation.
///
/// All decision + trim arithmetic lives in the pure `SpeechGateLogic` so it is
/// unit-testable without a model; this actor only runs the model and delegates.
actor SpeechGate: GateProviding {
    /// Result of gating one utterance. `audio` is the buffer to hand to ASR
    /// (trimmed to speech on `.pass`, the raw buffer when VAD is unavailable,
    /// and empty when the utterance was dropped).
    struct Outcome: Sendable {
        let decision: GateDecision
        let audio: [Float]
    }

    /// nil until `warmUp()` succeeds, and *stays* nil if the model failed to
    /// load — its nil-ness is exactly the degraded / fail-open flag.
    private var vad: VadManager?

    /// Lowered from FluidAudio's library default of 0.85. At 0.85 quiet Danish
    /// speech under-triggers: the VAD misses soft onsets and marks real speech
    /// as silence, so a genuine dictation gets dropped. 0.70 is more permissive.
    /// The asymmetry justifies it — a false *accept* is cheap (one Parakeet call
    /// at ~100x real-time, and the post-ASR `HallucinationFilter` still guards
    /// the output), whereas a false *reject* silently swallows real speech, the
    /// worse failure for a dictation tool.
    static let vadThreshold: Float = 0.70

    /// Segmentation tuning. Two fields deviate from the library defaults where
    /// those defaults hurt push-to-talk dictation; the rest are restated at
    /// their defaults for clarity/pinning:
    /// - `minSilenceDuration` 0.50 (lib 0.75): the default merges natural
    ///   between-sentence pauses into one giant segment; 0.50 keeps regions
    ///   distinct without chopping mid-word.
    /// - `speechPadding` 0.15 (lib 0.10): a little extra pad protects soft
    ///   onsets and trailing plosives from being clipped off by the trim.
    /// (`speechPadding` must be <= `minSpeechDuration` — the library asserts it —
    /// so both sit at 0.15.)
    static let segConfig = VadSegmentationConfig(
        minSpeechDuration: 0.15,
        minSilenceDuration: 0.50,
        maxSpeechDuration: 14.0,
        speechPadding: 0.15,
        silenceThresholdForSplit: 0.30
    )

    /// Load the Silero VAD model. Idempotent. Best-effort: on any failure we log
    /// and stay in fail-open (degraded) mode rather than propagating — the gate
    /// is an optional guard, so a load failure must not surface to the caller.
    func warmUp() async {
        guard vad == nil else { return }   // idempotent
        do {
            vad = try await VadManager(config: VadConfig(defaultThreshold: Self.vadThreshold))
            Log.info("VAD warmed up (threshold=\(Self.vadThreshold))", "vad")
        } catch {
            Log.warn("VAD unavailable — gating degraded to duration-only: \(error)", "vad")
        }
    }

    /// Gate one utterance. Never throws: a VAD runtime error degrades that call
    /// to fail-open. Returns the decision plus the audio to transcribe.
    func evaluate(_ samples: [Float]) async -> Outcome {
        // Accidental-tap floor: below ~0.30 s of raw audio, don't even touch VAD.
        guard samples.count >= SpeechGateLogic.minRawSamples else {
            return Outcome(decision: .tooShort, audio: [])
        }
        // No model (never warmed, or load failed): fail OPEN, transcribe raw.
        guard let vad else {
            return Outcome(decision: .vadUnavailable, audio: samples)
        }
        // One segmentation pass. A thrown VAD error collapses to nil, which the
        // pure logic reads as "VAD unavailable" — fail open again for this call.
        let segments = try? await vad.segmentSpeech(samples, config: Self.segConfig)
        let decision = SpeechGateLogic.decide(totalSamples: samples.count, segments: segments)
        switch decision {
        case .pass:
            // `decide` only returns `.pass` when `segments` was non-nil and met
            // the speech floor; `?? []` keeps this total (no force-unwrap) while
            // trimming to the padded speech regions.
            return Outcome(decision: .pass, audio: SpeechGateLogic.trim(samples, segments: segments ?? []))
        case .vadUnavailable:
            return Outcome(decision: .vadUnavailable, audio: samples)
        case .tooShort, .silence:
            return Outcome(decision: decision, audio: [])
        }
    }
}
