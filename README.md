# local-dictation

Universal push-to-talk dictation for macOS. Hold **Right Option** (or
left-click the menu-bar icon), speak, release. The transcript is pasted into
whatever app has focus. Everything runs locally on-device, no cloud calls.

Right-click (or two-finger / Control-click) the menu-bar icon for the menu.

Inspired by Warp's `fn`-key voice input, but built around a local
Whisper model so it works in any app and never sends audio off the machine.

## Stack

- Swift 5.10, macOS 14+ (Apple Silicon strongly recommended)
- AVCaptureSession for capture, online-converted to 16 kHz mono Float32
  (see `CLAUDE.md` for why not AVAudioEngine)
- `CGEventTap` watching `flagsChanged` for the Right Option key
- Dual transcription engines, routed automatically (see below):
  - FluidAudio Parakeet TDT v3: low-latency default, ANE-resident
  - WhisperKit (Argmax OSS SDK) `openai_whisper-large-v3-v20240930`
    (full precision, ~1.5 GB, pre-downloaded in the background at launch):
    accuracy / fallback engine, used for languages outside Parakeet's set
    or when Accuracy Mode is on
- FluidAudio Silero VAD: pre-ASR speech gate, trims silence and drops
  no-speech taps before any model runs
- `NSPasteboard` + synthetic Cmd+V for text injection
- LaunchAgent for always-on daemon behavior

## Dual-engine routing

Every utterance is gated (silence/too-short dropped, speech trimmed) and then
routed to one of the two engines:

| Language setting            | Accuracy Mode | Engine   | Notes                                  |
|------------------------------|:---:|----------|-----------------------------------------|
| Auto                          | off | Parakeet | model self-detects among its 28 codes  |
| Pinned, in Parakeet's 28      | off | Parakeet | e.g. `da`, `en`, `sv`, `de`             |
| Pinned, outside Parakeet's 28 | off | Whisper  | e.g. `no`, `ja`, `zh`, `ko`, `ar`       |
| Any                            | on  | Whisper  | forces Whisper for every language      |

When Parakeet reports low confidence in its own transcript (below 0.80, the
telltale of it decoding e.g. Danish speech as English gibberish), the
utterance is automatically re-run through Whisper with the pinned language
forced, and Whisper's text is pasted instead. The first rescue after launch
pays Whisper's load time (about 5-8 seconds, shown in the menu bar); later
rescues cost only its inference. Every capture is also saved to
`~/Library/Caches/local-dictation/last-utterance.wav` (one file, overwritten,
never leaves the machine) so a bad transcript can be replayed through both
engines with the real audio; set `LOCAL_DICTATION_SAVE_AUDIO=0` to disable.

