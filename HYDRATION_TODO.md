# Handoff todo list: Phase 2 (LLM transcript polish)

Companion to [HYDRATION.md](HYDRATION.md). Recreate these as session tasks
(TaskCreate) when resuming, in this order. Per the user's global CLAUDE.md,
present the plan/spike results and wait for explicit go-ahead before
implementing.

## Done (previous sessions — do not redo)

- [x] Phase 1: dual-engine ASR, VAD gate, hallucination filter, CLI, menu
  (shipped 2026-07-03).
- [x] Phase 1.5: Danish → Whisper routing, text-LID + code-switch rescues,
  Whisper pre-load (shipped + deployed 2026-07-06, `1a19b74..1bbef3b`).
- [x] Live validation: Danish and mixed utterances perfect; English via
  Parakeet identified as the remaining weak spot (fillers, restarts,
  non-words). See HYDRATION.md for the exact transcripts.
- [x] `scripts/test-cli.sh` green with the da→whisper routing contract.

## Phase 2 plan (next session)

Goal: a fully local post-ASR cleanup pass — strip fillers, collapse
restarts, repair non-words and acoustic misses from context — that never
adds content and can be disabled. Wispr Flow parity feature.

- [ ] **Quick win first — filler strip, no LLM**: pure function (new file or
  `HallucinationFilter` sibling) removing standalone fillers
  (en: uh/um/erm; da: øh/øhm/ehm) with unit tests. Conservative: whole-token
  matches only, never inside words, keep real discourse words ("altså").
  Ship + deploy this even if the LLM work stalls.
- [ ] **Spike Apple Foundation Models** (macOS 26.5 is running): check
  `import FoundationModels` builds with our SPM toolchain,
  `SystemLanguageModel.default.availability`, then measure a cleanup prompt
  on utterance-1-style text (latency target: a few hundred ms; quality:
  fixes "canorical"→"canonical", "citation"→"dictation" in context,
  collapses restarts; verify behaviour on DANISH text too). Fallback
  candidate if unavailable/poor: small MLX instruct model (extra download;
  decide only after the spike).
- [ ] **Design before implementing** (present to user): `TranscriptPolisher`
  actor behind a protocol seam (prompt building + guardrails pure and unit
  tested); pipeline stage AFTER `HallucinationFilter`; menu toggle
  ("Polish transcript"?) persisted in `LanguageSetting`-style defaults; CLI
  `--no-polish` flag + `polished` key in JSON; raw ASR text always kept in
  the log line.
- [ ] **Guardrails** (non-negotiable, encode as tests): fall back to the raw
  transcript on any error or timeout (`AsyncTimeout.run`, NOT task groups —
  see CLAUDE.md); reject rewrites that change length beyond a sane ratio or
  return empty; never polish an errored/gated outcome; polish must be a
  no-op when the model is unavailable (graceful degradation like the VAD).
- [ ] **Verify e2e**: unit suite; CLI replay of
  `fixtures-real/danish-tech-utterance5.wav` and a scripted
  disfluent-English fixture; then build-app/install-app/kickstart deploy and
  a live dictation round with the user.
- [ ] **Update docs + this handoff**: CLAUDE.md section for the polish
  layer, README feature list, auto-memory `engine-v2-roadmap`.

## Other pending (unchanged)

- [ ] **Decide on pushing/PR**: `feat/engine-v2-streaming` has ~30 local
  commits, never pushed; ask the user whether to push and open a PR to
  `main`.
- [ ] Optional A/B the user may run themselves: Accuracy Mode on for a day
  (English through Whisper) to gauge how much polish the ASR alone buys.
- [ ] **Phase 3**: settings UI (hotkey picker, thresholds, language pins,
  engine choice).
- [ ] **Phase 4**: distribution (notarized DMG or brew cask, auto-update).
- [ ] Delete `HYDRATION.md` and `HYDRATION_TODO.md` when Phase 2 ships.
