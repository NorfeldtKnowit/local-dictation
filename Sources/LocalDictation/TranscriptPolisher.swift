import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Seam for pipeline layer 4 so `DictationPipeline` (and its tests) never
/// touch FoundationModels / MLX directly.
protocol TranscriptPolishing: Sendable {
    /// Best-effort model page-in so the first real polish doesn't pay it.
    func warmUp() async
    /// Returns the polished text, or nil when polish declines — model
    /// unavailable, text not worth polishing, guardrail reject, error, or
    /// timeout. A nil ALWAYS means "keep the input text"; it is never a drop.
    ///
    /// `onPartial` (optional) receives the ACCUMULATED raw model output as it
    /// streams — display-only feedback for the review HUD. Partials are NOT
    /// guardrail-checked; only the returned final text is safe to paste.
    /// Backends without streaming simply never call it.
    func polish(_ text: String, template: PromptTemplate,
                onPartial: (@Sendable (String) -> Void)?) async -> String?
}

extension TranscriptPolishing {
    func polish(_ text: String, template: PromptTemplate) async -> String? {
        await polish(text, template: template, onPartial: nil)
    }
}

/// Post-ASR transcript polish on Apple's on-device Foundation model: repairs
/// misrecognized words from context ("canorical" → "canonical", "citation" →
/// "dictation"), collapses restarts, strips residual fillers. Fully local,
/// like everything else in this app.
///
/// Degrades gracefully exactly like the VAD gate: when Apple Intelligence is
/// off / the model isn't ready / macOS is too old, every call declines and
/// dictation behaves as if the stage didn't exist. Instructions + accept
/// guardrails live in `TranscriptPolisherLogic` (pure, unit-tested).
actor TranscriptPolisher: TranscriptPolishing {
    /// Hard ceiling on one polish call; on breach the raw transcript is used.
    /// Via `AsyncTimeout.run` (NOT a task group) so a wedged inference is
    /// abandoned at the deadline instead of blocking the utterance — see
    /// AsyncTimeout's header for why structured racing can't do this.
    static let timeoutSeconds: TimeInterval = 6

    private var loggedUnavailable = false

    func warmUp() async {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return }
        guard available() else { return }
        LanguageModelSession(instructions: TranscriptPolisherLogic.instructions).prewarm()
        Log.info("polish model pre-warm requested", "polish")
        #endif
    }

    /// `onPartial` is accepted but unused: the FM call is fast enough (~1 s)
    /// that streaming feedback adds nothing.
    func polish(_ text: String, template: PromptTemplate,
                onPartial: (@Sendable (String) -> Void)?) async -> String? {
        guard TranscriptPolisherLogic.worthPolishing(text) else { return nil }
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), available() else { return nil }
        do {
            let candidate = try await AsyncTimeout.run(seconds: Self.timeoutSeconds) {
                // Fresh session per utterance: session context accumulates, and
                // one utterance must never leak into the next. The model stays
                // resident across sessions, so this costs nothing meaningful.
                let session = LanguageModelSession(instructions: template.instructions)
                let response = try await session.respond(
                    to: text,
                    options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1024))
                return response.content
            }
            switch TranscriptPolisherLogic.accept(raw: text, candidate: candidate, profile: template.profile) {
            case .accepted(let polished):
                return polished
            case .rejected(let reason):
                Log.warn("polish rejected: \(reason) — keeping ASR text", "polish")
                return nil
            }
        } catch {
            Log.warn("polish failed (\(error is AsyncTimeout.TimeoutError ? "timeout" : String(describing: error))) — keeping ASR text", "polish")
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(FoundationModels)
    /// Availability probe; logs the reason once per process, not per utterance.
    @available(macOS 26.0, *)
    private func available() -> Bool {
        if case .unavailable(let reason) = SystemLanguageModel.default.availability {
            if !loggedUnavailable {
                loggedUnavailable = true
                Log.info("polish inactive: Apple Intelligence model unavailable (\(String(describing: reason)))", "polish")
            }
            return false
        }
        return true
    }
    #endif
}
