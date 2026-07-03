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

    /// - Parameters:
    ///   - language: "auto" or an ISO code from the menu.
    ///   - accuracyMode: user's global "use Whisper everywhere" toggle.
    static func route(language: String, accuracyMode: Bool) -> EngineKind {
        if accuracyMode { return .whisper }
        if language == "auto" { return .parakeet }
        return parakeetLanguages.contains(language) ? .parakeet : .whisper
    }
}
