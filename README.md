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
- Post-ASR text stages: hallucination blocklist, deterministic filler strip
  (uh/um/øh/øhm), and an optional LLM transcript polish on Apple's on-device
  Foundation model (see below)
- `NSPasteboard` + synthetic Cmd+V for text injection
- LaunchAgent for always-on daemon behavior

## Dual-engine routing

Every utterance is gated (silence/too-short dropped, speech trimmed) and then
routed to one of the two engines:

| Language setting            | Accuracy Mode | Engine   | Notes                                  |
|------------------------------|:---:|----------|-----------------------------------------|
| Auto                          | off | Parakeet | self-detects; Danish rescued to Whisper (below) |
| Pinned, Whisper-preferred     | off | Whisper  | `da` — Parakeet garbles Danish, Whisper doesn't |
| Pinned, in Parakeet's 28      | off | Parakeet | e.g. `en`, `sv`, `de`                   |
| Pinned, outside Parakeet's 28 | off | Whisper  | e.g. `no`, `ja`, `zh`, `ko`, `ar`       |
| Any                            | on  | Whisper  | forces Whisper for every language      |

On Auto, three rescue layers re-run Parakeet output through Whisper when the
transcript deserves better (the log and CLI JSON carry which one fired):

- **Confidence** — Parakeet below 0.80 is the telltale of a wrong-language
  decode (Danish speech as English gibberish); the whole utterance re-runs
  through Whisper with the pinned language forced.
- **Language** — the transcript *reads* as Danish (text language ID): Parakeet
  is confidently mediocre at Danish, so the utterance re-runs through Whisper
  pinned to `da`. This is what makes Auto-mode Danish come out right.
- **Code-switch** — the transcript (or a per-segment scan at the VAD's pause
  boundaries) mixes Danish with another language: each pause-separated segment
  is routed by its own language, Danish runs through Whisper, the rest keeps
  Parakeet, and the pieces are joined in spoken order. Pause about a second
  when you switch language mid-dictation and each half comes out in its own
  language, correctly.

Whisper is pre-loaded in the background at launch so rescues cost only its
inference (1-2 s), not a model load; set `LOCAL_DICTATION_PRELOAD_WHISPER=0`
to keep it lazy (~1.5 GB residency saved, first rescue pays ~5-8 s). Every
capture is also saved to
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

## Transcript cleanup (filler strip + AI polish)

After the hallucination filter, two cleanup stages run on the transcript:

- **Filler strip** (always on, deterministic): standalone hesitation fillers
  (`uh`, `um`, `erm`; Danish `øh`, `øhm`, `ehm`) are removed, whole-token
  matches only — "serum", "uh-huh" and Danish "er" are never touched. The
  pause-commas a filler drags in go with it ("I want to, uh, refactor" →
  "I want to refactor").
- **Polish Transcript** (menu toggle, on by default): the transcript is
  rewritten by Apple's on-device Foundation model to repair misrecognized
  words from context ("canorical" → "canonical", "citation quality" →
  "dictation quality"), collapse stutters and false starts, and drop
  residual fillers. Fully local, like everything else.

Polish can only ever upgrade an utterance, never lose one: the rewrite is
discarded (raw text pasted) if the model is unavailable, times out (6 s
ceiling), returns something empty, much longer/shorter, multi-line, or in a
different language than it was given. Every accepted rewrite logs the
original ASR text so nothing is unrecoverable.

**Requires Apple Intelligence** (System Settings → Apple Intelligence &
Siri) on macOS 26+. When it's off, the toggle stays functional but inert —
the log shows `polish inactive: … (appleIntelligenceNotEnabled)` once and
dictation behaves exactly as before.

## Delivery options

Two menu toggles control what happens once a transcript is ready
(both off by default):

- **Review Before Paste**: instead of pasting immediately, a small floating
  overlay appears near the top of the screen with two candidates — the RAW
  transcript and a TERSE AI rewrite (the polish stage switches to a
  condensing prompt in this mode). Click one to insert it, or the ✕ to
  insert nothing. The overlay never steals focus, so the caret stays where
  you're typing; if you don't choose in time, the TERSE version
  auto-inserts and the RAW one is placed on the clipboard (paste it with
  Cmd+V if the rewrite lost something). The delay is configurable under
  **Review Auto-Insert ▸**: Auto (scales with length), 10 s, 30 s, or
  Never (the overlay waits for your click; the countdown also pauses while
  your pointer hovers it). Effective only while Polish Transcript is on —
  with polish off there is only one candidate, so text pastes directly.
- **Copy Instead of Paste**: the transcript is placed on the clipboard and
  stays there (no synthetic Cmd+V, no clipboard restore) — paste it
  yourself wherever you want. Composes with Review Before Paste: the
  candidate you pick is what lands on the clipboard.

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
4. Switch to the gray waveform icon (ready).

