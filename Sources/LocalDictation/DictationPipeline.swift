import Foundation

/// The single place where gate → route → transcribe → filter → polish happens,
/// shared by both front-ends (the GUI menu-bar dictation and the CLI
/// `--transcribe-file` mode). Keeping this as the one reuse point is deliberate:
/// it is the only way to guarantee the two entry paths can't drift in behaviour
/// (routing, gating, text filtering and polish all stay identical).
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
        /// The filtered ASR text BEFORE polish (layers 1-3 applied, layer 4 not).
        /// Equal to `text` whenever `polished` is false. Kept so a review UI can
        /// offer the raw transcript next to the polished rewrite.
        let asrText: String
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
        /// Non-nil iff Parakeet's transcript was (partly) discarded for a
        /// Whisper re-run; says why. `engine` is then `.whisper` — the engine
        /// whose text was (at least partly) used.
        var rescue: RescueReason? = nil
        /// Convenience for logs / JSON consumers that only care whether any
        /// rescue happened.
        var rescued: Bool { rescue != nil }
        /// True iff the polish stage produced a rewrite that DIFFERS from the
        /// filtered ASR text and was used as `text`. False when polish was
        /// off, the model unavailable, the rewrite rejected or a verbatim
        /// echo, or the call failed/timed out — `text` is then the filtered
        /// ASR text unchanged.
        var polished: Bool = false
    }

    /// Why an auto-routed Parakeet transcript was re-run through Whisper.
    enum RescueReason: String, Sendable {
        /// Parakeet's token confidence fell below the rescue threshold — the
        /// signature of a wrong-language decode (e.g. Danish audio decoded as
        /// English gibberish).
        case confidence
        /// The transcript READ as a Whisper-preferred language (Danish) even
        /// though confidence was high: Parakeet is confidently mediocre at
        /// those, so the whole buffer re-ran through Whisper pinned to it.
        case language
        /// The transcript mixed a Whisper-preferred language with others; the
        /// utterance was re-transcribed per VAD segment, with the preferred-
        /// language runs re-run through Whisper (code-switching).
        case codeSwitch = "code-switch"
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
    private let polisher: (any TranscriptPolishing)?  // TranscriptPolisher (or a test fake)
    /// Optional separate backend for `polishText` (the review path). The GUI
    /// passes `RoutedPolisher` (Apple FM for English, MLX Qwen for the rest);
    /// `process()`'s inline polish deliberately does NOT use it — without the
    /// review HUD there is no feedback surface for MLX's slower cold path.
    private let reviewPolisher: (any TranscriptPolishing)?
    private let rescueConfidence: Double

    init(parakeet: any TranscriptionEngine,
         whisper: any TranscriptionEngine,
         gate: GateProviding,
         polisher: (any TranscriptPolishing)? = nil,
         reviewPolisher: (any TranscriptPolishing)? = nil,
         rescueConfidence: Double = DictationPipeline.defaultRescueConfidence) {
        self.parakeet = parakeet
        self.whisper = whisper
        self.gate = gate
        self.polisher = polisher
        self.reviewPolisher = reviewPolisher
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
    ///   - polish: run layer 4, the LLM transcript polish (menu toggle / CLI
    ///     `--no-polish`). Only ever a quality upgrade: any decline — model
    ///     unavailable, guardrail reject, error, timeout — keeps the filtered
    ///     ASR text. No-op when the pipeline was built without a polisher.
    ///   - polishStyle: how aggressively layer 4 may rewrite. `.standard` is
    ///     the faithful cleanup; `.terse` (used by the review overlay) also
    ///     condenses. Ignored when `polish` is false.
    ///   - onColdLoad: fired (once, before the blocking warm-up) when the routed
    ///     engine isn't warm yet, so the GUI can show "Loading … model (first
    ///     use)…". Never fired for an already-warm engine.
    func process(samples: [Float],
                 language: String,
                 accuracyMode: Bool,
                 forcedEngine: EngineKind? = nil,
                 bypassGate: Bool = false,
                 bypassFilter: Bool = false,
                 polish: Bool = false,
                 polishStyle: PolishStyle = .standard,
                 onColdLoad: (@Sendable (EngineKind) -> Void)? = nil) async throws -> Outcome {
        // Layers 1+2 (duration + VAD). Only `.pass` (trimmed) or `.vadUnavailable`
        // (raw, fail-open) proceed to ASR; `.tooShort` / `.silence` short-circuit
        // with empty text and no model ever touched. `--no-vad-gate` skips this
        // entirely by synthesising the fail-open decision on the raw buffer.
        let gated = bypassGate
            ? SpeechGate.Outcome(decision: .vadUnavailable, audio: samples)
            : await gate.evaluate(samples)
        guard gated.decision == .pass || gated.decision == .vadUnavailable else {
            return Outcome(text: "", asrText: "", engine: nil, gate: gated.decision,
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
        var rescue: RescueReason? = nil

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
                try await warmWhisper(onColdLoad: onColdLoad)
                result = try await whisper.transcribe(samples: gated.audio, language: hint)
                usedKind = .whisper
                rescue = .confidence
            } catch {
                Log.error("whisper rescue failed — keeping parakeet transcript: \(error)", "pipeline")
            }
        }

        // Language rescue. Confidence only reveals wrong-LANGUAGE decodes;
        // Parakeet's within-language Danish errors score 0.93+, identical to
        // clean output. The transcript itself is the remaining signal: if it
        // READS as a Whisper-preferred language (sentence-level LID), re-run —
        // whole-buffer when monolingual, per VAD segment when the utterance
        // code-switches between a preferred language and something else.
        // Auto-mode only: a pinned language already routed where the user chose.
        if rescue == nil, forcedEngine == nil, kind == .parakeet, language == "auto" {
            let weights = TextLanguageID.languageWeights(of: result.text)
            switch EngineRouter.textRescuePlan(weights: weights, segmentCount: gated.segments.count) {
            case .keep:
                // A monolingual-looking transcript does NOT prove monolingual
                // audio: Parakeet can silently DROP a whole sentence in the
                // other language (observed: a Danish+English clip transcribed
                // as only the English sentence at confidence 1.00), leaving no
                // textual trace for the LID above. When the gate found real
                // pause boundaries, spend one cheap Parakeet pass per segment
                // to check each one; nil comes back when nothing preferred is
                // found and the whole-buffer transcript stands.
                if gated.segments.count >= 2 {
                    do {
                        if let text = try await codeSwitchTranscribe(segments: gated.segments,
                                                                     onColdLoad: onColdLoad) {
                            Log.warn("segment scan found whisper-preferred speech parakeet's whole-buffer transcript missed — code-switch rescue", "pipeline")
                            result = EngineResult(text: text, confidence: nil)
                            usedKind = .whisper
                            rescue = .codeSwitch
                        }
                    } catch {
                        Log.error("segment-scan rescue failed — keeping parakeet transcript: \(error)", "pipeline")
                    }
                }
            case .wholeUtterance(let pin):
                Log.warn("parakeet transcript reads as '\(pin)' (whisper-preferred) — re-running whole utterance through whisper", "pipeline")
                do {
                    try await warmWhisper(onColdLoad: onColdLoad)
                    result = try await whisper.transcribe(samples: gated.audio, language: pin)
                    usedKind = .whisper
                    rescue = .language
                } catch {
                    Log.error("whisper language rescue failed — keeping parakeet transcript: \(error)", "pipeline")
                }
            case .perSegment(let pin):
                Log.warn("parakeet transcript mixes '\(pin)' with other languages — re-transcribing \(gated.segments.count) segments (code-switch)", "pipeline")
                do {
                    if let text = try await codeSwitchTranscribe(segments: gated.segments,
                                                                 onColdLoad: onColdLoad) {
                        result = EngineResult(text: text, confidence: nil)
                        usedKind = .whisper
                        rescue = .codeSwitch
                    }
                } catch {
                    Log.error("code-switch rescue failed — keeping parakeet transcript: \(error)", "pipeline")
                }
            }
        }
        let inference = Date().timeIntervalSince(t0)

        // Layer 3: post-ASR text filters — hallucination guard (whole-output
        // blocklist + loop guard) then standalone-filler strip.
        // `--no-hallucination-filter` returns the raw ASR text untouched.
        let raw = result.text
        let cleaned = bypassFilter ? raw : FillerFilter.strip(HallucinationFilter.clean(raw))

        // Layer 4: optional LLM polish. Never runs on empty/suppressed text
        // (gated-out utterances returned before ASR; errors threw above), and
        // any decline keeps `cleaned` — polish can lose nothing, only refine.
        var text = cleaned
        var polished = false
        if polish, !cleaned.isEmpty, let polisher,
           let refined = await polisher.polish(cleaned, style: polishStyle),
           refined != cleaned {   // verbatim echo == "already clean", not a rewrite
            // The pre-polish ASR text must stay recoverable from the log.
            Log.info("polish (\(polishStyle.rawValue)) rewrote: \"\(cleaned.prefix(160))\" -> \"\(refined.prefix(160))\"", "polish")
            text = refined
            polished = true
        }
        return Outcome(text: text, asrText: cleaned, engine: usedKind, gate: gated.decision,
                       filtered: cleaned.isEmpty && !raw.isEmpty,
                       inferenceSeconds: inference,
                       rescue: rescue, polished: polished)
    }

    /// Layer 4 alone, for the review path: the caller ran `process(polish:
    /// false)`, showed the HUD with the raw text, and now streams the rewrite
    /// into it. Same decline semantics as the inline polish — nil means "keep
    /// the ASR text" (unavailable, guardrail reject, timeout, verbatim echo).
    /// Routing (Apple FM vs MLX) lives in the injected `reviewPolisher`.
    func polishText(_ text: String,
                    style: PolishStyle,
                    onPartial: (@Sendable (String) -> Void)? = nil) async -> String? {
        guard !text.isEmpty, let polisher = reviewPolisher ?? polisher else { return nil }
        guard let refined = await polisher.polish(text, style: style, onPartial: onPartial),
              refined != text else { return nil }
        // The pre-polish ASR text must stay recoverable from the log.
        Log.info("polish (\(style.rawValue)) rewrote: \"\(text.prefix(160))\" -> \"\(refined.prefix(160))\"", "polish")
        return refined
    }

    private func warmWhisper(onColdLoad: (@Sendable (EngineKind) -> Void)?) async throws {
        if await !whisper.isWarmedUp { onColdLoad?(.whisper) }
        try await whisper.warmUp()
    }

    /// Code-switching re-transcription: Parakeet each VAD segment to find its
    /// language (its transcript carries the language even when the words are
    /// garbled — and per-segment it cannot silently drop a sentence the way a
    /// whole-buffer decode can), then merge consecutive whisper-preferred
    /// segments into runs and re-run those runs' audio through Whisper pinned
    /// to their language; other segments keep their Parakeet text (Parakeet is
    /// the better engine for them, and Whisper would translate them).
    /// Returns nil when no segment turned out to be whisper-preferred after
    /// all (the caller keeps the original whole-buffer transcript —
    /// re-segmented Parakeet text would be a lateral move with fresh join
    /// artifacts).
    private func codeSwitchTranscribe(segments: [[Float]],
                                      onColdLoad: (@Sendable (EngineKind) -> Void)?) async throws -> String? {
        var texts: [String] = []
        var pins: [String?] = []   // Whisper pin for the segment; nil = keep Parakeet's text
        for segment in segments {
            let text = try await parakeet.transcribe(samples: segment, language: nil).text
            texts.append(text)
            let language = TextLanguageID.dominantLanguage(of: text)
            pins.append(language.flatMap { EngineRouter.whisperPreferred.contains($0) ? $0 : nil })
        }
        guard pins.contains(where: { $0 != nil }) else { return nil }

        try await warmWhisper(onColdLoad: onColdLoad)
        var pieces: [String] = []
        var i = 0
        while i < segments.count {
            if let pin = pins[i] {
                // Merge the consecutive same-language run back into one buffer
                // so Whisper decodes it with full context (one call, not N).
                var audio: [Float] = []
                while i < segments.count, pins[i] == pin {
                    audio.append(contentsOf: segments[i])
                    i += 1
                }
                pieces.append(try await whisper.transcribe(samples: audio, language: pin).text)
            } else {
                pieces.append(texts[i])
                i += 1
            }
        }
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
