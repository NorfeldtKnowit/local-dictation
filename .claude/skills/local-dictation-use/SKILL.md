---
name: local-dictation-use
description: Orient on and debug the local-dictation menu-bar dictation app; check whether it is installed and running, understand the pipeline architecture, diagnose hotkey/paste/transcript problems from the log, and replay the last utterance through either ASR engine. Use when dictation misbehaves or when working on the app.
---

# Using and debugging local-dictation

local-dictation is a menu-bar push-to-talk dictation app: hold Right
Option, speak, release; audio is VAD-gated, routed to a local ASR
engine (FluidAudio Parakeet by default, WhisperKit for Danish/rare
languages/Accuracy Mode), filtered, optionally LLM-polished, then
pasted via synthetic Cmd+V. Fully local; audio never leaves the Mac.

The source of truth for architecture and gotchas is the repo's
`CLAUDE.md` (expected checkout: `~/repos/local-dictation`; locate with
`mdfind -name local-dictation` if moved). When invoked outside the
repo, read that file before nontrivial debugging.

## Is it installed and running?

```bash
launchctl print "gui/$(id -u)/com.norfeldt.local-dictation" | head -5
ls ~/Applications/local-dictation.app
tail -20 ~/Library/Logs/local-dictation.log
```

Restart after any change or grant:
`launchctl kickstart -k "gui/$(id -u)/com.norfeldt.local-dictation"`.

## Pipeline map (capture → paste)

hotkey (CGEvent tap, Right Option) → AVCaptureSession capture →
SpeechGate (Silero VAD, threshold 0.70) → EngineRouter (language +
Accuracy Mode → Parakeet or Whisper, plus three auto-mode rescue
layers) → HallucinationFilter → FillerFilter → TranscriptPolisher
(Apple FoundationModels, optional) → PasteSequencer → Cmd+V.

## Symptom → cause

| Symptom | Check | Likely cause |
|---------|-------|--------------|
| Right Option does nothing | `flagsChanged keyCode=61` lines in log? | None at all: Input Monitoring not granted (tap starts but is deaf). Present but no `beginRecording`: state bug or model still loading. |
| Transcribes but never pastes | `ax-trusted=false` in log | Accessibility not granted; restart daemon after granting. |
| Records but empty transcript | `stop: captured N samples (sample buffers=...)` | `sample buffers=0`: device delivered nothing. Also check `gate=silence` (VAD dropped it). |
| Worked, then rebuilt, now dead | Signing identity changed? | TCC keys grants on the cert; ad-hoc or changed identity drops all grants. See CLAUDE.md. |
| Wrong-language/garbled transcript | `rescued=` marker in the utterance log line | Rescue layers: `confidence`, `language`, `code-switch`. Danish routes to Whisper by design. |
| Transcript oddly rewritten | `polish rewrote:` log line (pre-polish text is logged) | LLM polish stage; toggle off via menu "Polish Transcript" or investigate guardrails. |
| Everything worked, utterance lost | `dropped:` lines | Gate or hallucination filter dropped it (reason given). |
| Orange mic dot stuck on | Usually NOT this app | System Settings → Sound holds the mic while open. |

## Replay the last utterance (best debugging tool)

The GUI saves every capture (single file, overwritten each utterance,
local only) to `~/Library/Caches/local-dictation/last-utterance.wav`.
After a bad dictation, replay it through either engine:

```bash
~/repos/local-dictation/.build/release/local-dictation \
  --transcribe-file ~/Library/Caches/local-dictation/last-utterance.wav \
  --language da --no-polish --json
```

Use `--no-polish` for engine A/B (polish would blur the comparison).
Other levers: `--engine parakeet|whisper`, `--accuracy`,
`--no-vad-gate`, `--no-hallucination-filter`. Exit codes: 0 transcript,
1 bad args, 2 model error, 3 dropped by gate/filter (reason on stderr).

## Log locations and verbose mode

- Main log: `~/Library/Logs/local-dictation.log` (plus `.out.log` /
  `.err.log`).
- `LOCAL_DICTATION_VERBOSE=1` (LaunchAgent plist env) logs every
  modifier keycode. Remove it when done; it is a keylogger-shaped
  setting.
- `LOCAL_DICTATION_SAVE_AUDIO=0` disables the last-utterance capture.
- `LOCAL_DICTATION_PRELOAD_WHISPER=0` keeps Whisper lazy (saves ~1.5 GB
  residency, costs 5-8 s on the first rescue).

## Making changes

The daemon runs the app bundle in `~/Applications`, not the raw SPM
binary. Full deploy cycle after a code change:

```bash
swift build -c release && scripts/build-app.sh && scripts/install-app.sh \
  && launchctl kickstart -k "gui/$(id -u)/com.norfeldt.local-dictation"
```

Read `CLAUDE.md` before touching AudioRecorder (frozen), the hotkey
tap, permissions, or engine routing.
