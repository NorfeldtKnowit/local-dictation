import Foundation

/// Which local speech-to-text backend produced (or should produce) a transcript.
/// `parakeet` is the low-latency default (FluidAudio Parakeet TDT v3, ANE-resident);
/// `whisper` is the accuracy / broad-language fallback (WhisperKit large-v3).
enum EngineKind: String, Sendable, CaseIterable { case parakeet, whisper }

/// Common seam over the two transcription backends so the pipeline can route,
/// warm, and call either without caring which one it holds.
///
/// Both conformers are actors: model state (Core ML pipes, decoder state) is
/// mutable and must not be touched concurrently, and serialising calls through
/// the actor is exactly the isolation we want — a fresh utterance can be
/// dispatched while a previous one is still transcribing without bleed.
protocol TranscriptionEngine: Actor {
    /// Stable identity of the backend. `nonisolated` so callers can branch on it
    /// (e.g. menu labels, routing) without an `await` hop.
    nonisolated var kind: EngineKind { get }

    /// True once models are loaded and the engine can transcribe immediately.
    var isWarmedUp: Bool { get }

    /// Load / download models. Idempotent: safe to call repeatedly; a no-op once warm.
    func warmUp() async throws

    /// Transcribe a 16 kHz mono Float32 buffer.
    /// - Parameter language: ISO code ("da") to pin, or nil to auto-detect.
    func transcribe(samples: [Float], language: String?) async throws -> EngineResult
}

/// One engine's transcript plus how sure it was about it.
///
/// `confidence` exists because Parakeet v3's language handling is only a
/// script filter: it cannot be *forced* to decode Danish over English (both
/// Latin script), so its wrong-language failures are invisible in the text
/// alone — but they show up clearly as low confidence (measured: 0.88-0.97 on
/// clean same-language audio vs 0.59 on a real Danish utterance it decoded as
/// English). The pipeline uses this signal to rescue low-confidence Parakeet
/// utterances through Whisper. Whisper reports nil (no comparable scalar).
struct EngineResult: Sendable {
    let text: String
    let confidence: Double?
}

/// Raised when a transcribe call arrives before the engine has been warmed up.
/// The pipeline warms lazily before every call, so this is a guard against
/// programmer error rather than an expected runtime path.
enum EngineError: Error { case notReady }
