import Foundation

/// Word-level diff between the filtered ASR text (RAW) and its terse rewrite,
/// for the review overlay: which words the rewrite dropped (struck out in the
/// RAW row) and which are new or changed (tinted in the TERSE row). Pure
/// logic. Tokens are maximal runs of non-whitespace, so punctuation stays
/// glued to its word and a punctuation-only fix reads as a changed word —
/// that is a real edit worth seeing. Whitespace-only differences never
/// highlight anything.
enum TranscriptDiffLogic {
    struct Highlights: Equatable {
        /// Ranges in the RAW string of words the rewrite dropped or replaced.
        let rawDeletions: [Range<String.Index>]
        /// Ranges in the TERSE string of words not present verbatim in RAW.
        let terseInsertions: [Range<String.Index>]
    }

    static func highlights(raw: String, terse: String) -> Highlights {
        let rawTokens = tokens(in: raw)
        let terseTokens = tokens(in: terse)
        let diff = terseTokens.map(\.text).difference(from: rawTokens.map(\.text))
        // .removals / .insertions are sorted by offset — coalesced() needs that.
        let deletions = diff.removals.map { rawTokens[$0.offset].range }
        let insertions = diff.insertions.map { terseTokens[$0.offset].range }
        return Highlights(rawDeletions: coalesced(deletions, in: raw),
                          terseInsertions: coalesced(insertions, in: terse))
    }

    private struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            result.append(Token(text: text[index..<end], range: index..<end))
            index = end
        }
        return result
    }

    /// Merge marked ranges separated only by whitespace, so a dropped run
    /// like "I think that" renders as one continuous strike instead of three
    /// struck words with untouched gaps.
    private static func coalesced(_ ranges: [Range<String.Index>],
                                  in text: String) -> [Range<String.Index>] {
        guard var current = ranges.first else { return [] }
        var result: [Range<String.Index>] = []
        for range in ranges.dropFirst() {
            if text[current.upperBound..<range.lowerBound].allSatisfy(\.isWhitespace) {
                current = current.lowerBound..<range.upperBound
            } else {
                result.append(current)
                current = range
            }
        }
        result.append(current)
        return result
    }
}

private extension CollectionDifference.Change {
    /// The offset regardless of change direction (each of .removals /
    /// .insertions only ever holds its own direction).
    var offset: Int {
        switch self {
        case .insert(let offset, _, _): return offset
        case .remove(let offset, _, _): return offset
        }
    }
}