Then hold **Right Option** and talk. The icon turns **Naples yellow**
while listening, switches to a spinner during transcription, then the
text pastes into the focused app.

## Why stable code signing matters

macOS keys its TCC grants (Accessibility, Input Monitoring, Microphone) off the
binary's code-signing identity. **Ad-hoc signing (`codesign -s -`) produces a
new cdhash on every build**, so macOS treats each rebuild as a brand new app and
silently drops every grant. Symptom: it worked, you rebuilt, now nothing works,
and re-toggling the switch in System Settings does not fix it.

The build scripts therefore sign with a **stable Apple Development
certificate**, not ad-hoc. With a real cert the grants survive rebuilds, so you
grant the three permissions once. `scripts/signing-id.sh` picks the keychain's
Apple Development cert automatically (create one in Xcode → Settings →
Accounts → Manage Certificates if you have none); override via the
`LOCAL_DICTATION_SIGN_ID` env var (set it to `-` to fall back to ad-hoc,
accepting the re-grant-every-build pain):

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

| Icon                       | State                                        |
|----------------------------|----------------------------------------------|
| ⬇  arrow.down.circle       | Loading model on first launch                |
| 〜 waveform (gray)          | Idle — ready, hold Right Option to dictate   |
| 〜 waveform.circle.fill (yellow) | Listening — Naples yellow #FADA5E       |
| ◌ spinner (yellow)         | Transcribing — rotating Naples-yellow symbol |
| ⚠ exclamationmark          | Error — open the menu for context            |

(The idle icon is deliberately not a mic: macOS shows its own mic indicator
in the menu bar while recording, and two mics read as a duplicate.)

## CLI mode (headless transcription)

Running the binary with `--transcribe-file` skips the GUI entirely: no
`NSApplication`, no menu-bar item, no Microphone/Accessibility/Input
Monitoring prompts. It transcribes one audio file through the exact same
`DictationPipeline` the GUI uses (gate → route → transcribe → filter →
polish) and exits with a status code, which makes it safe to call from CI
or scripts.

```bash
local-dictation --transcribe-file <path>
                [--engine auto|parakeet|whisper]   # default auto = real router
                [--language <iso>|auto]            # default auto
                [--accuracy]                       # force Whisper, all languages
                [--no-vad-gate]                     # bypass the silence/speech gate
                [--no-hallucination-filter]         # bypass blocklist + filler strip
                [--no-polish]                       # skip the LLM transcript polish
                [--json]                            # machine-readable stdout
```

Exit codes:

| Code | Meaning                                                  |
|-----:|-----------------------------------------------------------|
| 0    | transcript emitted (on stdout)                            |
| 1    | bad arguments or unreadable file                          |
| 2    | model load / transcription error                          |
| 3    | dropped by the gate (`tooShort`/`silence`) or the hallucination filter (reason on stderr) |

`--json` emits
`{"text","engine","language","gate","filtered","rescued","rescue","polished","latencyMs"}`
on stdout (the `engine` key is omitted when the utterance was dropped before
any engine ran; `rescue` says which rescue layer fired, when one did;
`polished` is true iff the LLM polish rewrote the text); without
it, stdout carries only the plain transcript on success (or nothing on a drop)
so it stays pipeable, and a one-line summary always goes to stderr.
`scripts/make-fixtures.sh` generates local `say`-synthesized Danish/English
fixtures plus a digital-silence WAV; `scripts/test-cli.sh` exercises the exit
paths (routed Whisper for Danish, routed Parakeet for English, forced engine,
gated silence) against the release binary; see that script for the exact
invocations.

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
  blocks the hotkey until "ready" — wait for the gray waveform icon before
  the first press.

## File map

