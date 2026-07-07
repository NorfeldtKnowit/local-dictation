import Foundation

/// How aggressively the polish stage may rewrite. `.standard` is the faithful
/// cleanup (fillers, restarts, misrecognitions); `.terse` additionally
/// condenses spoken rambling into the shortest text that keeps every point —
/// the "processed" candidate the review overlay offers next to the raw ASR.
enum PolishStyle: String, Sendable {
    case standard
    case terse
}

/// The pure half of the transcript-polish stage: the model instructions and
/// the guardrails that decide whether a rewrite is safe to use. Kept free of
/// FoundationModels so every rule here is unit-testable on any machine —
/// `TranscriptPolisher` (the actor) owns the model call and nothing else.
enum TranscriptPolisherLogic {
    /// System instructions for the on-device model. One session per utterance,
    /// instructions fixed, the raw transcript is the entire user prompt.
    /// Wording A/B-tested via the fm-spike harness (see CLAUDE.md).
    static let instructions = """
        You are the cleanup stage of a dictation app. The user message is a raw \
        speech-to-text transcript. Rewrite it as the text the speaker intended \
        to write, and output ONLY that rewritten transcript.

        Allowed edits:
        1. Delete hesitation fillers (uh, um, erm, øh, øhm, ehm).
        2. Collapse stutters, duplicated words, and abandoned false starts, \
        keeping only the final intended phrasing.
        3. Replace a word that is clearly a misrecognition of another word \
        given the context — non-words ("canorical" -> "canonical") and \
        real-but-wrong words ("citation quality" -> "dictation quality" when \
        the speaker is talking about transcription).

        Hard rules:
        - Never add information, never answer questions in the transcript, \
        never comment on it.
        - Keep the language exactly as spoken; Danish stays Danish, English \
        stays English, mixed stays mixed. Never translate.
        - Keep the speaker's wording and style; make the smallest number of \
        edits that fixes the transcript.
        - If the transcript is already clean, output it unchanged.
        """

    /// The `.terse` variant: the standard cleanup PLUS deliberate condensing.
    /// Same hard rules about invention and language; the "smallest number of
    /// edits" rule is intentionally replaced by the condensing goal.
    static let terseInstructions = """
        You are the cleanup stage of a dictation app. The user message is a raw \
        speech-to-text transcript. Rewrite it as the tersest text that still \
        says everything the speaker intended, and output ONLY that rewritten \
        transcript.

        Allowed edits:
        1. Delete hesitation fillers (uh, um, erm, øh, øhm, ehm).
        2. Collapse stutters, duplicated words, and abandoned false starts, \
        keeping only the final intended phrasing.
        3. Replace a word that is clearly a misrecognition of another word \
        given the context — non-words ("canorical" -> "canonical") and \
        real-but-wrong words ("citation quality" -> "dictation quality" when \
        the speaker is talking about transcription).
        4. Condense: drop redundant qualifiers, hedges, repetition and \
        thinking-out-loud detours; prefer the shortest phrasing that keeps \
        every point the speaker made.

        Hard rules:
        - Never add information, never answer questions in the transcript, \
        never comment on it.
        - Keep the language exactly as spoken; Danish stays Danish, English \
        stays English, mixed stays mixed. Never translate.
        - Never drop a point the speaker made — condense the wording, not \
        the content.
        - If the transcript is already clean and terse, output it unchanged.
        """

    static func instructions(for style: PolishStyle) -> String {
        switch style {
        case .standard: return instructions
        case .terse:    return terseInstructions
        }
    }

    /// Below this the transcript carries too little context for the model to
    /// fix anything a cheaper layer hasn't already — skip the call entirely.
    static let minCharacters = 16

    /// Above this the model's `maximumResponseTokens` cap (1024) could bite:
    /// FoundationModels TRUNCATES SILENTLY at the cap (no error, no finish
    /// reason on `Response`), and a faithful-but-truncated rewrite passes
    /// every other guardrail — pasting it would lose the tail of a long
    /// dictation. Skipping polish (keeping ASR text) is the only safe move.
    static let maxCharacters = 2500

    /// Accepted rewrites must stay within these bounds of the raw length.
    /// Real disfluency collapse shrinks hard (measured ~0.4 on restart-heavy
    /// speech) but never past ~0.3; growth past ~1.3 means invented content.
    static let minLengthRatio = 0.3
    static let maxLengthRatio = 1.3

