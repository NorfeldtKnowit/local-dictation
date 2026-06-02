# CLAUDE.md

Guidance for working on local-dictation. Read this before touching audio
capture, the global hotkey, or anything permission related: each of those has
a non-obvious macOS gotcha that cost real debugging time, documented below.

## What this is

A menu-bar push-to-talk dictation app. Hold **Right Option** (or left-click the
menu-bar icon), speak, release; the audio is transcribed locally with WhisperKit
and pasted into the focused app via synthetic Cmd+V. Runs as a per-user
LaunchAgent. See `README.md` for the user-facing overview and stack.

Source layout (`Sources/LocalDictation/`):

- `App.swift` — `AppDelegate`, wires permissions, hotkey, recorder, transcriber.
- `HotkeyMonitor.swift` — `CGEvent` tap watching Right Option (keycode 61).
- `AudioRecorder.swift` — mic capture via **AVCaptureSession** (see gotcha below).
- `Transcriber.swift` — WhisperKit wrapper.
- `TextInjector.swift` — pasteboard + synthetic Cmd+V.
- `MenuBar.swift` — status item, click handling, state icons, spinner.
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
