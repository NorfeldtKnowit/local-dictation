import Foundation

/// Headless `--transcribe-file` command-line interface. Two pieces, split so the
/// argument grammar is unit-testable without any AppKit / model dependency:
///
///  - `CLIArguments` — a *pure* parser over `CommandLine.arguments`. It never
///    touches the filesystem, models, or AppKit; it only decides "GUI launch vs.
///    headless run vs. usage error" and validates flag values.
///  - `CLIRunner`    — the async executor that actually loads audio and drives
///    the same `DictationPipeline` the GUI uses (the single reuse point), then
///    maps the outcome to a shell exit code.
///
/// Nothing in this file constructs `AudioRecorder`, `HotkeyMonitor`, `MenuBar`,
/// or references `NSApp`: the CLI path requests no TCC permissions and shows no
/// menu-bar item, so it's safe to run from CI / scripts.

/// Parsed, validated command-line options for a headless transcription run.
struct CLIArguments: Equatable {
    /// Path to the audio file to transcribe (`--transcribe-file`, required).
    var file: String
    /// `--engine` override. `nil` == "auto" == let `EngineRouter` decide; a
    /// concrete kind forces that engine and bypasses the router.
    var forcedEngine: EngineKind?
    /// `--language`: "auto" (no pin) or an ISO code. Drives routing + the hint.
    var language: String
    /// `--accuracy`: force Whisper for every language.
    var accuracy: Bool
    /// True by default; `--no-vad-gate` sets it false to bypass gate layers 1+2
    /// (raw-ASR regression testing).
    var vadGate: Bool
    /// True by default; `--no-hallucination-filter` sets it false to bypass the
    /// post-ASR blocklist/repetition guard (layer 3).
    var hallucinationFilter: Bool
    /// `--json`: emit a machine-readable object on stdout instead of plain text.
    var json: Bool

    /// A malformed invocation (unknown flag, missing value, absent required file).
    /// The entry point prints `message` to stderr and exits 1 — unless
    /// `isHelpRequest`, where `message` is the usage text (stdout, exit 0).
    struct ParseError: Error, Equatable {
        let message: String
        var isHelpRequest = false
    }

    static let usage = """
        usage: local-dictation --transcribe-file <path>
                               [--engine auto|parakeet|whisper]
                               [--language <iso>|auto]
                               [--accuracy]
                               [--no-vad-gate]
                               [--no-hallucination-filter]
                               [--json]
        Without --transcribe-file the menu-bar GUI launches (any other
        arguments, e.g. macOS-injected -psn_… tokens, are ignored).
        """

    /// Parse the full process argv (including argv[0], the program path).
    /// - Returns: `nil` for a GUI launch; `.success` for a valid headless run;
    ///   `.failure` for a usage error (or `--help`, flagged as such).
    ///
    /// GUI vs CLI: only `--transcribe-file` (or `--help`) opts into strict CLI
    /// parsing. macOS can inject argv tokens into a normal app launch (legacy
    /// `-psn_…` process serial numbers, `-NSSomething` UserDefaults arguments),
    /// so unknown stray arguments WITHOUT `--transcribe-file` must fall through
    /// to the GUI instead of exiting the whole app; the entry point logs them.
    static func parse(_ argv: [String]) -> Result<CLIArguments, ParseError>? {
        let args = Array(argv.dropFirst())          // drop the program path
        guard args.contains("--transcribe-file") || args.contains("--help") else {
            return nil                              // GUI launch (stray args ignored)
        }

        var file: String?
        var forcedEngine: EngineKind?
        var language = "auto"
        var accuracy = false
        var vadGate = true
        var hallucinationFilter = true
        var json = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--transcribe-file":
                guard i + 1 < args.count else {
                    return .failure(.init(message: "--transcribe-file requires a path"))
                }
                file = args[i + 1]; i += 2
            case "--engine":
                guard i + 1 < args.count else {
                    return .failure(.init(message: "--engine requires a value (auto|parakeet|whisper)"))
                }
                switch args[i + 1] {
                case "auto":     forcedEngine = nil
                case "parakeet": forcedEngine = .parakeet
                case "whisper":  forcedEngine = .whisper
                default: return .failure(.init(message: "--engine must be auto|parakeet|whisper"))
                }
                i += 2
            case "--language":
                guard i + 1 < args.count else {
                    return .failure(.init(message: "--language requires a value (ISO code or auto)"))
                }
                language = args[i + 1]; i += 2
            case "--help":
                return .failure(.init(message: Self.usage, isHelpRequest: true))
            case "--accuracy":                accuracy = true; i += 1
            case "--no-vad-gate":             vadGate = false; i += 1
            case "--no-hallucination-filter": hallucinationFilter = false; i += 1
            case "--json":                    json = true; i += 1
            default:
                return .failure(.init(message: "unknown argument: \(arg)"))
            }
        }

        guard let file else {
            return .failure(.init(message: "--transcribe-file <path> is required"))
        }
        return .success(CLIArguments(
            file: file,
            forcedEngine: forcedEngine,
            language: language,
            accuracy: accuracy,
            vadGate: vadGate,
            hallucinationFilter: hallucinationFilter,
            json: json
        ))
    }
}

