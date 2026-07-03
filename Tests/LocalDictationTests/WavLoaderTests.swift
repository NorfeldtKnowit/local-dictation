import AVFoundation
import XCTest
@testable import LocalDictation

/// Regression tests for the converter-tail flush in `WavLoader.load`.
///
/// The old pull loop signalled `.noDataNow` after the single input feed and
/// stopped on the first non-`.haveData` status, so `AVAudioConverter` never got
/// the `.endOfStream` cue to flush the samples still buffered inside its
/// resampler — the tail of the file (the final phoneme) was silently dropped.
final class WavLoaderTests: XCTestCase {
    /// Write a 1.0 s mono 440 Hz sine AIFF at `sampleRate` and return its URL.
    private func makeSineFile(sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavloader-\(Int(sampleRate))-\(UUID().uuidString).aiff")
        let frames = AVAudioFrameCount(sampleRate * 1.0)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?.pointee else {
            throw XCTSkip("cannot build \(Int(sampleRate)) Hz buffer on this system")
        }
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            channel[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test44100DownsampleKeepsFullDuration() throws {
        // 1.0 s at 44.1 kHz must come back as ~16 000 samples at 16 kHz.
        // Measured: old (.noDataNow) code returned 15 994 (6-frame filter tail
        // held back); the .endOfStream flush returns exactly 16 000.
        let url = try makeSineFile(sampleRate: 44_100)
        let samples = try WavLoader.load(url: url)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 16_000 * 0.01,
                       "44.1 kHz downsample lost its resampler tail")
    }

    func test8000UpsampleFlushesConverterTail() throws {
        // The upsample path is where the old code failed catastrophically: for
        // 1.0 s at 8 kHz the converter buffers roughly half the audio internally,
        // so the old (.noDataNow) loop returned only 8 160 of the expected
        // 16 000 samples — 0.49 s of speech silently discarded. The .endOfStream
        // flush returns exactly 16 000. This is the case that fails against the
        // old code (the 44.1 kHz loss above is real but inside the 1% tolerance).
        let url = try makeSineFile(sampleRate: 8_000)
        let samples = try WavLoader.load(url: url)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 16_000 * 0.01,
                       "8 kHz upsample lost the converter's buffered tail")
    }
}