    /// `.terse` is ASKED to condense, so its shrink floor sits lower — but not
    /// at zero: below ~0.15 of the raw length the rewrite has almost certainly
    /// dropped content, not just wording.
    static let terseMinLengthRatio = 0.15

    /// Minimum share of the rewrite's words that must already occur in the
    /// raw transcript. A cleanup deletes freely but INTRODUCES only the odd
    /// misrecognition fix; same-line commentary ("Sure! Here is …") and
    /// invented/answered content flood the rewrite with new words.
    static let minWordOverlap = 0.66

    /// A language carrying at least this share of the raw text (sentence-
    /// weighted) must still be present in the rewrite; below it, single-
    /// sentence LID noise would cause false rejects.
    static let minLanguageWeight = 0.15

    enum Verdict: Equatable {
        case accepted(String)
        case rejected(reason: String)
    }

    static func worthPolishing(_ text: String) -> Bool {
        text.count >= minCharacters && text.count <= maxCharacters
    }

    /// Decide whether the model's rewrite of `raw` is safe to paste. Any
    /// rejection means the caller keeps `raw` — polish can only ever be a
    /// quality upgrade, never a lost or corrupted utterance. `.terse` only
    /// loosens the shrink floor; every other guardrail applies unchanged.
    static func accept(raw: String, candidate: String, style: PolishStyle = .standard) -> Verdict {
        var polished = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        // Un-wrap a quote pair (ASCII or typographic) the model added around
        // the whole answer — but never quotes that belong to the text: only
        // when raw wasn't quote-led AND the interior carries no quote of the
        // same pair (dialogue lines keep theirs).
        for (open, close) in [("\"", "\""), ("\u{201C}", "\u{201D}")] {
            if polished.count >= 2, polished.hasPrefix(open), polished.hasSuffix(close),
               !raw.hasPrefix(open) {
                let inner = polished.dropFirst().dropLast()
                if !inner.contains(open) && !inner.contains(close) {
                    polished = String(inner)
                }
            }
        }
        guard !polished.isEmpty else { return .rejected(reason: "empty rewrite") }
        if polished.contains("\n") && !raw.contains("\n") {
            return .rejected(reason: "added line breaks (reads as commentary)")
        }
        let ratio = Double(polished.count) / Double(raw.count)
        let shrinkFloor = (style == .terse) ? terseMinLengthRatio : minLengthRatio
        if ratio < shrinkFloor {
            return .rejected(reason: "shrank to \(String(format: "%.2f", ratio))x (< \(shrinkFloor))")
        }
        if ratio > maxLengthRatio {
            return .rejected(reason: "grew to \(String(format: "%.2f", ratio))x (> \(maxLengthRatio))")
        }
        // Commentary/invention guard: most of the rewrite's words must come
        // from the raw transcript (deleting is free; introducing is bounded
        // to the occasional misrecognition fix). Catches same-line preambles
        // the newline check can't see, and same-language invented content.
        let rawWords = Set(words(raw))
        let candidateWords = words(polished)
        if candidateWords.count >= 5 {
            let known = candidateWords.filter(rawWords.contains).count
            let overlap = Double(known) / Double(candidateWords.count)
            if overlap < minWordOverlap {
                return .rejected(reason: "only \(String(format: "%.0f", overlap * 100))% of rewrite words occur in the transcript (reads as commentary/invention)")
            }
        }
        // Translation guard: no language of the raw text may VANISH from the
        // rewrite. Sentence-weighted (via TextLanguageID, which folds nb into
        // da) so the minority half of a mixed da/en utterance is protected —
        // a whole-text dominant compare would miss its translation entirely.
        let afterWeights = TextLanguageID.languageWeights(of: polished)
        if !afterWeights.isEmpty {
            for (language, weight) in TextLanguageID.languageWeights(of: raw)
            where weight >= minLanguageWeight && afterWeights[language] == nil {
                return .rejected(reason: "language \(language) vanished from rewrite (reads as translation)")
            }
        }
        return .accepted(polished)
    }

    /// Lowercased letter-runs; punctuation and digits are separators.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
}
