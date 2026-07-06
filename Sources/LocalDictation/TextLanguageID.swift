import Foundation
import NaturalLanguage

/// Text-based language identification over ASR output, built on the OS-bundled
/// `NLLanguageRecognizer` (no download, no TCC, deterministic enough to test).
///
/// Why identify language from *text* when the audio already went through an
/// engine: Parakeet's confidence only reveals wrong-LANGUAGE decodes (they
/// score ~0.59); its within-language Danish errors score 0.93-0.97, identical
/// to clean output, so confidence can never route Danish to the better engine.
/// The transcript itself, however, still *reads* as Danish even when garbled
/// ("komet omskrivning af foreningen" is wrong but unmistakably Danish), which
/// makes text LID a reliable post-hoc routing signal.
enum TextLanguageID {
    /// Below this many characters LID is noise ("Okay." matches half of
    /// Europe); callers get nil and should treat the language as unknown.
    static let minChars = 8

    /// Norwegian Bokmål folds into Danish: the two are near-identical in
    /// writing and `NLLanguageRecognizer` frequently labels (especially
    /// garbled) Danish as "nb". For routing purposes both mean "re-run
    /// through Whisper pinned to Danish".
    static func normalized(_ code: String) -> String {
        code == "nb" ? "da" : code
    }

    /// Dominant language of the whole text as a normalized ISO 639-1 code,
    /// or nil when the text is too short / unrecognizable.
    static func dominantLanguage(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minChars else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        return normalized(language.rawValue)
    }

    /// Character-weighted language distribution across the text's sentences,
    /// normalized to sum to 1 over the sentences that produced a confident
    /// LID. Sentence granularity is what detects code-switching: a mixed
    /// utterance LIDs as one language whole ("dominant" hides the minority)
    /// but its sentences split cleanly — Parakeet transcribes each spoken
    /// language in its own script, so the transcript's sentences carry the
    /// switch even when the words are garbled.
    static func languageWeights(of text: String) -> [String: Double] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var weights: [String: Double] = [:]
        var total = 0.0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty, let language = dominantLanguage(of: sentence) {
                weights[language, default: 0] += Double(sentence.count)
                total += Double(sentence.count)
            }
            return true
        }
        guard total > 0 else { return [:] }
        return weights.mapValues { $0 / total }
    }
}
