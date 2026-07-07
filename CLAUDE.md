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
- `AudioRecorder.swift` — mic capture via **AVCaptureSession**, frozen: do
  not modify (see gotcha below). The freeze baseline is the Float32 output
  pin (`1ee728e`, a pre-engine-v2 Bluetooth-HFP fix); the engine-v2 work
  itself added nothing on top of it.
- `SpeechGate.swift` / `SpeechGateLogic.swift` — pre-ASR VAD guard: actor
  wrapper (degrades gracefully if Silero is unavailable) + pure decision/trim
  logic.
- `EngineRouter.swift` — pure language/Accuracy-Mode → engine decision, the
  `whisperPreferred` set (Danish), and the post-Parakeet `textRescuePlan`.
- `TextLanguageID.swift` — text language ID over ASR output (OS-bundled
  `NLLanguageRecognizer`; sentence-level weights detect code-switching).
- `TranscriptionEngine.swift` — shared protocol + `EngineKind`.
- `ParakeetEngine.swift` — FluidAudio Parakeet TDT v3 (low-latency default).
- `Transcriber.swift` — WhisperKit wrapper, conforms to `TranscriptionEngine`.
- `HallucinationFilter.swift` — pure post-ASR blocklist + repetition guard.
- `FillerFilter.swift` — pure standalone-filler strip (uh/um/erm, øh/øhm/ehm),
  whole-token matches only; runs after the hallucination filter.
- `TranscriptPolisher.swift` — actor: optional layer-4 LLM rewrite on Apple
  FoundationModels behind the `TranscriptPolishing` seam; no-ops gracefully
  when Apple Intelligence is unavailable.
- `TranscriptPolisherLogic.swift` — pure polish instructions + accept
  guardrails (length ratio, no added newlines, language-flip reject).
- `DictationPipeline.swift` — actor tying gate → route → transcribe → filter
  → polish together; the single reuse point for both GUI and CLI.
- `LanguageSetting.swift` — `UserDefaults`-backed language pin + accuracy
  mode + polish toggle.
- `UtteranceStateMachine.swift` — pure recording/transcription bookkeeping
  with monotonic IDs.
- `PasteSequencer.swift` — pure paste ordering: flushes outcomes in strict
  utterance-ID order with >= 300 ms between actual pastes.
- `LostReleaseWatchdog.swift` — pure watchdog decision: re-arm on a genuine
  long hold vs end on a lost release.
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
real **Apple Development** certificate, resolved by `scripts/signing-id.sh`
(the `LOCAL_DICTATION_SIGN_ID` env var if set, otherwise the keychain's first
Apple Development cert — create one in Xcode → Settings → Accounts → Manage
Certificates if the script errors out). With a stable cert the grants survive
rebuilds. Do **not** revert these to `-`.

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
then filters; it is the single reuse point for both the GUI and the CLI
(`CLI.swift`). Routing is a pure function (`EngineRouter.route`):

| language setting | accuracyMode | engine | hint passed |
|---|:---:|---|---|
| `auto` | off | Parakeet | `nil` (self-detects; rescue layers below may re-run via Whisper) |
| code in `whisperPreferred` (**da**) | off | Whisper | `DecodingOptions.language`, `detectLanguage: false` |
| other code in Parakeet's 28 (en, sv, …) | off | Parakeet | `Language(rawValue:)` script filter |
| code not in Parakeet's 28 (ja, zh, ar, ko, **no**, …) | off | Whisper | `DecodingOptions.language`, `detectLanguage: false` |
| any | on | Whisper | code or nil+detect |

`EngineRouter.whisperPreferred` (currently `{"da"}`) marks languages Parakeet
nominally supports but transcribes measurably worse than Whisper. A/B on a
real Danish utterance (2026-07-06, a gitignored `fixtures-real/` recording —
real-voice audio never enters git; keep it that way):
Parakeet produced "komet omskrivning af foreningen … starte forfar" at
confidence **0.96**; Whisper pinned `da` produced the correct "komplet
omskrivning af forgreningen … starte forfra". That 0.96 is the key fact —
within-language errors score as high as clean output, so no confidence
threshold can catch them; routing and text LID (below) are the levers.

There is deliberately no silent cross-engine fallback: a warm-up/transcribe
failure on the routed engine surfaces as an error, never a different engine's
output passed off as the requested one. The one sanctioned exception is a
Parakeet launch failure, which flips a `forceWhisper` override (equivalent to
Accuracy Mode): Whisper is a safe universal superset, so that direction is
always correct.

### The three rescue layers (auto mode only)

