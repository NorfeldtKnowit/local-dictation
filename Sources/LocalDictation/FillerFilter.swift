import Foundation

/// Post-ASR removal of standalone hesitation fillers (en: "uh"/"um"/"uhm"/
/// "erm", da: "øh"/"øhm"/"ehm"). Pure; applied to BOTH engines, after the
/// hallucination filter.
///
/// Whole-token matches ONLY — a token is dropped when its letters are exactly
/// a filler word, so "serum", "høj", "uh-huh" and (critically, for Danish)
/// "er" are never touched. Real discourse words ("altså", "jo", "well") are
/// deliberately not listed: they carry meaning, hesitation fillers don't.
///
/// Punctuation repair is limited to the artifacts the filler itself dragged
/// in: the ", uh," pause-pair loses both commas ("I want to, uh, refactor" →
/// "I want to refactor"), a sentence-final filler hands its terminator to the
/// previous word ("the parser, uh." → "the parser."), and a removed leading
/// filler passes its capital on ("Um, so we…" → "So we…").
enum FillerFilter {
    static let fillers: Set<String> = [
        "uh", "um", "uhm", "erm",   // English
        "øh", "øhm", "ehm",         // Danish
    ]

    /// Returns `text` with standalone filler tokens removed. Exactly `text`
    /// (same instance, same whitespace) when no filler is present.
    static func strip(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return text }

        var kept: [String] = []
        var capitalizeNext = false
        var removedAny = false

        for var token in tokens {
            guard let firstLetter = token.firstIndex(where: { $0.isLetter }),
                  let lastLetter = token.lastIndex(where: { $0.isLetter }) else {
                kept.append(token)   // pure punctuation, keep verbatim
                continue
            }
            let core = token[firstLetter...lastLetter]
            if fillers.contains(core.lowercased()) {
                removedAny = true
                let trailing = token[token.index(after: lastLetter)...]
                // Sentence-initial filler (utterance-leading or right after a
                // terminator): pass its sentence capital to the next word.
                if core.first!.isUppercase,
                   kept.isEmpty || ".!?".contains(kept[kept.count - 1].last ?? " ") {
                    capitalizeNext = true
                }
                if !kept.isEmpty {
                    if trailing.first == "," {
                        // ", uh," pause-pair: the previous word's comma is the
                        // filler's artifact too — but only when it can't be a
                        // list separator (no earlier comma so far). Corrupting
                        // an enumeration is worse than one awkward comma.
                        if kept[kept.count - 1].hasSuffix(","),
                           !kept.dropLast().contains(where: { $0.hasSuffix(",") }) {
                            kept[kept.count - 1].removeLast()
                        }
                    } else if let ender = trailing.first, ".!?".contains(ender) {
                        // Sentence-final filler: the terminator belongs to the
                        // text — unless the text already ends with one
                        // ("Done. Uh." must not become "Done..").
                        if kept[kept.count - 1].hasSuffix(",") { kept[kept.count - 1].removeLast() }
                        if let last = kept[kept.count - 1].last, !".!?".contains(last) {
                            kept[kept.count - 1].append(ender)
                        }
                    }
                }
                continue
            }
            if capitalizeNext {
                token = uppercasedFirstLetter(token)
                capitalizeNext = false
            }
            kept.append(token)
        }

        guard removedAny else { return text }
        // A comma-strip can empty a pure-punctuation token; drop the husk.
        return kept.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func uppercasedFirstLetter(_ token: String) -> String {
        guard let first = token.first, first.isLetter, first.isLowercase else { return token }
        return first.uppercased() + token.dropFirst()
    }
}