/// Executes a parsed CLI run and returns the process exit code.
enum CLIRunner {
    /// Exit codes (CI asserts on these):
    ///   0  transcript emitted
    ///   1  unreadable file (bad-arguments is handled in `CLIArguments.parse`)
    ///   2  model load / transcription error
    ///   3  utterance dropped by the gate (tooShort/silence) or hallucination filter
    static func run(_ args: CLIArguments) async -> Int32 {
        // 1. Load audio as the pipeline's expected 16 kHz mono Float32 buffer.
        let samples: [Float]
        do {
            samples = try WavLoader.load(url: URL(fileURLWithPath: args.file))
        } catch {
            stderr("error: \(error)")
            return 1
        }

        // 2. Build the same engines + gate + pipeline the GUI uses.
        let pipeline = DictationPipeline(
            parakeet: ParakeetEngine(),
            whisper: Transcriber(),
            gate: SpeechGate()
        )
        // Warm the launch defaults (VAD + Parakeet). Models are cached locally so
        // this is fast; a failure to load Parakeet surfaces as a model error.
        do {
            try await pipeline.warmUpDefaults()
        } catch {
            stderr("error: warm-up failed: \(error)")
            return 2
        }

        // 3. Run the one utterance through the pipeline (bypass flags honoured).
        let outcome: DictationPipeline.Outcome
        do {
            outcome = try await pipeline.process(
                samples: samples,
                language: args.language,
                accuracyMode: args.accuracy,
                forcedEngine: args.forcedEngine,
                bypassGate: !args.vadGate,
                bypassFilter: !args.hallucinationFilter
            )
        } catch {
            stderr("error: transcription failed: \(error)")
            return 2
        }

        // 4. Map the outcome to an exit code + output.
        let exitCode: Int32
        var dropReason: String?
        switch outcome.gate {
        case .tooShort: dropReason = "tooShort"; exitCode = 3
        case .silence:  dropReason = "silence";  exitCode = 3
        case .pass, .vadUnavailable:
            if outcome.filtered { dropReason = "hallucination"; exitCode = 3 }
            else { exitCode = 0 }
        }

        // stdout carries only the machine-readable result: JSON when asked (always,
        // even for a drop, so CI can inspect it), otherwise the plain transcript on
        // success. Diagnostics go to stderr so stdout stays clean/pipeable.
        if args.json {
            print(jsonLine(outcome, language: args.language))
        } else if exitCode == 0 {
            print(outcome.text)
        }
        if let dropReason {
            stderr("dropped: \(dropReason)")
        }
        stderr("cli done: engine=\(outcome.engine.rawValue) gate=\(gateName(outcome.gate)) "
             + "filtered=\(outcome.filtered) latencyMs=\(Int(outcome.inferenceSeconds * 1000)) exit=\(exitCode)")
        return exitCode
    }

    // MARK: - Output helpers

    /// `{"text","engine","language","gate","filtered","latencyMs"}` — one line.
    private static func jsonLine(_ outcome: DictationPipeline.Outcome, language: String) -> String {
        struct Payload: Encodable {
            let text: String
            let engine: String
            let language: String
            let gate: String
            let filtered: Bool
            let latencyMs: Int
        }
        let payload = Payload(
            text: outcome.text,
            engine: outcome.engine.rawValue,
            language: language,
            gate: gateName(outcome.gate),
            filtered: outcome.filtered,
            latencyMs: Int(outcome.inferenceSeconds * 1000)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// `GateDecision` has no rawValue; map it to the stable string CI greps for.
    private static func gateName(_ decision: GateDecision) -> String {
        switch decision {
        case .pass:           return "pass"
        case .tooShort:       return "tooShort"
        case .silence:        return "silence"
        case .vadUnavailable: return "vadUnavailable"
        }
    }

    private static func stderr(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
