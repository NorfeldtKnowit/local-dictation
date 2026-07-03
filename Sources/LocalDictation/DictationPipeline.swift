import Foundation

/// The single place where gate → route → transcribe → filter happens, shared by
/// both front-ends (the GUI menu-bar dictation and the CLI `--transcribe-file`
/// mode). Keeping this as the one reuse point is deliberate: it is the only way
/// to guarantee the two entry paths can't drift in behaviour (routing, gating,
/// hallucination filtering all stay identical).
///
/// An actor because it holds the two engines (themselves actors) plus the gate,
/// and because a fresh utterance may be dispatched while a previous one is still
/// transcribing. The engines serialise their own model state via their actor
/// isolation and each utterance gets a fresh decoder state, so overlapping calls
/// don't bleed; this actor just orchestrates.
actor DictationPipeline {
    /// The result of running one utterance through the whole pipeline.
    struct Outcome: Sendable {
        /// The text to paste. Empty when the utterance was gated out OR when the
        /// transcript was suppressed by the hallucination filter (distinguish the
        /// two via `gate` and `filtered`).
        let text: String
        /// Which engine ran, or nil when no ASR ran at all (the utterance was
        /// gated out before routing).
        let engine: EngineKind?
        /// Why the gate passed or dropped this utterance.
        let gate: GateDecision
        /// True iff ASR produced non-empty text that the hallucination filter
        /// then dropped (so callers can log a suppressed ghost vs. real silence).
        let filtered: Bool
        /// Wall-clock seconds spent inside `engine.transcribe` (0 when gated out).
        let inferenceSeconds: Double
        /// True iff Parakeet's transcript was discarded for a Whisper re-run
        /// because its confidence fell below the rescue threshold (`engine` is
        /// then `.whisper` — the engine whose text was actually used).
        var rescued: Bool = false
    }

    /// Parakeet confidence at/above which its transcript is trusted as-is.
    /// Below it, the utterance is re-run through Whisper (which CAN be forced
    /// to a language, unlike Parakeet's script-only hint). Calibration from
    /// this machine: clean same-language audio scores 0.88-0.97; a real Danish
    /// utterance Parakeet wrongly decoded as English scored 0.59.
    static let defaultRescueConfidence = 0.80

    private let parakeet: any TranscriptionEngine   // ParakeetEngine
    private let whisper: any TranscriptionEngine    // Transcriber
    private let gate: GateProviding                 // SpeechGate (or a test fake)
    private let rescueConfidence: Double

    init(parakeet: any TranscriptionEngine,
         whisper: any TranscriptionEngine,
         gate: GateProviding,
         rescueConfidence: Double = DictationPipeline.defaultRescueConfidence) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.gate = gate
        self.rescueConfidence = rescueConfidence
    }

    /// Warm only the launch-time defaults: the VAD gate and Parakeet (both load
    /// in seconds). Whisper stays lazy — it cold-loads for 3-4 min and resides
    /// at ~1.5 GB, so that cost is paid only if/when the user actually routes to
    /// it (Accuracy Mode or a language outside Parakeet's set).
    func warmUpDefaults() async throws {
        await gate.warmUp()          // fail-open; never throws
        try await parakeet.warmUp()
    }

    /// Route and warm the engine the given settings select, WITHOUT running any
    /// audio through it. Idempotent: warming an already-warm engine is a no-op.
    ///
    /// This exists so callers can pay a possibly-minutes-long cold load (Whisper's
    /// first-ever download/compile) OUTSIDE any per-utterance hang guard: the GUI
    /// calls this before wrapping `process` in its 120 s timeout, and the CLI uses
    /// it to warm only the engine a run will actually touch.
    /// - Returns: the engine kind that was selected and warmed.
    func prepareEngine(language: String,
                       accuracyMode: Bool,
                       forcedEngine: EngineKind? = nil,
                       onColdLoad: (@Sendable (EngineKind) -> Void)? = nil) async throws -> EngineKind {
        let kind = forcedEngine ?? EngineRouter.route(language: language, accuracyMode: accuracyMode)
        let engine = (kind == .parakeet) ? parakeet : whisper
        // Surface the cold-load BEFORE the (possibly minutes-long) warm-up so the
        // UI reflects it immediately; never fired for an already-warm engine.
        if await !engine.isWarmedUp { onColdLoad?(kind) }
        try await engine.warmUp()
        return kind
    }

    /// Run one utterance end-to-end.
    /// - Parameters:
    ///   - samples: 16 kHz mono Float32 capture buffer.
    ///   - language: "auto" (no pin) or an ISO code; drives both routing and the
    ///     per-engine language hint.
    ///   - accuracyMode: force Whisper for every language.
    ///   - forcedEngine: CLI `--engine` override that bypasses the router.
    ///   - bypassGate: CLI `--no-vad-gate` — skip gate layers 1+2 and transcribe
    ///     the raw buffer (treated as `.vadUnavailable`, the same fail-open path).
    ///     Used by raw-ASR regression tests; defaults false so the GUI is unaffected.
    ///   - bypassFilter: CLI `--no-hallucination-filter` — skip layer 3 and return
    ///     the raw ASR text. Defaults false so the GUI is unaffected.
    ///   - onColdLoad: fired (once, before the blocking warm-up) when the routed
    ///     engine isn't warm yet, so the GUI can show "Loading … model (first
    ///     use)…". Never fired for an already-warm engine.
    func process(samples: [Float],
                 language: String,
                 accuracyMode: Bool,
                 forcedEngine: EngineKind? = nil,
                 bypassGate: Bool = false,
                 bypassFilter: Bool = false,
                 onColdLoad: (@Sendable (EngineKind) -> Void)? = nil) async throws -> Outcome {
        // Layers 1+2 (duration + VAD). Only `.pass` (trimmed) or `.vadUnavailable`
        // (raw, fail-open) proceed to ASR; `.tooShort` / `.silence` short-circuit
        // with empty text and no model ever touched. `--no-vad-gate` skips this
        // entirely by synthesising the fail-open decision on the raw buffer.
        let gated = bypassGate
            ? SpeechGate.Outcome(decision: .vadUnavailable, audio: samples)
            : await gate.evaluate(samples)
        guard gated.decision == .pass || gated.decision == .vadUnavailable else {
            return Outcome(text: "", engine: nil, gate: gated.decision,
                           filtered: false, inferenceSeconds: 0)
        }

        // Route, unless the CLI pinned a specific engine.
        let kind = forcedEngine ?? EngineRouter.route(language: language, accuracyMode: accuracyMode)
        let engine = (kind == .parakeet) ? parakeet : whisper

        // Surface the cold-load BEFORE the (possibly minutes-long) warm-up so the
        // UI reflects it immediately; warmUp() itself is idempotent, so calling it
        // when already warm is a cheap no-op.
        if await !engine.isWarmedUp { onColdLoad?(kind) }
        try await engine.warmUp()

        // "auto" is the app-level sentinel for "no pin"; engines take nil for auto.
        let hint = (language == "auto") ? nil : language
        let t0 = Date()
        var result = try await engine.transcribe(samples: gated.audio, language: hint)
        var usedKind = kind
        var rescued = false

        // Confidence rescue. Parakeet v3 cannot be *forced* to a language — its
        // `language:` hint is only a script filter, and e.g. Danish vs English
        // are both Latin — so when it locks onto the wrong language the only
        // tell is low confidence. Re-run those utterances through Whisper,
        // which honours a pinned language outright (DecodingOptions.language).
        // Never rescues when the caller forced an engine (explicit choice wins),
        // and a rescue failure falls back to Parakeet's text: a dubious
        // transcript beats a lost utterance.
        if forcedEngine == nil, kind == .parakeet,
           let confidence = result.confidence, confidence < rescueConfidence {
            Log.warn("parakeet confidence \(String(format: "%.2f", confidence)) < \(String(format: "%.2f", rescueConfidence)) — rescuing with whisper", "pipeline")
            do {
                if await !whisper.isWarmedUp { onColdLoad?(.whisper) }
                try await whisper.warmUp()
                result = try await whisper.transcribe(samples: gated.audio, language: hint)
                usedKind = .whisper
                rescued = true
            } catch {
                Log.error("whisper rescue failed — keeping parakeet transcript: \(error)", "pipeline")
            }
        }
        let inference = Date().timeIntervalSince(t0)

        // Layer 3: post-ASR hallucination filter (whole-output blocklist + loop
        // guard). `--no-hallucination-filter` returns the raw ASR text untouched.
        let raw = result.text
        let cleaned = bypassFilter ? raw : HallucinationFilter.clean(raw)
        return Outcome(text: cleaned, engine: usedKind, gate: gated.decision,
                       filtered: cleaned.isEmpty && !raw.isEmpty,
                       inferenceSeconds: inference,
                       rescued: rescued)
    }
}
