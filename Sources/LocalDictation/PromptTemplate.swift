import Foundation

/// How strictly the polish guardrails (`TranscriptPolisherLogic.accept`) judge a
/// rewrite. Faithful/terse templates only ever fix and condense, so they keep
/// the full guard set; stylistic templates (millennial, boomer, and any
/// user-authored prompt) deliberately introduce new words, emoji and formatting,
/// so the word-overlap and added-newline guards would reject almost every one —
/// they are dropped, leaving only the hard safety checks (non-empty, bounded
/// length, and the never-translate language guard).
///
/// `.translation` is the ONE profile that drops even the never-translate
/// language guard — making a language vanish is a translator's whole job — plus
/// the word-overlap guard (translated words don't occur in the source). Only the
/// non-empty and (wide) length checks remain; review-before-paste is the real
/// safety net for a bad translation. Reserved for the compiled-in translator
/// built-ins: a file-backed template can't reach it (the store forces `.stylistic`).
enum GuardrailProfile: Sendable, Equatable {
    case faithful
    case terse
    case stylistic
    case translation
}

/// A named polish prompt: the system instructions handed to the layer-4 rewrite
/// model plus the guardrail profile its output is judged against. Built-ins are
/// compiled in (`.standard`, `.terse`); everything else is loaded from the user's
/// templates folder by `PromptTemplateStore`.
///
/// `name` is the human-facing label (menu title, and uppercased it becomes the
/// review overlay's second-row badge). `id` is the stable code persisted in
/// `LanguageSetting.selectedTemplate` — the lowercased name for file-backed
/// templates.
struct PromptTemplate: Sendable, Equatable {
    let id: String
    let name: String
    let instructions: String
    let profile: GuardrailProfile

    /// Faithful cleanup (fillers, restarts, misrecognitions). The inline-polish
    /// default, and the safe fallback everywhere.
    static let standard = PromptTemplate(
        id: "standard",
        name: "Standard",
        instructions: TranscriptPolisherLogic.instructions,
        profile: .faithful)

    /// Standard cleanup PLUS deliberate condensing — the historical review-row
    /// rewrite and the default `selectedTemplate`.
    static let terse = PromptTemplate(
        id: "terse",
        name: "Terse",
        instructions: TranscriptPolisherLogic.terseInstructions,
        profile: .terse)

    /// Translate the utterance into idiomatic US English. Built-in (not a
    /// seeded file) because translation needs the `.translation` profile, and
    /// the store forces every file-backed template to `.stylistic`.
    static let translateEnglish = PromptTemplate(
        id: "translate-english",
        name: "Translate → English",
        instructions: TranscriptPolisherLogic.translateEnglishInstructions,
        profile: .translation)

    /// Translate the utterance into idiomatic Swedish. Same built-in rationale
    /// as `translateEnglish`.
    static let translateSwedish = PromptTemplate(
        id: "translate-swedish",
        name: "Translate → Swedish",
        instructions: TranscriptPolisherLogic.translateSwedishInstructions,
        profile: .translation)
}
