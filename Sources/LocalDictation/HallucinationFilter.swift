import Foundation

/// Post-ASR guard against known model hallucinations — the phantom subtitles /
/// "thanks for watching" phrases both Whisper and Parakeet emit on silence or
/// near-silence, plus decode-loop repetition. Pure; applied to BOTH engines.
///
/// Whole-normalized-output matching ONLY (never substring): the blocklist is
/// curated to phrases that are implausible as an *entire* intentional
/// dictation, so real speech that merely contains such a phrase is kept. This
/// is why "tak for det" and "you" are deliberately EXCLUDED — they are normal
/// standalone one-utterance replies, and whole-output matching can't tell a
/// hallucinated "you" from a real one anyway.
enum HallucinationFilter {
    static let blocklist: Set<String> = [
        // Danish Whisper silence ghosts
        "tak for at se med", "tak fordi du så med", "tak for at i så med",
        "tak fordi i så med", "undertekster af nicolai winther", "tekstet af seertekst",
        // English
        "thank you for watching", "thanks for watching", "please subscribe",
        "like and subscribe", "subtitles by the amara.org community",
    ]

    /// Returns "" when the text should be suppressed, otherwise the original text.
    static func clean(_ text: String) -> String {
        let norm = normalize(text)
        if norm.isEmpty { return "" }
        if blocklist.contains(norm) { return "" }
        if isRepetitionLoop(norm) { return "" }
        return text
    }

    /// Lowercase, strip surrounding whitespace and terminal punctuation so
    /// "Thanks for watching." matches "thanks for watching".
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,…♪"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper decode-loop guard: a long output dominated by a handful of
    /// distinct words (e.g. "the the the the …") is almost certainly a loop.
    static func isRepetitionLoop(_ normalized: String) -> Bool {
        let words = normalized.split(separator: " ")
        guard words.count > 12 else { return false }
        return Double(Set(words).count) / Double(words.count) < 0.2
    }
}