In auto mode `DictationPipeline` may re-run a Parakeet transcript through
Whisper. Which layer fired is in the log line and CLI JSON (`rescued=` /
`"rescue"`: `confidence` | `language` | `code-switch`). Shared rules: a forced
`--engine` never rescues (explicit choice wins), a pinned language never
text-rescues (only the confidence layer applies there), and any rescue
failure keeps Parakeet's text — a dubious transcript beats a lost utterance.

1. **Confidence** (< 0.80, `DictationPipeline.defaultRescueConfidence`).
   Parakeet v3's `language:` hint is only a script filter; Danish and English
   are both Latin, so a wrong-language decode's only tell is low confidence
   (measured: 0.88-0.97 clean vs 0.59 for Danish decoded as English). Whole
   buffer re-runs through Whisper, where a pin IS forced.
2. **Language** (`EngineRouter.textRescuePlan` → `.wholeUtterance`). The
   transcript READS as a whisper-preferred language per `TextLanguageID`
   (sentence-level, char-weighted; `nb` folds into `da` — NLLanguageRecognizer
   often labels garbled Danish as Bokmål). Catches Parakeet's
   high-confidence-but-wrong Danish, which layer 1 cannot.
3. **Code-switch** (`.perSegment`, or a segment scan when the whole-buffer
   text looks monolingual but the gate found 2+ VAD segments — Parakeet can
   silently DROP a whole sentence in the other language at confidence 1.00,
   leaving no textual trace). Each pause-separated segment is transcribed by
   Parakeet for LID, consecutive Danish segments merge into runs that re-run
   through Whisper pinned `da`, other segments keep Parakeet text, pieces
   join in spoken order. Needs a ~0.6-0.8 s pause at the language switch (see
   `SpeechGate.segConfig` — the VAD's 4096-sample hop quantizes
   `minSilenceDuration` up to whole frames).

Whisper is pre-loaded in the background at GUI launch (a rescue would
otherwise pay the ~5-8 s warm load mid-dictation; `warmUp`, not just
`predownloadModel`); set `LOCAL_DICTATION_PRELOAD_WHISPER=0` in the
LaunchAgent plist to keep it lazy and save ~1.5 GB residency. Once resident,
rescues cost only Whisper inference (about 1-2 s).

## Post-ASR text stages: filler strip + transcript polish (layer 4)

Transcript order inside `DictationPipeline.process`:
`raw ASR → HallucinationFilter → FillerFilter → (optional) TranscriptPolisher`.
`--no-hallucination-filter` bypasses BOTH deterministic filters (its contract
is "raw ASR text"); `--no-polish` / the menu's "Polish Transcript" checkbox
(default on, persisted like Accuracy Mode) control only the LLM stage.

- **FillerFilter** is pure and always safe: whole-token matches only, so
  Danish "er" (a filler-looking real word), "serum", "uh-huh" are never
  touched. It repairs only the punctuation the filler itself dragged in
  (pause-comma pairs, sentence-final terminators, leading capital hand-off).
- **TranscriptPolisher** runs Apple's on-device Foundation model
  (`FoundationModels`, macOS 26+) with instructions + guardrails in
  `TranscriptPolisherLogic` (pure, unit-tested). Non-negotiables, all encoded
  as tests: a decline (model unavailable, error, 6 s `AsyncTimeout.run`
  breach, guardrail reject) ALWAYS keeps the filtered ASR text; gated /
  filter-suppressed / empty outcomes are never polished; accepted rewrites
  must stay within 0.3-1.3x of the raw length, add no newlines, and keep the
  dominant language (`nb` folds into `da`, same convention as the router).
  Every accepted rewrite logs the pre-polish text, so the raw ASR output is
  always recoverable from the log.
- **Fresh `LanguageModelSession` per utterance** — session context
  accumulates, and one utterance must never leak into the next (privacy +
  drift). Greedy sampling for determinism; the model weights stay resident
  across sessions, so per-session cost is negligible.
- **Apple Intelligence must be enabled** (System Settings → Apple
  Intelligence & Siri) or `SystemLanguageModel.default.availability` reports
  `.unavailable(appleIntelligenceNotEnabled)` and the stage is inert; the
  once-per-process log line `polish inactive: …` is the tell. The package
  platform stays macOS 14 — all FoundationModels usage sits behind
  `#if canImport(FoundationModels)` + `#available(macOS 26.0, *)`.
- Spike-harness gotcha for measuring prompts against the raw model: a
  single-file CLI needs `xcrun swiftc -O -parse-as-library` (plain `swiftc`
  rejects `@main` in a one-file build without that flag).

