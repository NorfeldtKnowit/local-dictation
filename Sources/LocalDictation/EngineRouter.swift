import Foundation
import FluidAudio

/// Pure decision of which engine transcribes an utterance, given the user's
/// language pin and Accuracy Mode toggle. No I/O, no models — fully unit tested.
///
/// Design: Parakeet is the low-latency default and self-detects among its 28
/// script-filtered languages. Anything outside that set (Japanese, Chinese,
/// Korean, Arabic — and, notably for a Nordic user, Norwegian, which the
/// FluidAudio `Language` enum does NOT contain) must go to Whisper. Accuracy
/// Mode forces Whisper for every language.
enum EngineRouter {
    /// Exactly the raw ISO codes FluidAudio's Parakeet v3 supports (Latin /
    /// Cyrillic / Greek scripts). Derived from the enum so it can never drift
    /// out of sync with the linked library version. Contains "da", "sv", "fi"
    /// but NOT Norwegian ("no" / "nb") — Norwegian routes to Whisper.
    /// (Note: use the bare `Language` — the module exports a `public struct
    /// FluidAudio` that shadows the module name, so `FluidAudio.Language` won't
    /// resolve.)
    static let parakeetLanguages: Set<String> = Set(Language.allCases.map(\.rawValue))

    /// Languages Parakeet nominally supports but transcribes measurably worse
    /// than Whisper, so they route to Whisper despite being in
    /// `parakeetLanguages`. Danish is here from direct A/B on real utterances
    /// (2026-07-06, this machine): Parakeet at confidence 0.96 produced
    /// "komet omskrivning af foreningen … starte forfar" where Whisper pinned
    /// `da` produced the correct "komplet omskrivning af forgreningen … starte
    /// forfra". The confidence rescue cannot catch this class of error —
    /// within-language mistakes score as high as clean output — so routing is
    /// the only lever.
    static let whisperPreferred: Set<String> = ["da"]

    /// The codes the menu should offer under the low-latency Parakeet section:
    /// the model's languages minus the ones quality-routed to Whisper.
    static let parakeetMenuLanguages: Set<String> = parakeetLanguages.subtracting(whisperPreferred)

    /// - Parameters:
    ///   - language: "auto" or an ISO code from the menu.
    ///   - accuracyMode: user's global "use Whisper everywhere" toggle.
    static func route(language: String, accuracyMode: Bool) -> EngineKind {
        if accuracyMode { return .whisper }
        if language == "auto" { return .parakeet }
        if whisperPreferred.contains(language) { return .whisper }
        return parakeetLanguages.contains(language) ? .parakeet : .whisper
    }

    // MARK: - Second-stage (post-Parakeet) text rescue plan

    /// What the pipeline should do with an auto-mode Parakeet transcript,
    /// decided from the transcript's sentence-level language distribution.
    enum TextRescuePlan: Equatable {
        /// Transcript's language is one Parakeet handles well — keep it.
        case keep
        /// Utterance is (essentially) all one Whisper-preferred language:
        /// re-run the whole buffer through Whisper pinned to `pin`.
        case wholeUtterance(pin: String)
        /// Utterance mixes a Whisper-preferred language with others and the
        /// gate found 2+ speech segments: transcribe per segment, sending the
        /// `pin`-language runs through Whisper (code-switching).
        case perSegment(pin: String)
    }

    /// Above this share of (character-weighted) sentences, the utterance is
    /// treated as monolingual in the preferred language.
    static let dominantShare = 0.85
    /// At/above this share the preferred language is a real presence (not LID
    /// noise on one short sentence) and worth acting on.
    static let mixedShare = 0.20
    /// Fallback when mixing is detected but no segment boundaries exist: a
    /// majority-preferred utterance still re-runs whole (fixing the majority
    /// outweighs Whisper mangling the minority); below it Parakeet's sloppy
    /// code-switching is the lesser evil.
    static let majorityShare = 0.50

    /// - Parameters:
    ///   - weights: `TextLanguageID.languageWeights` of the Parakeet transcript.
    ///   - segmentCount: how many padded speech segments the VAD gate produced
    ///     (0 or 1 means no usable cut points for per-segment routing).
    static func textRescuePlan(weights: [String: Double], segmentCount: Int) -> TextRescuePlan {
        let preferred = weights.filter { whisperPreferred.contains($0.key) }
        let share = preferred.values.reduce(0, +)
        guard share >= mixedShare,
              let pin = preferred.max(by: { $0.value < $1.value })?.key else { return .keep }
        if share >= dominantShare { return .wholeUtterance(pin: pin) }
        if segmentCount >= 2 { return .perSegment(pin: pin) }
        return share >= majorityShare ? .wholeUtterance(pin: pin) : .keep
    }
}
