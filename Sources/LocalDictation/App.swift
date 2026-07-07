import AppKit
import AVFoundation

@main
struct LocalDictationMain {
    static func main() async {
        Log.installCrashHandlers()
        // Parse the CLI grammar BEFORE any AppKit / NSApplication state exists, so
        // the headless `--transcribe-file` path never creates a status item, hotkey
        // tap, or requests TCC permissions. `parse` returns nil for a GUI launch:
        // either no arguments (how the LaunchAgent starts us) or stray argv tokens
        // macOS injects into app launches (-psn_…, -NSSomething) — those must be
        // ignored, never exit(1) the whole app.
        guard let parsed = CLIArguments.parse(CommandLine.arguments) else {
            let stray = Array(CommandLine.arguments.dropFirst())
            if !stray.isEmpty {
                Log.warn("ignoring non-CLI launch arguments: \(stray)", "cli")
            }
            runApp()
            return
        }
        switch parsed {
        case .success(let cli):
            exit(await CLIRunner.run(cli))
        case .failure(let error) where error.isHelpRequest:
            print(error.message)
            exit(0)
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
    private let polisher = TranscriptPolisher()
    private lazy var pipeline = DictationPipeline(parakeet: parakeet, whisper: whisper, gate: gate,
                                                  polisher: polisher)

    /// Persisted language pin + Accuracy Mode; rendered by MenuBar, owned here.
    private let settings = LanguageSetting()

    private var hotkey: HotkeyMonitor?

    /// Pure recording/transcription bookkeeping (monotonic utterance IDs).
    /// All recorder/menu side effects hang off the Actions it returns.
    private var utterance = UtteranceStateMachine()

    /// Reorders overlapping utterances' outcomes into strict utterance-ID order
    /// and keeps consecutive pastes >= 300 ms apart, so a slow utterance can't
    /// paste after a faster later one and two pastes can't interleave with
    /// TextInjector's 200 ms pasteboard save/restore window. EVERY allocated
    /// utterance ID must be completed (empty text for gated/error/never-captured
    /// outcomes) or the queue stalls behind the missing ID.
    private lazy var pasteSequencer = PasteSequencer(
        schedule: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        // Delivery mode is read at FLUSH time (not utterance end): the sequencer
        // may hold an outcome briefly, and the mode the user sees checked when
        // the text lands is the one that should apply.
        paste: { [settings] text in
            if settings.copyInsteadOfPaste {
                TextInjector.copy(text)
            } else {
                TextInjector.paste(text)
            }
        }
    )

    /// Review Before Paste: pure queue logic + AppKit overlay. Every reviewed
    /// utterance still settles through `pasteSequencer.complete` (click,
    /// dismiss and timeout all converge there), so utterance-ID ordering and
    /// the every-ID-completes contract are untouched by review mode.
    private lazy var reviewCoordinator = ReviewCoordinator(
        schedule: { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        complete: { [weak self] id, text in
            self?.pasteSequencer.complete(id: id, text: text)
        }
    )

    /// Set when Parakeet fails to warm at launch. Equivalent to Accuracy Mode:
    /// every utterance routes to Whisper, which is a safe universal superset of
    /// Parakeet's languages. Never the reverse — a Whisper failure must not
    /// silently degrade an explicit accuracy request to Parakeet.
    private var forceWhisper = false

    /// Lost-release watchdog. The tap-level synthetic release covers tap
    /// disables, but a release can also vanish in ways the tap never sees
    /// (secure-input focus steals, dropped flagsChanged). 120 s is longer than
    /// any sane push-to-talk hold yet bounds how long the mic can stay hot.
    /// When it fires, the physical key state decides (see `LostReleaseWatchdog`):
    /// a genuinely still-held Right Option re-arms instead of truncating.
    private static let lostReleaseTimeout: TimeInterval = 120
    private var lostReleaseTimer: Timer?

    /// Physical "is Right Option down right now?" probe, injected into the
    /// watchdog decision. `CGEventSource.keyState` reads the session's HID
    /// state for any virtual keycode, modifiers included; 61 is Right Option,
    /// the same keycode `HotkeyMonitor`'s tap watches.
    private let hotkeyStillDown: () -> Bool = {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(61))
    }

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
        menuBar.onTogglePolish = { [weak self, polisher] enabled in
            self?.settings.polishTranscript = enabled
            Log.info("polish transcript: \(enabled)", "app")
            // Turning it on mid-session: page the model in now, not on the
            // first polished utterance. No-op when unavailable or already warm.
            if enabled { Task.detached(priority: .background) { await polisher.warmUp() } }
        }
        menuBar.onToggleCopyMode = { [weak self] enabled in
            self?.settings.copyInsteadOfPaste = enabled
            Log.info("copy instead of paste: \(enabled)", "app")
        }
        menuBar.onToggleReview = { [weak self] enabled in
            self?.settings.reviewBeforePaste = enabled
            Log.info("review before paste: \(enabled)", "app")
        }
        menuBar.onSelectReviewAutoInsert = { [weak self] code in
            self?.settings.reviewAutoInsert = code
            self?.reviewCoordinator.setTimeoutPolicy(.from(code: code))
            Log.info("review auto-insert: \(code)", "app")
        }
        menuBar.setLanguage(settings.language)
        menuBar.setAccuracyMode(settings.accuracyMode)
        menuBar.setPolishTranscript(settings.polishTranscript)
        menuBar.setCopyMode(settings.copyInsteadOfPaste)
        menuBar.setReview(settings.reviewBeforePaste)
        menuBar.setReviewAutoInsert(settings.reviewAutoInsert)
        reviewCoordinator.setTimeoutPolicy(.from(code: settings.reviewAutoInsert))

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
                // Page the polish model in ahead of the first utterance (a few
                // hundred MB, managed by the OS). Declines instantly when the
                // toggle is off or Apple Intelligence is unavailable.
                if settings.polishTranscript {
                    Task.detached(priority: .background) { [polisher] in await polisher.warmUp() }
                }
                // Pre-download AND pre-load Whisper in the background. Danish
                // (a daily language here) now quality-routes to Whisper, so its
                // model is no longer a rare fallback: without a pre-load the
                // first Danish utterance of the day pays the ~5 s Core ML load
                // mid-dictation. Costs ~1.5 GB residency; opt out of the load
                // (keeping the download) with LOCAL_DICTATION_PRELOAD_WHISPER=0
                // in the LaunchAgent plist. Low priority, best-effort: a
                // failure only logs — the lazy load inside warmUp() stays as
                // the fallback. GUI-only by construction (this is the menu-bar
                // launch path; the CLI never runs this code).
                Task.detached(priority: .background) { [whisper] in
                    do {
                        try await whisper.predownloadModel()
                        guard ProcessInfo.processInfo.environment["LOCAL_DICTATION_PRELOAD_WHISPER"] != "0" else { return }
                        try await whisper.warmUp()
                        Log.info("whisper pre-loaded and resident (set LOCAL_DICTATION_PRELOAD_WHISPER=0 to keep it lazy)", "whisper")
                    } catch {
                        Log.warn("whisper pre-load failed (will load lazily on first use): \(error)", "whisper")
                    }
                }
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
                // The ID was allocated but will never transcribe: advance the
                // paste sequence past it or later utterances would stall.
                pasteSequencer.complete(id: failedID, text: "")
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
        saveLastUtterance(samples)
        menuBar.update(.transcribing)
        transcribe(id: id, samples: samples)
    }

    /// Keep the most recent capture on disk (single file, overwritten every
    /// utterance, never leaves the machine) so a bad transcript can be replayed
    /// through both engines via `--transcribe-file` with the *real* audio —
    /// synthesized fixtures proved misleading for real-speech quality. Opt out
    /// with LOCAL_DICTATION_SAVE_AUDIO=0 in the LaunchAgent plist.
    private func saveLastUtterance(_ samples: [Float]) {
        guard ProcessInfo.processInfo.environment["LOCAL_DICTATION_SAVE_AUDIO"] != "0",
              !samples.isEmpty else { return }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local-dictation", isDirectory: true)
        let url = dir.appendingPathComponent("last-utterance.wav")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: AudioRecorder.targetSampleRate,
                                             channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(samples.count))
            else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
            }
            // Overwrite-in-place isn't supported by AVAudioFile; remove first.
            try? FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            Log.debug("last utterance saved to \(url.path)", "app")
        } catch {
            Log.warn("could not save last utterance: \(error)", "app")
        }
    }

    private func transcribe(id: UInt64, samples: [Float]) {
        // Snapshot settings at utterance end so a mid-transcription menu change
        // can't retroactively alter an utterance that was already spoken.
        let language = settings.language
        let accuracy = settings.accuracyMode || forceWhisper
        let polish = settings.polishTranscript
        // Review mode is only meaningful with polish on (one candidate is no
        // choice), and it switches polish to the terse rewrite — that is the
        // whole point of the second candidate.
        let review = settings.reviewBeforePaste && polish

        Task { @MainActor in
            do {
                // Warm the routed engine OUTSIDE the hang guard: a Whisper first
                // use can legitimately cold-load for minutes (download + Core ML
                // compile), and the menu already shows that via onColdLoad. Only
                // the actual per-utterance inference below gets the 120 s bound.
                _ = try await pipeline.prepareEngine(
                    language: language,
                    accuracyMode: accuracy,
                    onColdLoad: { [menuBar] kind in
                        // First routed use of a cold engine (in practice:
                        // Whisper via Accuracy Mode / a non-Parakeet pin).
                        // Reuses the existing .loading state — no 6th state.
                        menuBar.update(.loading(kind == .whisper
                            ? "Loading Whisper model (first use)…"
                            : "Loading Parakeet model…"))
                    }
                )
                // If a cold load repainted the menu to .loading, restore the
                // correct state (listening/transcribing) now that the engine is warm.
                refreshMenuState()
                let outcome = try await AsyncTimeout.run(seconds: Self.transcriptionTimeout) { [pipeline] in
                    // process re-warms internally, but after prepareEngine that
                    // is an idempotent no-op — kept as a safety net only.
                    try await pipeline.process(
                        samples: samples,
                        language: language,
                        accuracyMode: accuracy,
                        polish: polish,
                        polishStyle: review ? .terse : .standard
                    )
                }
                utterance.settled(id)
                Log.info("utterance \(id): engine=\(outcome.engine?.rawValue ?? "none") gate=\(outcome.gate) filtered=\(outcome.filtered) rescued=\(outcome.rescue?.rawValue ?? "no") polished=\(outcome.polished) inference=\(String(format: "%.2f", outcome.inferenceSeconds))s, \(outcome.text.count) chars: \(outcome.text.prefix(120))", "app")
                // Never paste directly: the sequencer restores spoken order for
                // overlapping utterances (an empty text still advances the queue).
                // With review on, a genuinely-rewritten outcome detours through
                // the overlay first — which still settles the same sequencer ID
                // on every path (click / dismiss / timeout), just later.
                if review, ReviewQueueLogic.needsReview(asrText: outcome.asrText,
                                                        text: outcome.text,
                                                        polished: outcome.polished) {
                    reviewCoordinator.enqueue(id: id, raw: outcome.asrText, polished: outcome.text)
                } else {
                    pasteSequencer.complete(id: id, text: outcome.text)
                }
                refreshMenuState()
            } catch {
                utterance.settled(id)
                // Errored utterances paste nothing but must advance the sequence.
                pasteSequencer.complete(id: id, text: "")
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
    /// timeout — a normal end/begin cycle in between makes it a no-op. A key
    /// that is genuinely still held re-arms instead of truncating the dictation.
    private func scheduleLostReleaseWatchdog(id: UInt64) {
        lostReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lostReleaseTimeout, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            switch LostReleaseWatchdog.decide(isRecording: self.utterance.isRecording,
                                              recordingID: self.utterance.recordingID,
                                              firedID: id,
                                              keyStillDown: self.hotkeyStillDown) {
            case .ignore:
                return
            case .rearm:
                Log.info("lost-release watchdog: Right Option still physically held (id=\(id)) — re-arming", "app")
                self.scheduleLostReleaseWatchdog(id: id)
            case .endRecording:
                Log.warn("lost-release watchdog fired (id=\(id)) — key is up, forcing endRecording", "app")
                self.endRecording()
            }
        }
        // .common so it fires even while the status-item menu is open.
        RunLoop.main.add(timer, forMode: .common)
        lostReleaseTimer = timer
    }

}
