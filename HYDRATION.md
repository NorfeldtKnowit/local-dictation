# Context hydration: engine-v2 session handoff

Snapshot taken 2026-07-06 ~15:00 local, at the end of the Phase 2 session
(filler strip + LLM transcript polish). Read this plus
[HYDRATION_TODO.md](HYDRATION_TODO.md) to start the next session fresh.
Refresh or delete both files when the polish layer is validated live and
Phase 3 begins.

## Mission

Make this fully local multilanguage dictation app production grade and
competitive with [Wispr Flow](https://wisprflow.ai/features). Roadmap lives
in auto-memory `engine-v2-roadmap`: Phases 1, 1.5 and 2 are shipped on
branch `feat/engine-v2-streaming` (~36 local commits, never pushed;
pushing/PR is an explicit pending decision for the user). Phases 3-4
(settings UI, distribution) remain.

## What Phase 2 shipped (2026-07-06, commits `31f82eb..bcf5e2f`)

All deployed and live in the daemon; 160 unit tests green,
`scripts/test-cli.sh` green:

- `FillerFilter` — pure standalone-filler strip (uh/um/uhm/erm, øh/øhm/ehm),
  whole-token only, always on. Verified through real ASR: "Um, so basically
  I want to, uh, refactor the parser module." pastes as "So basically I
  want to refactor the parser module."
- `TranscriptPolisher` + `TranscriptPolisherLogic` — layer-4 LLM rewrite on
  Apple FoundationModels (on-device), behind the `TranscriptPolishing`
  seam. Guardrails (all unit-tested): 16-2500 char window, 0.3-1.3x length
  ratio, no added line breaks, wrapper-quote unwrap, >=66% word overlap,
  sentence-weighted no-language-vanishes rule (nb folds into da). Any
  decline keeps the ASR text; polish can never lose an utterance.
- Surface: "Polish Transcript" menu checkbox (default ON, persisted), CLI
  `--no-polish` + `"polished"` JSON key, `polished=` in the utterance log
  line, background model warm-up at GUI launch.
- Docs: CLAUDE.md "Post-ASR text stages" section and README "Transcript
  cleanup" section carry the details — read those, do not re-derive.

An adversarial 15-finding review hardened it. The three findings worth
remembering: FoundationModels **truncates silently** at
`maximumResponseTokens` (no error, no finish reason — hence the 2500-char
polish ceiling); a whole-text dominant-language compare misses the minority
half of a mixed utterance being translated (hence the per-language vanish
rule); `test-cli.sh` must pass `--no-polish` to stay deterministic on
Apple-Intelligence-enabled hosts.

## THE blocker: Apple Intelligence is disabled on this Mac

`SystemLanguageModel.default.availability` reports
`unavailable(appleIntelligenceNotEnabled)`, so the polish stage is
currently a verified no-op (log tell: `polish inactive: …`, once per
process). Only the user can fix this: System Settings → Apple Intelligence
& Siri, enable, let the model download, then
`launchctl kickstart -k gui/$(id -u)/com.norfeldt.local-dictation`.

Consequence: `TranscriptPolisherLogic.instructions` (the shipped prompt)
is **unvalidated against the real model**. A 3-variant × 5-case prompt
bake-off was authored but skipped at the availability gate. The spike
harness lived in the session scratchpad (`fm-spike/harness`), which may be
gone; rebuilding is trivial — a ~40-line CLI over
`LanguageModelSession(instructions:)` / `respond(to:options:)`, compiled
with `xcrun swiftc -O -parse-as-library` (gotcha documented in CLAUDE.md).

## Live validation state

- Phase 1.5 behavior re-verified this session: real Danish fixture
  (`fixtures-real/danish-tech-utterance5.wav`, gitignored real voice —
  never commit or push) still auto-rescues via `rescue=language` to correct
  Danish.
- Filler strip verified live through the CLI on a synthesized disfluent
  fixture (see above).
- NOT yet done: a live push-to-talk round with polish actually active
  (blocked on Apple Intelligence), and the user's verdict on English
  quality with polish on.

## Working state

Branch `feat/engine-v2-streaming`, clean tree, all work committed locally.
The daemon runs the deployed Phase 2 bundle. Deploy cycle and permission
gotchas are in CLAUDE.md.
