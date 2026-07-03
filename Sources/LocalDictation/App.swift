import AppKit

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
    private let transcriber = Transcriber()
    private var hotkey: HotkeyMonitor?
    private var isRecording = false
    private var modelReady = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("applicationDidFinishLaunching", "app")
        menuBar.onQuit = { Log.info("user-quit", "app"); NSApp.terminate(nil) }
        menuBar.onOpenAccessibility = { Permissions.openAccessibilitySettings() }
        menuBar.onOpenInputMonitoring = { Permissions.openInputMonitoringSettings() }
        menuBar.onOpenMicrophone = { Permissions.openMicrophoneSettings() }
        menuBar.onToggleRecord = { [weak self] in self?.toggleRecording() }

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

            menuBar.update(.loading("Loading Whisper model…"))
            do {
                try await transcriber.warmUp()
                modelReady = true
                Log.info("model ready", "app")
                menuBar.update(.idle)
            } catch {
                Log.error("warmUp failed: \(error)", "app")
                menuBar.update(.error("Model load failed — see log"))
            }
        }
    }

    /// Click / menu entry point: start if idle, stop if already recording.
    /// The Right Option hotkey still uses press/release (push-to-talk); both
    /// funnel through the same begin/end so the two interaction styles coexist.
    private func toggleRecording() {
        if isRecording {
            endRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard modelReady else {
            Log.warn("beginRecording ignored — model not ready yet", "app")
            return
        }
        guard !isRecording else { Log.warn("beginRecording while already recording", "app"); return }
        Log.info("beginRecording", "app")
        do {
            try recorder.start()
            isRecording = true
            menuBar.update(.listening)
        } catch {
            Log.error("recorder.start failed: \(error)", "app")
            menuBar.update(.error(error.localizedDescription))
        }
    }

    private func endRecording() {
        guard isRecording else { Log.warn("endRecording while not recording", "app"); return }
        isRecording = false
        let samples = recorder.stop()
        Log.info("endRecording captured \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioRecorder.targetSampleRate))s)", "app")
        menuBar.update(.transcribing)

        Task {
            do {
                let t0 = Date()
                // language: nil = auto-detect. Stage 2 keeps the app on the
                // Whisper-only path; routing to Parakeet is wired in a later stage.
                let text = try await transcriber.transcribe(samples: samples, language: nil)
                let dt = Date().timeIntervalSince(t0)
                Log.info("transcribe ok in \(String(format: "%.2f", dt))s, \(text.count) chars: \(text.prefix(120))", "app")
                if !text.isEmpty {
                    await MainActor.run { TextInjector.paste(text) }
                }
                menuBar.update(.idle)
            } catch {
                Log.error("transcribe failed: \(error)", "app")
                menuBar.update(.error(error.localizedDescription))
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                menuBar.update(.idle)
            }
        }
    }
}
