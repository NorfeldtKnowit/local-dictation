# Context hydration: engine-v2 session handoff

Snapshot taken 2026-07-06 ~13:30 local, at the end of the Phase 1.5 session
(Danish quality + code-switching). Read this plus
[HYDRATION_TODO.md](HYDRATION_TODO.md) to start the Phase 2 session fresh.
Delete both files when Phase 2 ships.

## Mission

Make this fully local multilanguage dictation app production grade and
competitive with [Wispr Flow](https://wisprflow.ai/features). Roadmap lives
in auto-memory `engine-v2-roadmap`: Phases 1 + 1.5 shipped and deployed on
branch `feat/engine-v2-streaming` (local commits only, not pushed); Phase 2
(LLM cleanup) is next; Phases 3-4 (settings UI, distribution) after.

## What Phase 1.5 shipped (2026-07-06, commits `1a19b74..1bbef3b`)

Root cause of the user's "too many Danish mistakes": Parakeet garbles Danish
at HIGH confidence (0.96), invisible to the 0.80 confidence rescue. Fixes,
all deployed and live in the daemon:

- Danish is whisper-preferred (`EngineRouter.whisperPreferred`): pinned `da`
  routes to Whisper outright; the menu lists Danish under "Other (Whisper)".
- Auto mode: text-LID rescue (`TextLanguageID` sentence weights, `nb` folds
  into `da`) re-runs Danish-reading transcripts through Whisper pinned `da`.
- Auto mode: code-switch rescue re-transcribes per VAD segment when mixing
  is detected (or when a 2+-segment scan finds Danish the whole-buffer
  decode dropped); needs a ~0.6-0.8 s pause at the language switch.
- Whisper pre-loads at GUI launch (`LOCAL_DICTATION_PRELOAD_WHISPER=0` opts
  out), so rescues cost ~1-2 s inference, never a 5-8 s model load.

Details and the measured A/B are in CLAUDE.md ("Dual-engine routing" and
"The three rescue layers") — read those, do not re-derive. 115 unit tests
green; `scripts/test-cli.sh` green with the flipped contract (da → whisper,
en → parakeet).

## Live validation results (user's real push-to-talk, 2026-07-06 ~13:13)

- Danish-only: perfect, incl. "Rød-grød med fløde" (`rescued=language`,
  1.8 s).
- Mixed da/en in one utterance: perfect — whole-buffer Whisper pinned `da`
  kept the embedded English as English (`rescued=language`).
- English-only: the remaining weak spot. Parakeet kept fillers and restarts
  verbatim and produced "canorical" (non-word) and "citation" (acoustic miss
  for "dictation"). 0.68 s, no rescue — correctly so; this is not a routing
  problem.

## The user's Phase 2 request (their words, lightly compressed)

"Instead of writing words that do not exist, do a REALLY good autocomplete."
I.e. a context-aware post-ASR rewrite: repair non-words AND acoustic misses
("citation" is correctly spelled — only context reveals "dictation"),
collapse restarts ("it it wor how good how good" → "how good"), strip
fillers. A spell checker cannot do any of this; it is LLM-shaped. This is
exactly roadmap Phase 2. The plan is in
[HYDRATION_TODO.md](HYDRATION_TODO.md).

An alternative lever was offered to the user (untested): Accuracy Mode on
for a day routes English through Whisper too (~0.7 s → ~2 s), which invents
fewer non-words and drops fillers naturally. If the user reports having
tried it, factor that into how aggressive the polish pass needs to be.

## Working state

Branch `feat/engine-v2-streaming`, clean tree, all work committed locally
(never pushed; pushing/PR is an explicit pending decision for the user).
The real Danish test utterance is preserved at
`fixtures-real/danish-tech-utterance5.wav` (gitignored real voice — never
commit or push audio from there). The daemon runs the deployed Phase 1.5
bundle; deploy cycle and permission gotchas are in CLAUDE.md.
