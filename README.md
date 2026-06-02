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
- WhisperKit (Argmax OSS SDK) with `large-v3-v20240930_626MB` by default
- `NSPasteboard` + synthetic Cmd+V for text injection
- LaunchAgent for always-on daemon behavior

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
| `Sources/LocalDictation/App.swift` | Entry point, app delegate, model warm-up gate |
| `Sources/LocalDictation/MenuBar.swift` | `NSStatusItem` with five states incl. Naples yellow listening |
| `Sources/LocalDictation/HotkeyMonitor.swift` | `CGEventTap` watching Right Option |
| `Sources/LocalDictation/AudioRecorder.swift` | AVCaptureSession → 16 kHz mono Float32 |
| `Sources/LocalDictation/Transcriber.swift` | WhisperKit wrapper, lazy model load + warm-up |
| `Sources/LocalDictation/TextInjector.swift` | `NSPasteboard` + Cmd+V injection, AX-trust check |
| `Sources/LocalDictation/Permissions.swift` | Mic + Accessibility prompts |
| `Sources/LocalDictation/Log.swift` | Tee logger to stderr + file + unified logging |
| `scripts/build-app.sh` | Assemble + sign `dist/local-dictation.app` |
| `scripts/install-app.sh` | Copy + sign the app into `~/Applications` |
| `scripts/sign.sh` | Sign the raw `.build` binary (stable identity) |
| `scripts/install-daemon.sh` | Install LaunchAgent |
| `scripts/uninstall-daemon.sh` | Remove LaunchAgent |