### Debugging bad transcripts: the last utterance is on disk

Synthesized `say` fixtures proved misleading for real-speech quality, so the
GUI saves every capture (single file, overwritten per utterance, local only)
to `~/Library/Caches/local-dictation/last-utterance.wav`. After a bad
dictation, replay the actual audio through either engine:

```bash
.build/release/local-dictation --transcribe-file \
  ~/Library/Caches/local-dictation/last-utterance.wav \
  --language da --no-polish --json
```

(`--no-polish` because an A/B replay is about the ENGINE's output; letting
the LLM polish rewrite it would blur what you are comparing.)

Opt out by setting `LOCAL_DICTATION_SAVE_AUDIO=0` in the LaunchAgent plist.

### FluidAudio's `Language` enum has no Norwegian

`Language.allCases` (imported from FluidAudio) is exactly 28 cases across
Latin/Cyrillic/Greek scripts, and **does not contain Norwegian** (`no`/`nb`).
For a Nordic user this is a routing landmine: Norwegian must always be pinned
to Whisper (or routed there via Accuracy Mode), never assumed to work in Auto.
The menu's Language ▸ submenu lists it explicitly under "Other (Whisper)"
alongside Japanese/Chinese/Korean/Arabic. Also note: the FluidAudio module
exports a `public struct FluidAudio` that shadows the module name, so
`FluidAudio.Language.init(rawValue:)` fails to resolve ("type FluidAudio has
no member Language"); use the bare `Language` name after `import FluidAudio`.

### VAD threshold: 0.70, not the library default 0.85

`VadConfig.defaultThreshold` defaults to **0.85** in FluidAudio (verified in
`VadTypes.swift`), which under-triggers on quiet Danish speech: utterances
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
not call-site order: a decode call that lists `noSpeechThreshold:` before
`logProbThreshold:`/`compressionRatioThreshold:` (a very natural way to group
"the anti-hallucination levers") **will not compile**. Also worth knowing: the
canonical anti-hallucination values (`noSpeechThreshold: 0.6, logProbThreshold:
-1.0, compressionRatioThreshold: 2.4`) are already the library's **defaults**;
they don't need restating unless you intend to change them. The levers this
app actually sets are `language:`, `detectLanguage:`, and `chunkingStrategy:
.vad`. If you touch `Transcriber.transcribe`, verify argument order against
the checked-out source before compiling, not from memory or from an older
snippet.

### Timeouts around Core ML: task groups can't bail out

Do not implement the transcription hang guard with `withThrowingTaskGroup`:
structured concurrency must cancel **and await** every child before the group
can rethrow, and a wedged Core ML inference ignores cooperative cancellation,
so a "timeout" child that throws at the deadline still blocks until the
inference actually returns (i.e. never, for a true hang). That leaves the menu
pinned on "Transcribing…" and the utterance forever in flight, exactly the
failure the guard exists to bound. `AsyncTimeout.run` exists for this: an
unstructured continuation-based race that abandons the wedged body and fires
at the deadline (regression-tested in `AsyncTimeoutTests`).

## Testing

- **Executable targets are unit-testable directly**: SPM has supported test
  targets depending on executable targets since **Swift 5.5**; `@testable
  import LocalDictation` from `Tests/LocalDictationTests` works with no
  library-target split. Don't reintroduce one "to make testing possible"; it
  isn't needed and it would move every TCC-sensitive file.
- `swift test` runs the pure-logic suite (state machines, router, gate logic,
  hallucination filter, pipeline via fakes, CLI argument parsing): no models,
  no mic, seconds to run, safe for default CI.
- `scripts/test-cli.sh` is the model-touching e2e layer: it drives the real
  release binary's `--transcribe-file` mode against `scripts/make-fixtures.sh`
  fixtures (Danish → Whisper via `whisperPreferred` routing, English →
  Parakeet via the router, English forced through `--engine whisper`,
  digital silence → exit 3 **and** `dropped: silence`/`gate=silence` on
  stderr, because exit 3 alone is ambiguous with a hallucination-filter drop
  after a VAD fail-open) and needs Parakeet v3 + Whisper large-v3 already cached
  locally. Treat it as manual/nightly, not part of `swift test`.
- CLI mode (`--transcribe-file <path> [--engine …] [--language …] [--accuracy]
  [--no-vad-gate] [--no-hallucination-filter] [--no-polish] [--json]`) constructs no
  `AudioRecorder`/`HotkeyMonitor`/`MenuBar`/`NSApp`; it requests zero TCC
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
