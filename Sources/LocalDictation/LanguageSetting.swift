import Foundation

/// Thin UserDefaults wrapper for the persisted dictation preferences:
/// the language pin ("auto" or an ISO code), the Accuracy Mode toggle
/// (force Whisper for every language), the Polish Transcript toggle
/// (LLM cleanup pass, on by default — it degrades to a no-op when the
/// Apple Intelligence model is unavailable), and the Copy Instead of
/// Paste toggle (leave the transcript on the clipboard rather than
/// injecting Cmd+V into the focused app).
///
/// `defaults` is injectable so tests can drive an isolated
/// `UserDefaults(suiteName:)` rather than the app's shared domain. The
/// accessors are `nonmutating set` because the state lives in UserDefaults,
/// not in the struct — a copied `LanguageSetting` still writes through to the
/// same backing store.
struct LanguageSetting {
    static let languageKey = "language"        // "auto" | ISO code; default "auto"
    static let accuracyKey = "accuracyMode"    // Bool; default false
    static let polishKey = "polishTranscript"  // Bool; default true
    static let copyKey = "copyInsteadOfPaste"  // Bool; default false
    static let reviewKey = "reviewBeforePaste" // Bool; default false
    static let reviewAutoInsertKey = "reviewAutoInsert" // "auto" | "never" | seconds; default "auto"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var language: String {
        get { defaults.string(forKey: Self.languageKey) ?? "auto" }
        nonmutating set { defaults.set(newValue, forKey: Self.languageKey) }
    }

    var accuracyMode: Bool {
        get { defaults.bool(forKey: Self.accuracyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.accuracyKey) }
    }

    /// Default-true needs the object probe: `bool(forKey:)` can't tell
    /// "never set" from "set to false".
    var polishTranscript: Bool {
        get { defaults.object(forKey: Self.polishKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.polishKey) }
    }

    var copyInsteadOfPaste: Bool {
        get { defaults.bool(forKey: Self.copyKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.copyKey) }
    }

    /// Review Before Paste: show the overlay offering raw vs terse-polished
    /// text after each dictation. Effective only while `polishTranscript` is
    /// on (without polish there is only one candidate — nothing to review).
    var reviewBeforePaste: Bool {
        get { defaults.bool(forKey: Self.reviewKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.reviewKey) }
    }

    /// Review overlay auto-insert delay: "auto" (length-scaled), "never"
    /// (wait for a click), or a number of seconds as a string ("10").
    /// Decoded by `ReviewQueueLogic.TimeoutPolicy.from(code:)`.
    var reviewAutoInsert: String {
        get { defaults.string(forKey: Self.reviewAutoInsertKey) ?? "auto" }
        nonmutating set { defaults.set(newValue, forKey: Self.reviewAutoInsertKey) }
    }
}
