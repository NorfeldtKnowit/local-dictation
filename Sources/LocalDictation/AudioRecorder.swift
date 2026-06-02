import AVFoundation
import CoreMedia
import Foundation

/// Captures microphone audio with AVCaptureSession, online-converts to 16 kHz
/// mono Float32, and returns the full buffer on stop. Designed for short
/// push-to-talk segments held in memory — not for long-running streams.
///
/// We use AVCaptureSession rather than AVAudioEngine: on some machines (notably
/// when running as a LaunchAgent, and with Bluetooth HFP / virtual audio devices
/// present) AVAudioEngine's input node fails to attach to the real default
/// device — it reports a phantom 44.1 kHz format, delivers zero buffers, and
/// holds the mic open without ever releasing it. The capture stack does not have
/// that problem: it binds to AVCaptureDevice.default(for: .audio) and releases
/// the device cleanly on stopRunning().
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "local-dictation.capture")
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat
    private var samples: [Float] = []
    private let samplesQueue = DispatchQueue(label: "local-dictation.audio.samples")
    private var isRunning = false

    // Diagnostics for a single session, reset on each start().
    private var sampleBufferCount = 0
    private var inputFrames = 0
    private var convertErrors = 0
    private var loggedFirstChunk = false

    static let targetSampleRate: Double = 16_000

    override init() {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            fatalError("Could not create 16 kHz mono target format")
        }
        self.targetFormat = target
        super.init()
    }

    func start() throws {
        guard !isRunning else { return }
        samplesQueue.sync { samples.removeAll(keepingCapacity: true) }
        sampleBufferCount = 0
        inputFrames = 0
        convertErrors = 0
        loggedFirstChunk = false
        converter = nil

        guard let device = AVCaptureDevice.default(for: .audio) else {
            Log.error("no default audio capture device — no mic, or permission denied", "audio")
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }
        Log.info("capture device: \(device.localizedName)", "audio")

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Log.error("AVCaptureDeviceInput init failed: \(error)", "audio")
            throw error
        }

        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw NSError(domain: "AudioRecorder", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio input to capture session"])
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "AudioRecorder", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot add audio output to capture session"])
        }
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        self.output = output
        session.startRunning()
        isRunning = true
        Log.info("capture session started", "audio")
    }

    /// Stops the session and returns the accumulated Float32 mono 16 kHz buffer.
    @discardableResult
    func stop() -> [Float] {
        guard isRunning else { return [] }
        isRunning = false

        // Explicit, complete teardown so the device is released immediately and
        // the macOS "microphone in use" indicator turns off. Just stopRunning()
        // and dropping the reference can leave the session lingering.
        if let session = session {
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
        output?.setSampleBufferDelegate(nil, queue: nil)
        output = nil
        session = nil

        let captured = samplesQueue.sync { samples }
        Log.info("stop: captured \(captured.count) samples (sample buffers=\(sampleBufferCount), input frames=\(inputFrames), convert errors=\(convertErrors))", "audio")
        return captured
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRunning else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        var asbd = asbdPtr.pointee
        guard let inputFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        // Lazily build the converter from the real capture format.
        if converter == nil {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            Log.info("capture stream format sr=\(inputFormat.sampleRate) ch=\(inputFormat.channelCount) common=\(inputFormat.commonFormat.rawValue) -> \(Self.targetSampleRate)", "audio")
        }
        guard let converter = converter else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return }
        inBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: inBuffer.mutableAudioBufferList)
        if copyStatus != noErr {
            convertErrors += 1
            if convertErrors <= 3 { Log.error("CMSampleBufferCopyPCMData failed status=\(copyStatus)", "audio") }
            return
        }

        sampleBufferCount += 1
        inputFrames += Int(frameCount)

        convert(inBuffer, with: converter)
    }

    private func convert(_ inBuffer: AVAudioPCMBuffer, with converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / inBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 4096)

        var fedInput = false
        while true {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if fedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fedInput = true
                outStatus.pointee = .haveData
                return inBuffer
            }

            if status == .error || error != nil {
                convertErrors += 1
                if convertErrors <= 3 {
                    Log.error("converter.convert status=\(status.rawValue) error=\(String(describing: error))", "audio")
                }
                return
            }

            let frames = Int(outBuffer.frameLength)
            if frames > 0, let channelData = outBuffer.floatChannelData?[0] {
                let chunk = Array(UnsafeBufferPointer(start: channelData, count: frames))
                samplesQueue.sync { samples.append(contentsOf: chunk) }
                if !loggedFirstChunk {
                    loggedFirstChunk = true
                    Log.debug("first converted chunk: in=\(inBuffer.frameLength)@\(inBuffer.format.sampleRate) -> out=\(frames)@\(targetFormat.sampleRate)", "audio")
                }
            }

            if status != .haveData { break }
        }
    }
}
