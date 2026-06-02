import Foundation
import WhisperKit

/// Wraps WhisperKit. The model is loaded lazily on the first transcription
/// so app launch stays fast; the ~600 MB download happens on first use.
actor Transcriber {
    /// Whisper-large-v3 (Sep 2024 weights) with turbo decoder (4 layers
    /// vs. 32) and 4-bit quantization, ~632 MB. Multilingual including
    /// Danish, and roughly 5-8× faster than the non-turbo large-v3 with
    /// near-identical accuracy. Override via LOCAL_DICTATION_MODEL.
    static let defaultModel = "openai_whisper-large-v3-v20240930_turbo_632MB"

    private var pipe: WhisperKit?
    private let modelName: String

    init(modelName: String? = nil) {
        self.modelName = modelName
            ?? ProcessInfo.processInfo.environment["LOCAL_DICTATION_MODEL"]
            ?? Self.defaultModel
    }

    func warmUp() async throws {
        _ = try await loadedPipe()
    }

    /// Transcribes a Float32 16 kHz mono buffer and returns plain text.
    func transcribe(samples: [Float]) async throws -> String {
        guard !samples.isEmpty else {
            Log.warn("transcribe called with 0 samples", "whisper")
            return ""
        }
        let pipe = try await loadedPipe()
        let audioSeconds = Double(samples.count) / 16_000.0
        Log.info("transcribe start: \(samples.count) samples (\(String(format: "%.2f", audioSeconds))s audio)", "whisper")
        let t0 = Date()
        do {
            let results = try await pipe.transcribe(audioArray: samples)
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
        Log.info("loading WhisperKit model='\(modelName)' (first call may download ~600 MB)", "whisper")
        do {
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
            return pipe
        } catch {
            Log.error("WhisperKit init threw: \(error)", "whisper")
            throw error
        }
    }
}