| File | Purpose |
|------|---------|
| `Sources/LocalDictation/App.swift` | `@main` entry point (async, branches to CLI or GUI), app delegate, watchdogs |
| `Sources/LocalDictation/MenuBar.swift` | `NSStatusItem` with five states, Language ▸ submenu, Accuracy Mode, Polish Transcript, Review Before Paste, Copy Instead of Paste |
| `Sources/LocalDictation/HotkeyMonitor.swift` | `CGEventTap` watching Right Option; `isDown` delegates to `HotkeyStateMachine` |
| `Sources/LocalDictation/HotkeyStateMachine.swift` | Pure press/release/tap-disabled state machine (unit tested) |
| `Sources/LocalDictation/AudioRecorder.swift` | AVCaptureSession → 16 kHz mono Float32 (frozen since the Float32 output pin `1ee728e`; do not modify) |
| `Sources/LocalDictation/Transcriber.swift` | WhisperKit wrapper; conforms to `TranscriptionEngine` |
| `Sources/LocalDictation/ParakeetEngine.swift` | FluidAudio Parakeet TDT v3 engine (low-latency default) |
| `Sources/LocalDictation/TranscriptionEngine.swift` | `EngineKind` + the shared engine protocol |
| `Sources/LocalDictation/EngineRouter.swift` | Pure language/Accuracy-Mode → engine routing decision |
| `Sources/LocalDictation/LanguageSetting.swift` | `UserDefaults`-backed language pin + Accuracy/Polish/Review/Copy toggles |
| `Sources/LocalDictation/SpeechGate.swift` | Actor over FluidAudio's Silero VAD; degrades gracefully if unavailable |
| `Sources/LocalDictation/SpeechGateLogic.swift` | Pure gate decision + speech-region trimming (unit tested, no models) |
| `Sources/LocalDictation/HallucinationFilter.swift` | Pure post-ASR blocklist + repetition-loop guard |
| `Sources/LocalDictation/FillerFilter.swift` | Pure standalone-filler strip (en + da), whole-token only |
| `Sources/LocalDictation/TranscriptPolisher.swift` | Actor: LLM polish on Apple FoundationModels; graceful no-op when unavailable |
| `Sources/LocalDictation/TranscriptPolisherLogic.swift` | Pure polish instructions + accept guardrails (unit tested, no model) |
| `Sources/LocalDictation/DictationPipeline.swift` | Actor: gate → route → transcribe → filter → polish (single reuse point, GUI + CLI) |
| `Sources/LocalDictation/UtteranceStateMachine.swift` | Pure recording/transcription bookkeeping with monotonic IDs |
| `Sources/LocalDictation/PasteSequencer.swift` | Pure paste ordering: strict utterance-ID order, >= 300 ms between pastes |
| `Sources/LocalDictation/ReviewQueueLogic.swift` | Pure Review-Before-Paste queue: FIFO, decide-exactly-once, deadman timeout (unit tested) |
| `Sources/LocalDictation/ReviewOverlayController.swift` | Non-activating overlay panel: raw vs terse candidates, countdown, hover pause |
| `Sources/LocalDictation/ReviewCoordinator.swift` | Glue: runs ReviewQueueLogic commands against the overlay + paste sequencer |
| `Sources/LocalDictation/LostReleaseWatchdog.swift` | Pure watchdog decision: re-arm on genuine hold vs end on lost release |
| `Sources/LocalDictation/WavLoader.swift` | `AVAudioFile` → 16 kHz mono Float32 for CLI fixtures (CLI-only; recorder untouched) |
| `Sources/LocalDictation/CLI.swift` | `CLIArguments` parser + `CLIRunner` for `--transcribe-file` |
| `Sources/LocalDictation/TextInjector.swift` | `NSPasteboard` + Cmd+V injection, AX-trust check |
| `Sources/LocalDictation/Permissions.swift` | Mic + Accessibility prompts |
| `Sources/LocalDictation/Log.swift` | Tee logger to stderr + file + unified logging |
| `scripts/build-app.sh` | Assemble + sign `dist/local-dictation.app` |
| `scripts/install-app.sh` | Copy + sign the app into `~/Applications` |
| `scripts/sign.sh` | Sign the raw `.build` binary (stable identity) |
| `scripts/signing-id.sh` | Shared signing-identity resolution (sourced by the three scripts above) |
| `scripts/install-daemon.sh` | Install LaunchAgent |
| `scripts/uninstall-daemon.sh` | Remove LaunchAgent |

## Acknowledgements

This app stands on excellent open work:

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax (MIT):
  on-device Whisper inference via CoreML.
- [FluidAudio](https://github.com/FluidInference/FluidAudio) by FluidInference
  (Apache-2.0): CoreML runtime for Parakeet ASR and Silero VAD.
- [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) by
  NVIDIA (CC-BY-4.0): the low-latency multilingual ASR model.
- [Whisper](https://github.com/openai/whisper) by OpenAI (MIT): the
  accuracy-mode ASR model (large-v3-turbo).
- [Silero VAD](https://github.com/snakers4/silero-vad) by Silero Team (MIT):
  the voice-activity gate.
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) and
  the FoundationModels framework by Apple.

Model weights are downloaded at runtime from their upstream sources and are
covered by their own licenses above; this repository contains no model weights.

## License

No license is granted; all rights reserved. If you would like to use, copy, or
build on this code, please reach out and ask.
| `scripts/make-fixtures.sh` | Generate `Tests/fixtures/` audio (Danish, English, silence) via `say` |
| `scripts/test-cli.sh` | CLI e2e harness: Parakeet, forced Whisper, gated silence |
