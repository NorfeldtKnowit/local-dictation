import Foundation
import MLXLLM
import MLXLMCommon

/// Which polish backend an utterance should use. Pure, so the routing rule is
/// unit-testable: Apple's Foundation model handles English (fast, but in
/// practice English-only — it requires the system+Siri language to be
/// English), the MLX Qwen backend handles everything else (notably Danish).
enum PolishBackendRouter {
    enum Backend { case apple, mlx }

    static func backend(for text: String, profile: GuardrailProfile) -> Backend {
        // Stylistic restyles (millennial, corporate, marketing, custom) need a model
        // that will actually COMMIT to a bold voice. Apple's FM is tuned for
        // conservative cleanup: it neutralises slang/jargon and frequently
        // echoes the input unchanged, so a restyle "does nothing". Route every
        // stylistic template to the local Qwen model regardless of language —
        // it follows style instructions far more faithfully.
        if profile == .stylistic { return .mlx }
        // Translation always goes to Qwen: Apple's FM is English-only in
        // practice, so it can't translate INTO Swedish at all, and even the
        // →English direction wants a model that will commit to a full rewrite.
        if profile == .translation { return .mlx }
        // Faithful/terse cleanup: FM is great and fast for English; everything
        // else (notably Danish) goes to Qwen. nil (undetectable, e.g. very
        // short text) folds to English — ambiguous fragments are most likely
        // English on this system and the FM call is the cheap one to waste.
        return (TextLanguageID.dominantLanguage(of: text) ?? "en") == "en" ? .apple : .mlx
    }
}

/// Composite polisher: per-utterance language routing between the Apple FM
/// polisher and the MLX Qwen polisher. Used ONLY by the review path
/// (`DictationPipeline.polishText`) — the inline `process()` polish and the
/// CLI stay Apple-FM-only, because the MLX backend can take many seconds on
/// a cold load and only the review HUD gives the user feedback meanwhile.
struct RoutedPolisher: TranscriptPolishing {
    let apple: any TranscriptPolishing
    let mlx: any TranscriptPolishing

    /// Warms only the cheap backend. The MLX warm-up (a ~2.5 GB one-time
    /// download + multi-GB load) is kicked explicitly by `AppDelegate`.
    func warmUp() async { await apple.warmUp() }

    func polish(_ text: String, template: PromptTemplate,
                onPartial: (@Sendable (String) -> Void)?) async -> String? {
        switch PolishBackendRouter.backend(for: text, profile: template.profile) {
        case .apple: return await apple.polish(text, template: template, onPartial: onPartial)
        case .mlx:   return await mlx.polish(text, template: template, onPartial: onPartial)
        }
    }
}

