import AVFoundation
import Foundation

/// Loads an audio file from disk and returns it as the same 16 kHz mono Float32
/// buffer the live capture path produces, so the CLI `--transcribe-file` mode
/// feeds the exact sample format `DictationPipeline` (and both engines) expect.
///
/// This is deliberately independent of `AudioRecorder`: the capture path is a
/// sacred file (see CLAUDE.md) and must stay byte-for-byte unchanged. We share
/// only the *target-format constants* (`AudioRecorder.targetSampleRate`, mono,
/// Float32) — not the code — so fixture fidelity matches production without
/// touching the recorder. Any format `AVAudioFile` can read (AIFF from `say`,
/// WAV, m4a, …) is accepted; `AVAudioConverter` handles the resample + downmix.
enum WavLoader {
    enum LoadError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let why): return why
            }
        }
    }

    /// Read `url` and return a 16 kHz mono Float32 buffer.
    /// - Throws: `LoadError.unreadable` if the file can't be opened/read/converted.
    static func load(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw LoadError.unreadable("cannot open \(url.lastPathComponent): \(error.localizedDescription)")
        }

        // `processingFormat` is always deinterleaved Float32 at the file's native
        // sample rate / channel count — the ideal source format for the converter.
        let inputFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw LoadError.unreadable("empty or unsupported audio: \(url.lastPathComponent)")
        }
        do {
            try file.read(into: inBuffer)
        } catch {
            throw LoadError.unreadable("read failed for \(url.lastPathComponent): \(error.localizedDescription)")
        }

        // Same target the recorder pins: 16 kHz mono Float32 non-interleaved.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw LoadError.unreadable("cannot build 16 kHz mono converter for \(url.lastPathComponent)")
        }

        // Pull loop: feed the whole file once, then signal `.endOfStream` so the
        // converter flushes its resampler tail, and keep draining output buffers
        // until it reports `.endOfStream` back. Signalling `.noDataNow` instead
        // would make the converter hold back the samples still inside its filter
        // (a few frames on a 44.1 kHz downsample, ~half the audio on an 8 kHz
        // upsample), truncating the final phoneme of the fixture.
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 4096)
        var out: [Float] = []
        var fedInput = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw LoadError.unreadable("cannot allocate output buffer for \(url.lastPathComponent)")
            }
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if fedInput {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                fedInput = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error || error != nil {
                throw LoadError.unreadable("convert failed for \(url.lastPathComponent): \(String(describing: error))")
            }
            let frames = Int(outBuffer.frameLength)
            if frames > 0, let channelData = outBuffer.floatChannelData?[0] {
                out.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frames))
            }
            if status == .endOfStream { break }
        }
        return out
    }
}