Parakeet's `Language` enum has **no Norwegian** (`no`/`nb`), a Nordic-user
landmine worth knowing about. Norwegian dictation always routes to Whisper,
whether pinned explicitly or (since it's outside the 28) picked up on Auto
only if it happens to resemble a supported script; pin it or use Accuracy
Mode for reliable Norwegian output. The menu's Language ▸ submenu lists the
28 Parakeet codes plus an explicit "Other (Whisper)" section for Norwegian,
Japanese, Chinese, Korean, and Arabic.

There is no silent cross-engine fallback: if the routed engine fails to warm
up or transcribe, you get an error, never a different engine's output
pretending to be the one you asked for. The one exception is a Parakeet
launch failure, which flips a `forceWhisper` override (equivalent to Accuracy
Mode) since Whisper is a safe universal superset.

## Quick start

```bash
git clone <this repo> ~/repos/local-dictation
cd ~/repos/local-dictation
swift build -c release        # ~50 s first time, fetches WhisperKit
scripts/build-app.sh          # assemble + sign dist/local-dictation.app
scripts/install-app.sh        # copy + sign into ~/Applications
scripts/install-daemon.sh     # install LaunchAgent, start it
```

The daemon runs the **app bundle** in `~/Applications`, not the raw SPM
binary, so `build-app.sh` + `install-app.sh` are the steps that matter.

The first launch will:

1. Ask for **Microphone** permission — click Allow.
2. Ask for **Accessibility** permission — grant it in System Settings.
   You may also need to add it under **Input Monitoring**.
3. Show "Loading Whisper model…" in the menu bar while it downloads
   the ~600 MB Core ML model to `~/Documents/huggingface/...`. (~1 minute.)
4. Switch to the gray mic icon (ready).

Then hold **Right Option** and talk. The icon turns **Naples yellow**
while listening, switches to a waveform during transcription, then the
text pastes into the focused app.

## Why stable code signing matters

macOS keys its TCC grants (Accessibility, Input Monitoring, Microphone) off the
binary's code-signing identity. **Ad-hoc signing (`codesign -s -`) produces a
new cdhash on every build**, so macOS treats each rebuild as a brand new app and
silently drops every grant. Symptom: it worked, you rebuilt, now nothing works,
and re-toggling the switch in System Settings does not fix it.

The build scripts therefore sign with a **stable Apple Development
certificate**, not ad-hoc. With a real cert the grants survive rebuilds, so you
grant the three permissions once. Override the identity for another machine via
the `LOCAL_DICTATION_SIGN_ID` env var (default is the maintainer's cert; set it
to `-` to fall back to ad-hoc, accepting the re-grant-every-build pain):

```bash
LOCAL_DICTATION_SIGN_ID="<cert-sha1-or-name>" scripts/build-app.sh
LOCAL_DICTATION_SIGN_ID="<cert-sha1-or-name>" scripts/install-app.sh
```

If duplicate rows appear in a Settings list (e.g. both `local-dictation` and
`local-dictation.app`), the grant can read as enabled but not take effect. Reset
and re-grant once, then restart the daemon:

```bash
tccutil reset Accessibility com.norfeldt.local-dictation
tccutil reset ListenEvent   com.norfeldt.local-dictation
tccutil reset Microphone    com.norfeldt.local-dictation
```

If you see `ERROR [inject] Accessibility NOT trusted at paste time` in the log,
Accessibility is not granted for the currently running bundle. Granting a
permission needs a process restart (`kickstart -k`) to take effect.

See `CLAUDE.md` for the full permissions playbook.

## Menu bar states

| Icon                    | State                                        |
|-------------------------|----------------------------------------------|
| ⬇  arrow.down.circle    | Loading model on first launch                |
| 🎙 mic (gray)            | Idle — ready, hold Right Option to dictate   |
| 🎙 mic.fill (yellow)     | Listening — Naples yellow #FADA5E            |
| ◌ spinner (yellow)      | Transcribing — rotating Naples-yellow symbol |
| ⚠ exclamationmark       | Error — open the menu for context            |

## CLI mode (headless transcription)

Running the binary with `--transcribe-file` skips the GUI entirely: no
`NSApplication`, no menu-bar item, no Microphone/Accessibility/Input
Monitoring prompts. It transcribes one audio file through the exact same
`DictationPipeline` the GUI uses (gate → route → transcribe → filter) and
exits with a status code, which makes it safe to call from CI or scripts.

```bash
local-dictation --transcribe-file <path>
                [--engine auto|parakeet|whisper]   # default auto = real router
                [--language <iso>|auto]            # default auto
                [--accuracy]                       # force Whisper, all languages
                [--no-vad-gate]                     # bypass the silence/speech gate
                [--no-hallucination-filter]         # bypass the post-ASR blocklist
                [--json]                            # machine-readable stdout
```

Exit codes:

| Code | Meaning                                                  |
|-----:|-----------------------------------------------------------|
| 0    | transcript emitted (on stdout)                            |
| 1    | bad arguments or unreadable file                          |
| 2    | model load / transcription error                          |
| 3    | dropped by the gate (`tooShort`/`silence`) or the hallucination filter (reason on stderr) |

`--json` emits `{"text","engine","language","gate","filtered","latencyMs"}` on
stdout (the `engine` key is omitted when the utterance was dropped before any
engine ran); without it, stdout carries only the plain transcript on success
(or nothing on a drop) so it stays pipeable, and a one-line summary always
goes to stderr. `scripts/make-fixtures.sh` generates local `say`-synthesized
Danish/English fixtures plus a digital-silence WAV; `scripts/test-cli.sh`
exercises all three exit paths (Parakeet, forced Whisper, gated silence)
against the release binary; see that script for the exact invocations.

## Choosing a different model

Set the `LOCAL_DICTATION_MODEL` environment variable to any model name
hosted at
[argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).

```bash
LOCAL_DICTATION_MODEL=tiny ./.build/release/local-dictation     # ~40 MB, fast, English-leaning
LOCAL_DICTATION_MODEL=base.en ./.build/release/local-dictation  # ~145 MB, English only
# default:
LOCAL_DICTATION_MODEL=large-v3-v20240930_626MB ./...            # ~600 MB, best multilingual
```

To pass env vars through the LaunchAgent, edit
`~/Library/LaunchAgents/com.norfeldt.local-dictation.plist` and add an
`EnvironmentVariables` dict, then `launchctl kickstart -k` it.

## Logs

- Structured app log: `~/Library/Logs/local-dictation.log`
- LaunchAgent stdout / stderr:
  `~/Library/Logs/local-dictation.out.log` and `.err.log`
- Apple unified logging:

  ```bash
  log stream --predicate 'subsystem == "com.norfeldt.local-dictation"' --info
  ```

Set `LOCAL_DICTATION_VERBOSE=1` to log every `flagsChanged` event
(noisy — only useful if you suspect the Right Option key isn't
producing keyCode 61 on your layout).

## Daemon control

```bash
# Start / stop without uninstalling:
launchctl kickstart -k gui/$(id -u)/com.norfeldt.local-dictation
launchctl kill SIGTERM gui/$(id -u)/com.norfeldt.local-dictation

# Status:
launchctl print gui/$(id -u)/com.norfeldt.local-dictation | head -30

# Remove entirely:
scripts/uninstall-daemon.sh
```

## Upgrade workflow

```bash
git pull
swift build -c release
scripts/build-app.sh
scripts/install-app.sh
launchctl kickstart -k gui/$(id -u)/com.norfeldt.local-dictation
```

## Testing

```bash
swift test                    # pure-logic unit tests, no models, seconds
scripts/make-fixtures.sh      # generate Tests/fixtures/ (say-synthesized audio)
swift build -c release
scripts/test-cli.sh           # e2e: real Parakeet + Whisper models, gated silence
```

`swift test` runs against the executable target directly
(`@testable import LocalDictation`): SPM has supported test targets
depending on executable targets since Swift 5.5, so there is no separate
library target to keep in sync. `scripts/test-cli.sh` is not part of that
suite: it shells out to the release binary and needs the Parakeet v3 +
Whisper large-v3 models already downloaded, so treat it as a manual/nightly
check rather than default CI.

## Known sharp edges

- **Right Option doubles as AltGr** on some non-US layouts. If you
  compose `@` or accented characters with Right Option, this app will
  eat the press. Swap `kVKRightOption = 61` in
  `HotkeyMonitor.swift` to Right Control (62) and rebuild.
- **Cmd+V is refused in password fields** by some apps. The transcript
  stays on the clipboard for ~200 ms so you can paste manually.
- **Don't queue presses against a downloading model.** The first launch
  blocks the hotkey until "ready" — wait for the gray mic icon before
  the first press.

## File map

| File | Purpose |
|------|---------|
| `Sources/LocalDictation/App.swift` | `@main` entry point (async, branches to CLI or GUI), app delegate, watchdogs |
| `Sources/LocalDictation/MenuBar.swift` | `NSStatusItem` with five states, Language ▸ submenu, Accuracy Mode |
| `Sources/LocalDictation/HotkeyMonitor.swift` | `CGEventTap` watching Right Option; `isDown` delegates to `HotkeyStateMachine` |
| `Sources/LocalDictation/HotkeyStateMachine.swift` | Pure press/release/tap-disabled state machine (unit tested) |
| `Sources/LocalDictation/AudioRecorder.swift` | AVCaptureSession → 16 kHz mono Float32 (frozen since the Float32 output pin `1ee728e`; do not modify) |
| `Sources/LocalDictation/Transcriber.swift` | WhisperKit wrapper; conforms to `TranscriptionEngine` |
| `Sources/LocalDictation/ParakeetEngine.swift` | FluidAudio Parakeet TDT v3 engine (low-latency default) |
| `Sources/LocalDictation/TranscriptionEngine.swift` | `EngineKind` + the shared engine protocol |
| `Sources/LocalDictation/EngineRouter.swift` | Pure language/Accuracy-Mode → engine routing decision |
| `Sources/LocalDictation/LanguageSetting.swift` | `UserDefaults`-backed language pin + Accuracy Mode toggle |
| `Sources/LocalDictation/SpeechGate.swift` | Actor over FluidAudio's Silero VAD; degrades gracefully if unavailable |
| `Sources/LocalDictation/SpeechGateLogic.swift` | Pure gate decision + speech-region trimming (unit tested, no models) |
| `Sources/LocalDictation/HallucinationFilter.swift` | Pure post-ASR blocklist + repetition-loop guard |
| `Sources/LocalDictation/DictationPipeline.swift` | Actor: gate → route → transcribe → filter (single reuse point, GUI + CLI) |
| `Sources/LocalDictation/UtteranceStateMachine.swift` | Pure recording/transcription bookkeeping with monotonic IDs |
| `Sources/LocalDictation/PasteSequencer.swift` | Pure paste ordering: strict utterance-ID order, >= 300 ms between pastes |
| `Sources/LocalDictation/LostReleaseWatchdog.swift` | Pure watchdog decision: re-arm on genuine hold vs end on lost release |
| `Sources/LocalDictation/WavLoader.swift` | `AVAudioFile` → 16 kHz mono Float32 for CLI fixtures (CLI-only; recorder untouched) |
| `Sources/LocalDictation/CLI.swift` | `CLIArguments` parser + `CLIRunner` for `--transcribe-file` |
| `Sources/LocalDictation/TextInjector.swift` | `NSPasteboard` + Cmd+V injection, AX-trust check |
| `Sources/LocalDictation/Permissions.swift` | Mic + Accessibility prompts |
| `Sources/LocalDictation/Log.swift` | Tee logger to stderr + file + unified logging |
| `scripts/build-app.sh` | Assemble + sign `dist/local-dictation.app` |
| `scripts/install-app.sh` | Copy + sign the app into `~/Applications` |
| `scripts/sign.sh` | Sign the raw `.build` binary (stable identity) |
| `scripts/install-daemon.sh` | Install LaunchAgent |
| `scripts/uninstall-daemon.sh` | Remove LaunchAgent |
| `scripts/make-fixtures.sh` | Generate `Tests/fixtures/` audio (Danish, English, silence) via `say` |
| `scripts/test-cli.sh` | CLI e2e harness: Parakeet, forced Whisper, gated silence |
