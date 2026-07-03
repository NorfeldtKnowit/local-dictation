# CLAUDE.md

Guidance for working on local-dictation. Read this before touching audio
capture, the global hotkey, or anything permission related: each of those has
a non-obvious macOS gotcha that cost real debugging time, documented below.

## What this is

A menu-bar push-to-talk dictation app. Hold **Right Option** (or left-click the
menu-bar icon), speak, release; the audio is gated for speech, routed to one of
two local engines (FluidAudio Parakeet by default, WhisperKit for languages
Parakeet doesn't cover or when Accuracy Mode is on), and pasted into the
focused app via synthetic Cmd+V. Also runnable headless via
`--transcribe-file` for CI/scripts. Runs as a per-user LaunchAgent. See
`README.md` for the user-facing overview, stack, and routing table.

Source layout (`Sources/LocalDictation/`), roughly capture → gate → route →
transcribe → inject:

- `App.swift` — `@main` (async; branches to CLI or GUI), `AppDelegate`, wires
  permissions, hotkey, recorder, pipeline, watchdogs.
- `HotkeyMonitor.swift` — `CGEvent` tap watching Right Option (keycode 61);
  `isDown` bookkeeping delegates to `HotkeyStateMachine`.
- `HotkeyStateMachine.swift` — pure press/release/tap-disabled state machine.
- `AudioRecorder.swift` — mic capture via **AVCaptureSession**, byte-for-byte
  frozen (see gotcha below).
- `SpeechGate.swift` / `SpeechGateLogic.swift` — pre-ASR VAD guard: actor
  wrapper (degrades gracefully if Silero is unavailable) + pure decision/trim
  logic.
- `EngineRouter.swift` — pure language/Accuracy-Mode → engine decision.
- `TranscriptionEngine.swift` — shared protocol + `EngineKind`.
- `ParakeetEngine.swift` — FluidAudio Parakeet TDT v3 (low-latency default).
- `Transcriber.swift` — WhisperKit wrapper, conforms to `TranscriptionEngine`.
- `HallucinationFilter.swift` — pure post-ASR blocklist + repetition guard.
- `DictationPipeline.swift` — actor tying gate → route → transcribe → filter
  together; the single reuse point for both GUI and CLI.
- `LanguageSetting.swift` — `UserDefaults`-backed language pin + accuracy mode.
- `UtteranceStateMachine.swift` — pure recording/transcription bookkeeping
  with monotonic IDs.
- `WavLoader.swift` — CLI-only `AVAudioFile` → 16 kHz mono Float32 loader.
- `CLI.swift` — `CLIArguments` parser + `CLIRunner` for `--transcribe-file`.
- `TextInjector.swift` — pasteboard + synthetic Cmd+V.
- `MenuBar.swift` — status item, click handling, state icons, spinner,
  Language ▸ submenu, Accuracy Mode checkbox.
- `Permissions.swift` — TCC requests / settings deep-links.
- `Log.swift` — tee logger to stderr + `~/Library/Logs/local-dictation.log`.

## Build and deploy

The running daemon executes the **app bundle** at
`~/Applications/local-dictation.app`, not the raw SPM binary. The full cycle:

```bash
swift build -c release
scripts/build-app.sh        # assemble + sign dist/local-dictation.app
scripts/install-app.sh      # copy + sign into ~/Applications
launchctl kickstart -k "gui/$(id -u)/com.norfeldt.local-dictation"
```

`scripts/install-daemon.sh` (re)installs the LaunchAgent plist. Its
`bootstrap` step fails with `5: Input/output error` if the agent is still
registered; if so, just `kickstart -k` the existing label, or `bootout` then
`bootstrap`.

The Whisper model cold-loads in roughly 3-4 minutes on first launch after a
restart, then warm-loads in under 10 seconds. Wait for `model ready` in the log
before testing; `beginRecording` is a no-op until then.

## Permissions and code signing (the big one)

Three separate TCC categories are involved, and they are easy to confuse:

- **Microphone** — to capture audio. Prompted via `AVCaptureDevice`.
- **Input Monitoring** (`ListenEvent`) — for the `CGEvent` tap to actually
  receive keyboard events. Without it `CGEvent.tapCreate` still **succeeds**
  (returns non-nil, `hotkey tap started=true`), but **zero events are
  delivered**. Silent failure. If Right Option produces no `flagsChanged`
  log lines, this is why.
- **Accessibility** — for synthetic Cmd+V paste. Without it transcription
  works but the paste is silently dropped (`ax-trusted=false` in the log).

### Sign with a stable identity, never ad-hoc

TCC keys grants on the code-signing identity. **Ad-hoc signing (`codesign -s -`)
produces a new cdhash on every build**, so macOS treats each rebuild as a brand
new app and silently drops every grant. Symptom: it worked, you rebuilt, now
nothing works and re-toggling Settings doesn't help.

Fix already in place: `build-app.sh` / `install-app.sh` / `sign.sh` sign with a
real **Apple Development** certificate (default
`LOCAL_DICTATION_SIGN_ID=5FA4A452E6583B1C54CA2F9C0CD563CAA77DAA0E`,
team `9397MGXMJF`). With a stable cert the grants survive rebuilds. Do **not**
revert these to `-`. Override the identity via the `LOCAL_DICTATION_SIGN_ID`
env var if signing on another machine.

### Other permission traps

- **Relocating the binary loses grants.** Grants are tied to the signed
  identity/path; moving from `.build/release` to the `.app` bundle, or changing
  the signing identity, requires re-granting (or a `tccutil reset`, below).
- **Duplicate TCC rows confuse macOS.** If both `local-dictation` and
  `local-dictation.app` appear in a Settings list (or an old path lingers), the
  grant may read as enabled but not take effect. Reset and re-grant once:

  ```bash
  tccutil reset Accessibility com.norfeldt.local-dictation
  tccutil reset ListenEvent   com.norfeldt.local-dictation
  tccutil reset Microphone    com.norfeldt.local-dictation
  ```

  `reset` reporting success twice is the tell that there were duplicate rows.
  After reset, restart the daemon so it re-registers and re-prompts.
- **A freshly granted permission needs a process restart.** The `CGEvent` tap is
  created at launch; granting Input Monitoring afterward does not retroactively
  feed the existing tap. `kickstart -k` after granting.
- Deep-link to the panes:
  `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"`
  (and `?Privacy_Accessibility`).

## Audio capture: use AVCaptureSession, not AVAudioEngine

`AudioRecorder` deliberately uses **AVCaptureSession**. `AVAudioEngine`'s input
node was unusable on the dev machine (LaunchAgent context, Bluetooth HFP +
virtual audio devices present): it reported a **phantom 44100 Hz** input format
bound to no real device, delivered **zero tap callbacks**, and held the mic open
without releasing it. No real device on the system ran at 44100, which is the
tell. AVCaptureSession binds to `AVCaptureDevice.default(for: .audio)` reliably,
reports the real format (e.g. 48000), and releases the device cleanly.

If you ever touch this: `stop()` must do a full teardown (stopRunning, remove
inputs and outputs, clear the sample-buffer delegate, drop the session) so the
device is released promptly.

## Hotkey tap robustness

macOS disables a long-lived `.listenOnly` head-insert tap periodically
(`tapDisabledByUserInput` = `0xFFFFFFFF`). `HotkeyMonitor` handles this by
re-enabling, recreating the tap (debounced) after a disable, and synthesizing a
release if a disable arrives mid-press so recording can't get stuck on. Keep
those safeguards if refactoring.

## Dual-engine routing (Parakeet + Whisper)

`DictationPipeline` gates the raw buffer, routes it to one engine, transcribes,
then filters — this is the single reuse point for both the GUI and the CLI
(`CLI.swift`). Routing is a pure function (`EngineRouter.route`):

| language setting | accuracyMode | engine | hint passed |
|---|:---:|---|---|
| `auto` | off | Parakeet | `nil` (model self-detects among its 28) |
| code in Parakeet's 28 (da, en, sv, …) | off | Parakeet | `Language(rawValue:)` script filter |
| code not in Parakeet's 28 (ja, zh, ar, ko, **no**, …) | off | Whisper | `DecodingOptions.language`, `detectLanguage: false` |
| any | on | Whisper | code or nil+detect |

There is deliberately no silent cross-engine fallback: a warm-up/transcribe
failure on the routed engine surfaces as an error, never a different engine's
output passed off as the requested one. The one sanctioned exception is a
Parakeet launch failure, which flips a `forceWhisper` override (equivalent to
Accuracy Mode) — Whisper is a safe universal superset, so that direction is
always correct.

### FluidAudio's `Language` enum has no Norwegian

`Language.allCases` (imported from FluidAudio) is exactly 28 cases across
Latin/Cyrillic/Greek scripts, and **does not contain Norwegian** (`no`/`nb`).
For a Nordic user this is a routing landmine: Norwegian must always be pinned
to Whisper (or routed there via Accuracy Mode), never assumed to work in Auto.
The menu's Language ▸ submenu lists it explicitly under "Other (Whisper)"
alongside Japanese/Chinese/Korean/Arabic. Also note: the FluidAudio module
exports a `public struct FluidAudio` that shadows the module name, so
`FluidAudio.Language.init(rawValue:)` fails to resolve ("type FluidAudio has
no member Language") — use the bare `Language` name after `import FluidAudio`.

### VAD threshold: 0.70, not the library default 0.85

`VadConfig.defaultThreshold` defaults to **0.85** in FluidAudio (verified in
`VadTypes.swift`), which under-triggers on quiet Danish speech — utterances
get silently gated as silence. `SpeechGate` overrides it to **0.70**. A false
accept at 0.70 is cheap to absorb (one extra Parakeet call, ~ms-scale, ANE) and
is still caught by the post-ASR hallucination filter; a false reject at 0.85
means the utterance is dropped before ever reaching an engine, with no
recovery. Lower, not higher, is the safe direction to bias this knob.

### WhisperKit `DecodingOptions` argument order

`DecodingOptions`'s memberwise init declares its parameters in this order
(`Configurations.swift`): `…, compressionRatioThreshold, logProbThreshold,
firstTokenLogProbThreshold, noSpeechThreshold, concurrentWorkerCount,
chunkingStrategy`. Swift requires labeled arguments in **declaration order**,
not call-site order — a decode call that lists `noSpeechThreshold:` before
`logProbThreshold:`/`compressionRatioThreshold:` (a very natural way to group
"the anti-hallucination levers") **will not compile**. Also worth knowing: the
canonical anti-hallucination values (`noSpeechThreshold: 0.6, logProbThreshold:
-1.0, compressionRatioThreshold: 2.4`) are already the library's **defaults**;
they don't need restating unless you intend to change them. The levers this
app actually sets are `language:`, `detectLanguage:`, and `chunkingStrategy:
.vad`. If you touch `Transcriber.transcribe`, verify argument order against
the checked-out source before compiling, not from memory or from an older
snippet.

## Testing

- **Executable targets are unit-testable directly** — SPM has supported test
  targets depending on executable targets since **Swift 5.5**; `@testable
  import LocalDictation` from `Tests/LocalDictationTests` works with no
  library-target split. Don't reintroduce one "to make testing possible"; it
  isn't needed and it would move every TCC-sensitive file.
- `swift test` runs the pure-logic suite (state machines, router, gate logic,
  hallucination filter, pipeline via fakes, CLI argument parsing) — no models,
  no mic, seconds to run, safe for default CI.
- `scripts/test-cli.sh` is the model-touching e2e layer: it drives the real
  release binary's `--transcribe-file` mode against `scripts/make-fixtures.sh`
  fixtures (Danish → Parakeet, English forced through `--engine whisper`,
  digital silence → exit 3) and needs Parakeet v3 + Whisper large-v3 already
  cached locally. Treat it as manual/nightly, not part of `swift test`.
- CLI mode (`--transcribe-file <path> [--engine …] [--language …] [--accuracy]
  [--no-vad-gate] [--no-hallucination-filter] [--json]`) constructs no
  `AudioRecorder`/`HotkeyMonitor`/`MenuBar`/`NSApp` — it requests zero TCC
  permissions, so it's safe to run from CI or scripts on a machine that has
  never granted this app anything. Exit codes: `0` transcript emitted, `1` bad
  args/unreadable file, `2` model/transcription error, `3` dropped by the gate
  or hallucination filter (reason on stderr).

## Debugging playbook

- **Log:** `~/Library/Logs/local-dictation.log` (and `.out.log` / `.err.log`).
- **Verbose keycodes:** set `LOCAL_DICTATION_VERBOSE=1` to log every
  `flagsChanged keyCode=…`. Add it as an `EnvironmentVariables` entry in the
  LaunchAgent plist temporarily; **remove it when done** (it logs every
  keystroke modifier).
- **Right Option does nothing:** check for `flagsChanged keyCode=61` lines. None
  at all means the tap is deaf (Input Monitoring). Present but no
  `beginRecording` means a state bug.
- **Records but 0 audio:** check `stop: captured N samples (sample buffers=…)`.
  `sample buffers=0` means the device delivered nothing.
- **"Mic in use" orange dot stuck on:** it is almost never this app. The macOS
  **System Settings > Sound** pane runs a live input meter and holds the mic
  while open. Confirm who actually holds input with CoreAudio's
  `kAudioProcessPropertyIsRunningInput` over the process list (a ~30-line Swift
  probe) before suspecting our capture code.
