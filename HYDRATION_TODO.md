# Handoff todo list: polish validation + Phase 3

Companion to [HYDRATION.md](HYDRATION.md). Recreate these as session tasks
(TaskCreate) when resuming, in this order. Per the user's global CLAUDE.md,
present findings and wait for explicit go-ahead before implementing —
unless the user opens with an execute-everything instruction (the Phase 2
session ran on "use ultracode and whatever you need", which covered
implementation, deploy and local commits).

## Done (previous sessions — do not redo)

- [x] Phase 1: dual-engine ASR, VAD gate, hallucination filter, CLI, menu
  (shipped 2026-07-03).
- [x] Phase 1.5: Danish → Whisper routing, text-LID + code-switch rescues,
  Whisper pre-load (shipped + deployed 2026-07-06, `1a19b74..1bbef3b`).
- [x] Phase 2: FillerFilter + TranscriptPolisher with guardrails, menu
  toggle, CLI `--no-polish`, docs; 15-finding adversarial review fixed;
  160 tests; deployed (shipped 2026-07-06, `31f82eb..bcf5e2f`).
- [x] E2e re-verified after Phase 2: `scripts/test-cli.sh` green, real
  Danish fixture still rescues, filler strip confirmed through real ASR.

## Next session

- [ ] **Gate: user enables Apple Intelligence** (System Settings → Apple
  Intelligence & Siri, model download, then `kickstart -k` the daemon).
  Confirm via the log: the `polish inactive` line must be GONE after a
  dictation. Everything below assumes this.
- [ ] **Prompt bake-off against the real model**: rebuild the fm-spike
  harness (`xcrun swiftc -O -parse-as-library`, ~40 lines, API names in
  CLAUDE.md), run 3 instruction variants × 5 cases (disfluent English with
  "canorical"/"citation", filler-only, Danish passthrough, clean no-op,
  mixed da/en). Judge on: never adds content, Danish untouched, no-op
  stays no-op, latency. Update `TranscriptPolisherLogic.instructions` if a
  variant beats the shipped text; keep guardrail tests green.
- [ ] **Live dictation round with polish active**: user dictates Danish,
  English (disfluent on purpose), and mixed; check `polished=` and the
  `polish rewrote:` log lines; measure added latency (target: well under
  the 6 s timeout, ideally under ~1 s warm).
- [ ] **Tune from the round's evidence**: if the model over-edits, tighten
  instructions or guardrails; if it declines too often, check which
  guardrail fires (`polish rejected: <reason>` in the log).
- [ ] **Decide on pushing/PR**: the branch has ~36 local commits, never
  pushed; ask the user whether to push and open a PR to `main`.

## Later phases (unchanged)

- [ ] **Phase 3**: settings UI (hotkey picker fixes the AltGr conflict,
  thresholds, language pins, engine choice), floating HUD, history/undo,
  guided permissions onboarding, SMAppService launch-at-login.
- [ ] **Phase 4**: distribution (notarized DMG or brew cask, Sparkle
  auto-update, CI). Consider committing Package.resolved.
- [ ] Deferred from the original Phase 2 sketch: AX-based app context,
  personal dictionary (Whisper promptTokens), snippets.
- [ ] Refresh or delete `HYDRATION.md` and `HYDRATION_TODO.md` when the
  polish layer is validated live and Phase 3 starts.
