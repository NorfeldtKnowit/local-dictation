import AppKit
import AVFoundation

@main
struct LocalDictationMain {
    static func main() async {
        Log.installCrashHandlers()
        // Parse the CLI grammar BEFORE any AppKit / NSApplication state exists, so
        // the headless `--transcribe-file` path never creates a status item, hotkey
        // tap, or requests TCC permissions. `parse` returns nil when there are no
        // CLI arguments (the LaunchAgent launches us with none) → run the GUI.
        guard let parsed = CLIArguments.parse(CommandLine.arguments) else {
            runApp()
            return
        }
        switch parsed {
        case .success(let cli):
            exit(await CLIRunner.run(cli))
        case .failure(let error):
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            exit(1)
        }
    }

    /// Today's menu-bar launch path, verbatim: status item, hotkey, permissions,
    /// model warm-up. Reached only when no CLI arguments are present.
    private static func runApp() {
        Log.info("=== local-dictation launching ===")
        Log.info("log file: \(Log.logFilePath)")
        Log.info("pid: \(ProcessInfo.processInfo.processIdentifier), arch: \(machineArch()), macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBar()
    private let recorder = AudioRecorder()

    /// Engines + gate are owned here (not only inside the pipeline) so the
    /// launch fallback can warm Whisper directly if Parakeet fails to load.
    /// `pipeline` is the single reuse point shared with the CLI: gate → route →
    /// transcribe → filter all live there, never here.
    private let parakeet = ParakeetEngine()
    private let whisper = Transcriber()
    private let gate = SpeechGate()
    private lazy var pipeline = DictationPipeline(parakeet: parakeet, whisper: whisper, gate: gate)

    /// Persisted language pin + Accuracy Mode; rendered by MenuBar, owned here.
    private let settings = LanguageSetting()

    private var hotkey: HotkeyMonitor?

    /// Pure recording/transcription bookkeeping (monotonic utterance IDs).
    /// All recorder/menu side effects hang off the Actions it returns.
    private var utterance = UtteranceStateMachine()

    /// Set when Parakeet fails to warm at launch. Equivalent to Accuracy Mode:
    /// every utterance routes to Whisper, which is a safe universal superset of
    /// Parakeet's languages. Never the reverse — a Whisper failure must not
    /// silently degrade an explicit accuracy request to Parakeet.
    private var forceWhisper = false

    /// Lost-release watchdog. The tap-level synthetic release covers tap
    /// disables, but a release can also vanish in ways the tap never sees
    /// (secure-input focus steals, dropped flagsChanged). 120 s is longer than
    /// any sane push-to-talk hold yet bounds how long the mic can stay hot.
    private static let lostReleaseTimeout: TimeInterval = 120
    private var lostReleaseTimer: Timer?

    /// Hang guard: one pipeline.process call may not exceed this, so a wedged
    /// Core ML graph / model download can't pin the menu on "Transcribing…" forever.
    private static let transcriptionTimeout: TimeInterval = 120

    private var captureErrorObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching", "app")
        menuBar.onQuit = { Log.info("user-quit", "app"); NSApp.terminate(nil) }
        menuBar.onOpenAccessibility = { Permissions.openAccessibilitySettings() }
        menuBar.onOpenInputMonitoring = { Permissions.openInputMonitoringSettings() }
        menuBar.onOpenMicrophone = { Permissions.openMicrophoneSettings() }
        menuBar.onToggleRecord = { [weak self] in self?.toggleRecording() }
        menuBar.onSelectLanguage = { [weak self] code in
            self?.settings.language = code
            Log.info("language pinned: \(code) (takes effect next utterance)", "app")
        }
        menuBar.onToggleAccuracy = { [weak self] enabled in
            self?.settings.accuracyMode = enabled
            Log.info("accuracy mode: \(enabled)", "app")
        }
        menuBar.setLanguage(settings.language)
        menuBar.setAccuracyMode(settings.accuracyMode)

        // Additive AVCaptureSession runtime-error observer. AudioRecorder itself
        // is deliberately untouched (sacred capture path, see CLAUDE.md), so we
        // observe globally: ours is the only capture session in this process,
        // and we act only while recording. A runtime error mid-capture means the
        // buffer has stopped growing — funnel through the normal end path so the
        // device is released and whatever audio WAS captured still transcribes.
        captureErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            Log.error("capture session runtime error: \(String(describing: error))", "audio")
            if self.utterance.isRecording { self.endRecording() }
        }

        menuBar.update(.loading("Requesting permissions…"))

        Task { @MainActor in
            let micGranted = await Permissions.requestMicrophone()
            Log.info("microphone permission granted=\(micGranted)", "perm")
            if !micGranted {
                menuBar.update(.error("Microphone permission denied"))
                return
            }

            let trusted = Permissions.ensureAccessibility(prompt: true)
            Log.info("accessibility trusted=\(trusted)", "perm")

            let hotkey = HotkeyMonitor { [weak self] transition in
                guard let self = self else { return }
                switch transition {
                case .pressed: self.beginRecording()
                case .released: self.endRecording()
                }
            }
            let started = hotkey.start()
            Log.info("hotkey tap started=\(started)", "hotkey")
            if !started {
                menuBar.update(.error("Grant Accessibility permission, then relaunch"))
                return
            }
            self.hotkey = hotkey

            // Warm only the launch defaults: VAD + Parakeet (both load in
            // seconds from the local cache). Whisper stays lazy — its multi-
            // minute cold load and ~1.5 GB residency are paid only on first
            // actual use, with menu feedback via the onColdLoad callback.
            menuBar.update(.loading("Loading speech models…"))
            do {
                try await pipeline.warmUpDefaults()
                utterance.engineReady = true
                Log.info("model ready", "app")
                menuBar.update(.idle)
            } catch {
                // Launch-time exception to "never substitute engines": Whisper
                // covers every language Parakeet does, so forcing it is always
                // correct — and since every utterance will now need it, warm it
                // eagerly here rather than on the first dictation.
                Log.error("parakeet warm-up failed — using Whisper for this session: \(error)", "app")
                forceWhisper = true
                menuBar.update(.loading("Parakeet unavailable — loading Whisper…"))
                do {
                    try await whisper.warmUp()
                    utterance.engineReady = true
                    Log.info("model ready (whisper-only fallback)", "app")
                    menuBar.update(.idle)
                } catch {
                    Log.error("warmUp failed: \(error)", "app")
                    menuBar.update(.error("Model load failed — see log"))
                }
            }
        }
    }

