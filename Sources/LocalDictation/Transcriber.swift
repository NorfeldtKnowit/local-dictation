import Foundation
import WhisperKit

/// Wraps WhisperKit. The model is loaded lazily on the first transcription
/// so app launch stays fast. The ~1.5 GB full-precision model files are
/// fetched by the GUI's background pre-download at launch (`predownloadModel`,
/// spawned by `AppDelegate` once Parakeet is ready); if that hasn't finished
/// (or failed offline), the first use downloads whatever is missing.
actor Transcriber: TranscriptionEngine {
    /// Accuracy / broad-language backend. `nonisolated` so routing and menu code
    /// can branch on it without an `await` hop.
    nonisolated let kind = EngineKind.whisper

    /// Warmed once the pipe is loaded; mirrors `ParakeetEngine`'s manager-nil check.
    var isWarmedUp: Bool { pipe != nil }

    /// Whisper-large-v3-turbo (Sep 2024 weights), full precision, ~1.5 GB.
    /// Same turbo decoder (fast) as the old 632 MB default but WITHOUT the
    /// aggressive quantization that was hurting accuracy on Danish — the
    /// quantized 632 MB build felt "Siri quality". Multilingual incl. Danish.
    /// Override via LOCAL_DICTATION_MODEL (e.g. "openai_whisper-large-v3" for
    /// the slower, most-accurate non-turbo model, or
    /// "openai_whisper-large-v3-v20240930_turbo_632MB" to revert).
    static let defaultModel = "openai_whisper-large-v3-v20240930"

    private var pipe: WhisperKit?
    /// In-flight load memoization. Actor methods are reentrant at `await`s, so a
    /// bare check-then-await in `loadedPipe()` would let a second caller kick off
    /// a second concurrent multi-GB model load. All callers await this one task;
    /// it is cleared on failure so a retry can start a fresh load. `Void`-typed
    /// (the task assigns `pipe` itself) because `WhisperKit` is not `Sendable`
    /// and must not cross the task boundary as a result value.
    private var loadTask: Task<Void, Error>?
    private let modelName: String

    init(modelName: String? = nil) {
        self.modelName = modelName
            ?? ProcessInfo.processInfo.environment["LOCAL_DICTATION_MODEL"]
            ?? Self.defaultModel
    }

    func warmUp() async throws {
        _ = try await loadedPipe()
    }

    /// Download-only: fetch the model files into the local cache WITHOUT loading
    /// or compiling them (no RAM/ANE cost). `WhisperKit.download(variant:)` is the
    /// same call `WhisperKit(config)` / `setupModels` uses internally with the
    /// same repo + downloadBase defaults, so a later `warmUp()` finds everything
    /// on disk. Idempotent: already-cached files are skipped by the Hub snapshot.
    /// Used by the GUI's background pre-download at launch; failure (e.g. offline)
    /// is the caller's to log — the lazy download inside `warmUp()` remains the
    /// fallback.
    func predownloadModel() async throws {
        guard pipe == nil else { return }   // already loaded → nothing to fetch
        Log.info("pre-downloading WhisperKit model='\(modelName)' (~1.5 GB on a fresh install)", "whisper")
        let t0 = Date()
        _ = try await WhisperKit.download(variant: modelName)
        Log.info("WhisperKit model pre-download done in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s", "whisper")
    }

    /// Transcribes a Float32 16 kHz mono buffer and returns plain text.
    /// - Parameter language: ISO code ("da") to pin, or nil to auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> String {
        guard !samples.isEmpty else {
            Log.warn("transcribe called with 0 samples", "whisper")
            return ""
        }
        let pipe = try await loadedPipe()
        let audioSeconds = Double(samples.count) / 16_000.0
        Log.info("transcribe start: \(samples.count) samples (\(String(format: "%.2f", audioSeconds))s audio, language=\(language ?? "auto"))", "whisper")
        let t0 = Date()
        // Argument order MUST follow DecodingOptions' declaration order
        // (Configurations.swift:155): language, then detectLanguage, then
        // chunkingStrategy. The anti-hallucination thresholds
        // (compressionRatio 2.4 / logProb -1.0 / noSpeech 0.6) are already the
        // library defaults, so we deliberately do NOT restate them here.
        let opts = DecodingOptions(
            language: language,
            detectLanguage: language == nil,
            chunkingStrategy: .vad
        )
        do {
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: opts)
            let dt = Date().timeIntervalSince(t0)
            let rtf = dt / max(audioSeconds, 0.001)
            Log.info("transcribe done in \(String(format: "%.2f", dt))s (rtf=\(String(format: "%.2f", rtf))), \(results.count) result(s)", "whisper")
            return results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Log.error("pipe.transcribe threw: \(error)", "whisper")
            throw error
        }
    }

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe = pipe { return pipe }
        let task: Task<Void, Error>
        if let existing = loadTask {
            task = existing                     // a load is already in flight — join it
        } else {
            // Task {} inherits this actor's isolation, so the body may assign
            // self.pipe directly and WhisperKit never crosses a Sendable boundary.
            task = Task {
                Log.info("loading WhisperKit model='\(modelName)' (first call may download ~1.5 GB)", "whisper")
                // prewarm + load force the Core ML encoder and decoder to
                // compile and warm up *now*, instead of lazy-loading on the
                // first transcribe call (which would otherwise add ~10-30 s
                // of cold-start latency to the very first dictation).
                let config = WhisperKitConfig(
                    model: modelName,
                    verbose: false,
                    prewarm: true,
                    load: true,
                    download: true
                )
                let t0 = Date()
                let pipe = try await WhisperKit(config)
                let dt = Date().timeIntervalSince(t0)
                Log.info("WhisperKit loaded (prewarmed) in \(String(format: "%.2f", dt))s, state=\(pipe.modelState)", "whisper")
                self.pipe = pipe
            }
            loadTask = task
        }
        do {
            try await task.value
        } catch {
            // Only the task that failed clears the slot: a stale awaiter must not
            // wipe out a NEWER retry another caller already started.
            if loadTask == task { loadTask = nil }
            Log.error("WhisperKit init threw: \(error)", "whisper")
            throw error
        }
        guard let pipe else {
            // Unreachable: a successfully completed load task always set `pipe`.
            throw EngineError.notReady
        }
        return pipe
    }
}