/// Transcript polish on a local MLX model (Qwen3-4B-Instruct, 4-bit) — the
/// backend for languages Apple's Foundation model can't do (Danish, and any
/// mixed utterance that reads as non-English). Same instruction set and the
/// same `TranscriptPolisherLogic.accept` guardrails as the FM backend: a
/// decline of any kind keeps the ASR text.
///
/// Weights come from the pinned Hugging Face revision below (`safetensors` —
/// pure data, no code execution; the revision pin is part of the 2026-07-07
/// supply-chain review). Download is one-time (~2.5 GB into the HubApi cache);
/// once loaded the model stays resident (~3 GB) for the process lifetime.
actor MLXPolisher: TranscriptPolishing {
    static let modelID = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    /// Exact HF revision, verified 2026-07-07. Bump deliberately, never track
    /// "main": a moving branch is a supply-chain surface even for data files.
    static let modelRevision = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"

    /// Ceiling on one polish call INCLUDING a warm model load (~5-10 s) and
    /// generation (~2-4 s for a typical rewrite), but intentionally NOT the
    /// first-ever download: on breach the caller keeps the ASR text while the
    /// load task keeps running in the background, so a later utterance finds
    /// the model ready. Via `AsyncTimeout.run` for the same reason as the FM
    /// backend: a wedged GPU inference ignores cooperative cancellation.
    static let timeoutSeconds: TimeInterval = 30

    /// Deduplicated load: concurrent polish calls and warmUp share one task,
    /// and an AsyncTimeout abandonment does NOT kill it (unstructured task).
    private var loadTask: Task<ModelContainer, Error>?

    func warmUp() async {
        _ = try? await container()
    }

    func polish(_ text: String, template: PromptTemplate,
                onPartial: (@Sendable (String) -> Void)?) async -> String? {
        guard TranscriptPolisherLogic.worthPolishing(text) else { return nil }
        do {
            let candidate = try await AsyncTimeout.run(seconds: Self.timeoutSeconds) {
                let container = try await self.container(onPartial: onPartial)
                return try await Self.generate(container: container,
                                               instructions: template.instructions,
                                               prompt: text,
                                               onPartial: onPartial)
            }
            switch TranscriptPolisherLogic.accept(raw: text, candidate: candidate, profile: template.profile) {
            case .accepted(let polished):
                return polished
            case .rejected(let reason):
                Log.warn("mlx polish rejected: \(reason) — keeping ASR text", "mlx")
                return nil
            }
        } catch {
            Log.warn("mlx polish failed (\(error is AsyncTimeout.TimeoutError ? "timeout" : String(describing: error))) — keeping ASR text", "mlx")
            return nil
        }
    }

    /// Load (and on first use, download) the model. `onPartial` gets coarse
    /// download-progress lines so the review HUD shows life during the
    /// one-time fetch; they are display-only, like generation partials.
    private func container(onPartial: (@Sendable (String) -> Void)? = nil) async throws -> ModelContainer {
        if let loadTask { return try await loadTask.value }
        let progress = ProgressLogger(onPartial: onPartial)
        let task = Task {
            Log.info("loading \(Self.modelID) (first use downloads ~2.5 GB)", "mlx")
            let started = Date()
            let container = try await loadModelContainer(
                id: Self.modelID,
                revision: Self.modelRevision,
                progressHandler: { progress.report($0) }
            )
            Log.info("qwen polish model ready in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", "mlx")
            return container
        }
        loadTask = task
        do {
            return try await task.value
        } catch {
            loadTask = nil   // allow a later retry (downloads resume)
            throw error
        }
    }

    /// One generation with a FRESH KV cache — per-utterance isolation, same
    /// privacy/drift rule as the FM backend's fresh session. Greedy
    /// (temperature 0) for determinism; 1024-token cap mirrors the FM side
    /// (and `worthPolishing`'s input ceiling keeps rewrites well under it).
    private static func generate(container: ModelContainer,
                                 instructions: String,
                                 prompt: String,
                                 onPartial: (@Sendable (String) -> Void)?) async throws -> String {
        try await container.perform { context in
            let input = try await context.processor.prepare(
                input: UserInput(chat: [.system(instructions), .user(prompt)]))
            let parameters = GenerateParameters(maxTokens: 1024, temperature: 0)
            let cache = context.model.newCache(parameters: parameters)
            var output = ""
            for await item in try MLXLMCommon.generate(
                input: input, cache: cache, parameters: parameters, context: context
            ) {
                if let chunk = item.chunk {
                    output += chunk
                    onPartial?(output)
                }
            }
            return output
        }
    }

    /// Thread-safe 10%-step progress reporter (the Hub progressHandler fires
    /// per chunk from a nonisolated context).
    private final class ProgressLogger: @unchecked Sendable {
        private let lock = NSLock()
        private var lastReported = -1.0
        private let onPartial: (@Sendable (String) -> Void)?

        init(onPartial: (@Sendable (String) -> Void)?) { self.onPartial = onPartial }

        func report(_ progress: Progress) {
            let fraction = progress.fractionCompleted
            lock.lock()
            let step = (fraction - lastReported) >= 0.1 || (fraction >= 1 && lastReported < 1)
            if step { lastReported = fraction }
            lock.unlock()
            guard step else { return }
            let percent = Int(fraction * 100)
            Log.info("qwen model download \(percent)%", "mlx")
            onPartial?("(downloading rewrite model… \(percent)%)")
        }
    }
}