    /// The LaunchAgent gets kickstarted and the user can quit mid-recording;
    /// tear the capture session down so the mic (and the orange "in use"
    /// indicator) never outlives the process. recorder.stop() is a no-op when idle.
    func applicationWillTerminate(_ notification: Notification) {
        Log.info("applicationWillTerminate — releasing mic", "app")
        lostReleaseTimer?.invalidate()
        if let observer = captureErrorObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        recorder.stop()
        hotkey?.stop()
    }

    /// Click / menu entry point: start if idle, stop if already recording.
    /// The Right Option hotkey still uses press/release (push-to-talk); both
    /// funnel through the same begin/end so the two interaction styles coexist.
    private func toggleRecording() {
        if utterance.isRecording {
            endRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard case .startCapture(let id) = utterance.begin() else {
            Log.warn("beginRecording ignored (engineReady=\(utterance.engineReady), recording=\(utterance.isRecording))", "app")
            return
        }
        Log.info("beginRecording id=\(id)", "app")
        do {
            try recorder.start()
            menuBar.update(.listening)
            scheduleLostReleaseWatchdog(id: id)
        } catch {
            Log.error("recorder.start failed: \(error)", "app")
            // Roll the state machine back out of "recording": end() + settled()
            // restores pre-begin state — the capture never actually started, so
            // there is nothing to transcribe and nothing in flight.
            if case .stopCaptureAndProcess(let failedID) = utterance.end() {
                utterance.settled(failedID)
            }
            menuBar.update(.error(error.localizedDescription))
        }
    }

    private func endRecording() {
        guard case .stopCaptureAndProcess(let id) = utterance.end() else {
            Log.warn("endRecording while not recording", "app")
            return
        }
        lostReleaseTimer?.invalidate()
        lostReleaseTimer = nil
        let samples = recorder.stop()
        Log.info("endRecording id=\(id) captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioRecorder.targetSampleRate))s)", "app")
        menuBar.update(.transcribing)
        transcribe(id: id, samples: samples)
    }

    private func transcribe(id: UInt64, samples: [Float]) {
        // Snapshot settings at utterance end so a mid-transcription menu change
        // can't retroactively alter an utterance that was already spoken.
        let language = settings.language
        let accuracy = settings.accuracyMode || forceWhisper

        Task { @MainActor in
            do {
                let outcome = try await AsyncTimeout.run(seconds: Self.transcriptionTimeout) { [pipeline, menuBar] in
                    try await pipeline.process(
                        samples: samples,
                        language: language,
                        accuracyMode: accuracy,
                        onColdLoad: { kind in
                            // First routed use of a cold engine (in practice:
                            // Whisper via Accuracy Mode / a non-Parakeet pin).
                            // Reuses the existing .loading state — no 6th state.
                            menuBar.update(.loading(kind == .whisper
                                ? "Loading Whisper model (first use)…"
                                : "Loading Parakeet model…"))
                        }
                    )
                }
                utterance.settled(id)
                Log.info("utterance \(id): engine=\(outcome.engine.rawValue) gate=\(outcome.gate) filtered=\(outcome.filtered) inference=\(String(format: "%.2f", outcome.inferenceSeconds))s, \(outcome.text.count) chars: \(outcome.text.prefix(120))", "app")
                if !outcome.text.isEmpty {
                    TextInjector.paste(outcome.text)
                }
                refreshMenuState()
            } catch {
                utterance.settled(id)
                Log.error("transcribe failed (id=\(id)): \(error)", "app")
                menuBar.update(.error(error is AsyncTimeout.TimeoutError
                    ? "Transcription timed out"
                    : error.localizedDescription))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                refreshMenuState()
            }
        }
    }

    /// Menu precedence: listening > transcribing > idle. A new capture may start
    /// while a previous transcription is still in flight (the engines are actors
    /// and serialize; fresh decoder state per call means no bleed) — the icon
    /// must show the live capture during that overlap, not the background work.
    private func refreshMenuState() {
        if utterance.isRecording {
            menuBar.update(.listening)
        } else if utterance.isTranscribing {
            menuBar.update(.transcribing)
        } else {
            menuBar.update(.idle)
        }
    }

    /// Belt-and-braces for a swallowed hotkey release the tap never saw. Fires
    /// only if the SAME utterance (by monotonic ID) is still capturing after the
    /// timeout — a normal end/begin cycle in between makes it a no-op.
    private func scheduleLostReleaseWatchdog(id: UInt64) {
        lostReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lostReleaseTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.utterance.isRecording, self.utterance.recordingID == id else { return }
            Log.warn("lost-release watchdog fired (id=\(id)) — forcing endRecording", "app")
            self.endRecording()
        }
        // .common so it fires even while the status-item menu is open.
        RunLoop.main.add(timer, forMode: .common)
        lostReleaseTimer = timer
    }

}
