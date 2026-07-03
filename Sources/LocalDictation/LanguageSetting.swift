import Foundation

/// Thin UserDefaults wrapper for the two persisted dictation preferences:
/// the language pin ("auto" or an ISO code) and the Accuracy Mode toggle
/// (force Whisper for every language).
///
/// `defaults` is injectable so tests can drive an isolated
/// `UserDefaults(suiteName:)` rather than the app's shared domain. The
/// accessors are `nonmutating set` because the state lives in UserDefaults,
/// not in the struct — a copied `LanguageSetting` still writes through to the
/// same backing store.
struct LanguageSetting {
    static let languageKey = "language"        // "auto" | ISO code; default "auto"
    static let accuracyKey = "accuracyMode"    // Bool; default false

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
}
