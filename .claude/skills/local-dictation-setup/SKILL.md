---
name: local-dictation-setup
description: Install local-dictation on this Mac from a fresh clone; build, sign, install the LaunchAgent, walk the three TCC permission grants in the right order, download models, and verify each step against the log. Use when setting up a new machine or repairing a broken install.
---

# Set up local-dictation on this Mac

Follow the steps in order. Each step has a verification; do not move on
until it passes. The deep background for every gotcha here is in the
repo's `CLAUDE.md`; read the "Permissions and code signing" section if
anything deviates.

## 1. Prerequisites

Check, and report anything missing to the user before proceeding:

- macOS 14+ on Apple Silicon (`sw_vers`, `uname -m`). The optional AI
  polish stage additionally needs macOS 26+ with Apple Intelligence.
- **Full Xcode**, not just Command Line Tools: `xcode-select -p` should
  point at `Xcode.app` (`sudo xcode-select -s /Applications/Xcode.app`
  if it points at CommandLineTools). Step 3's `scripts/build-metallib.sh`
  runs `xcodebuild` to compile MLX's Metal shaders, which the CLT-only
  toolchain cannot do.
- Swift toolchain: `swift --version` (bundled with Xcode).
- An **Apple Development certificate** in the keychain:
  `security find-identity -v -p codesigning | grep "Apple Development"`.
  If none: the user must create one in Xcode → Settings → Accounts →
  Manage Certificates (a free Apple ID account suffices). Do NOT fall
  back to ad-hoc signing; TCC grants would drop on every rebuild.
- Disk: roughly 4 GB free for the ASR models (Parakeet ~1 GB, Whisper
  large-v3-turbo ~1.6 GB, Silero VAD is small), plus ~2.5 GB more if the
  user wants Review-Before-Paste polish in a non-English language, which
  pulls the Qwen3-4B MLX model (see step 7).

## 2. Build and test

```bash
swift build -c release   # first run resolves SPM deps, takes a while
swift test               # pure-logic suite, no models, seconds
```

Verify: build succeeds, all tests pass. Test failures on a clean clone
are a stop-the-line event; report them.

## 3. Bundle, install, start the daemon

```bash
scripts/build-metallib.sh   # compile MLX's Metal shaders via xcodebuild;
                            # several minutes, ONE-TIME (cached in .build/)
scripts/build-app.sh        # assemble + sign dist/local-dictation.app
scripts/install-app.sh      # copy + sign into ~/Applications
scripts/install-daemon.sh
```

`build-metallib.sh` is mandatory and must come first: `swift build` cannot
compile MLX's `.metal` sources, and `build-app.sh` hard-errors ("Missing
.build/mlx.metallib") without the artifact it produces. It needs full Xcode
(step 1) and is cached — re-run it only after bumping mlx-swift
(`scripts/build-metallib.sh --force`). Verify: `.build/mlx.metallib` exists
and `build-app.sh` completes.

Known trap: `install-daemon.sh`'s bootstrap step fails with
`5: Input/output error` if the agent is already registered. Then either
`launchctl kickstart -k "gui/$(id -u)/com.norfeldt.local-dictation"` or
`bootout` followed by `bootstrap`.

Verify: `launchctl print "gui/$(id -u)/com.norfeldt.local-dictation"`
shows state = running, and `~/Library/Logs/local-dictation.log` starts
receiving lines.

## 4. Permission grants (order matters)

Three separate TCC categories. After EACH grant, restart the daemon
(`launchctl kickstart -k ...`): a freshly granted permission does not
reach the already-running process.

1. **Microphone**: prompted automatically on first recording attempt.
2. **Input Monitoring**: never prompted reliably; open the pane with
   `open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"`
   and enable `local-dictation`. Failure tell: holding Right Option
   produces NO `flagsChanged keyCode=61` lines in the log (the event
   tap starts successfully but receives zero events; silent failure).
3. **Accessibility**: needed for the synthetic Cmd+V paste. Pane:
   `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
   Failure tell: transcription works but nothing pastes, and the log
   shows `ax-trusted=false`.

If a grant looks enabled but does not take effect (or duplicate rows
appear in Settings), reset that category once and re-grant:

```bash
tccutil reset Accessibility com.norfeldt.local-dictation
tccutil reset ListenEvent   com.norfeldt.local-dictation
tccutil reset Microphone    com.norfeldt.local-dictation
```

## 5. Models

First launch downloads and cold-loads models. Whisper takes roughly 3-4
minutes on the first launch after a restart, under 10 s warm. Wait for
`model ready` in the log; the hotkey is a no-op until then.

## 6. End-to-end verification

1. Open TextEdit, focus a document.
2. Hold Right Option, say a full sentence, release.
3. The sentence should paste within a few seconds.
4. Check the log's utterance line for `engine=`, `gate=`, and (if
   enabled) `polished=` markers.

Headless check without any permissions (also good on CI):

```bash
scripts/make-fixtures.sh && scripts/test-cli.sh
```

## 7. Optional: AI transcript polish + Review Before Paste

The inline **Polish Transcript** stage (menu toggle, on by default) runs on
Apple's on-device Foundation model. Requires Apple Intelligence enabled
(System Settings → Apple Intelligence & Siri) and its model downloaded.
After enabling, `kickstart -k` the daemon and confirm the `polish inactive:`
log line is gone. Without it the polish stage is a safe no-op.

**Review Before Paste** (menu toggle, off by default) streams a terse rewrite
into a floating overlay before pasting. English rewrites reuse the Apple
Foundation model; every other language (Danish included) runs a local
**Qwen3-4B-Instruct** via MLX — a one-time ~2.5 GB download to the Hugging
Face cache the first time review mode runs. This is why `build-metallib.sh`
(step 3) is mandatory even though inline polish alone doesn't exercise MLX.
Set `LOCAL_DICTATION_PRELOAD_QWEN=0` in the LaunchAgent plist to defer the
download to first use instead of preloading at launch.

## 8. Optional: make the companion skill global

The repo ships `local-dictation-use` (orientation + debugging). Symlink
it into the user's global skills so it works from any directory:

```bash
ln -sfn "$(pwd)/.claude/skills/local-dictation-use" \
  ~/.claude/skills/local-dictation-use
```

Ask the user before creating the symlink.
