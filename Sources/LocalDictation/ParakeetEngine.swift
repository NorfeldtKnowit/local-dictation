import Foundation
import FluidAudio

/// Wraps FluidAudio's Parakeet TDT v3 (`AsrManager`) as a `TranscriptionEngine`.
/// This is the low-latency default: the int8 encoder runs on the Apple Neural
/// Engine at ~100x real-time, so a typical push-to-talk utterance transcribes in
/// well under the 500 ms end-to-end budget. Models are ANE-resident and small,
/// so warm-up is seconds (not the 3-4 min Whisper cold-load), which is why the
/// pipeline can afford to warm Parakeet eagerly at launch while Whisper stays lazy.
actor ParakeetEngine: TranscriptionEngine {
    nonisolated let kind = EngineKind.parakeet

    /// Non-nil only after `warmUp()` has fully loaded *and* primed the models, so
    /// its nil-ness is a truthful "ready" flag. We intentionally do NOT proxy to
    /// `AsrManager.isAvailable`: that lives on the `AsrManager` actor and would
    /// require an `await`, which a synchronous `isWarmedUp` getter cannot do.
    private var manager: AsrManager?

    /// In-flight load memoization. Actor methods are reentrant at `await`s, so a
    /// bare `guard manager == nil` check-then-await would let a second concurrent
    /// caller start a second model load. All callers await this one task; it is
    /// cleared on failure so a retry can start a fresh load.
    private var loadTask: Task<AsrManager, Error>?

    var isWarmedUp: Bool { manager != nil }

    func warmUp() async throws {
        guard manager == nil else { return }   // idempotent
        let task: Task<AsrManager, Error>
        if let existing = loadTask {
            task = existing                     // a load is already in flight — join it
        } else {
            task = Task {
                let t0 = Date()
                // v3 is the multilingual TDT model whose script-filter `language:` hint we
                // rely on for routing; the models are already cached on this machine so the
                // "download" is a fast cache hit.
                let models = try await AsrModels.downloadAndLoad(version: .v3)
                let m = AsrManager(config: .default, models: models)

                // Prime the ANE with 1 s of silence so the very first *real* utterance
                // pays no Core ML cold-compile tax. Best-effort: a too-short/invalid prime
                // input can throw, and we don't care — the point is to force graph warm-up.
                var primeState = TdtDecoderState.make()   // v3 uses the default 2 decoder layers
                _ = try? await m.transcribe(
                    [Float](repeating: 0, count: 16_000),
                    decoderState: &primeState,
                    language: nil
                )

                Log.info("parakeet warmed up in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s", "parakeet")
                return m
            }
            loadTask = task
        }
        do {
            manager = try await task.value
        } catch {
            // Only the task that failed clears the slot: a stale awaiter must not
            // wipe out a NEWER retry another caller already started.
            if loadTask == task { loadTask = nil }
            throw error
        }
    }

    /// Transcribe a 16 kHz mono Float32 buffer.
    /// - Parameter language: ISO code ("da") mapped to a `Language` script-filter
    ///   hint (v3-only; skips top-K tokens whose script doesn't match), or nil to
    ///   let the model self-detect among its supported languages.
    func transcribe(samples: [Float], language: String?) async throws -> EngineResult {
        guard let manager else { throw EngineError.notReady }
        // Fresh decoder state per utterance: no token/context bleed from the
        // previous dictation. (The `inout` API keeps the door open for a future
        // streaming design that carries state across segments.)
        var state = TdtDecoderState.make()
        // Bare `Language`, not `FluidAudio.Language`: the module exports a
        // `public struct FluidAudio` that shadows the module name, so the
        // qualified form fails to resolve. Unknown/unsupported codes map to nil
        // (auto), which is the correct fail-open behaviour.
        let hint = language.flatMap(Language.init(rawValue:))
        let result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        Log.info("parakeet ok rtfx=\(String(format: "%.1f", result.rtfx)) conf=\(String(format: "%.2f", result.confidence))", "parakeet")
        return EngineResult(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            confidence: Double(result.confidence))
    }
}
