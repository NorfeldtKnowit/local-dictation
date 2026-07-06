#!/bin/bash
# End-to-end regression harness for the headless `--transcribe-file` CLI.
#
# Requires the real fixtures from `scripts/make-fixtures.sh` (Tests/fixtures/,
# gitignored) and the Parakeet v3 + Whisper large-v3 models already downloaded
# and cached (see CLAUDE.md — cold load is 3-4 min, this script assumes warm).
# Not part of `swift test` / default CI: it shells out to the real release
# binary and loads real on-device models, matching C11's "nightly/manual"
# split from the unit-test suite.
set -euo pipefail

cd "$(dirname "$0")/.."
BIN=".build/release/local-dictation"
FIXTURES="Tests/fixtures"

if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found — run 'swift build -c release' first." >&2
    exit 1
fi

for f in da.aiff en.aiff silence.wav; do
    if [ ! -f "$FIXTURES/$f" ]; then
        echo "error: $FIXTURES/$f missing — run scripts/make-fixtures.sh first." >&2
        exit 1
    fi
done

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# 1. Danish fixture: "da" is whisper-preferred (EngineRouter.whisperPreferred —
#    Parakeet garbles Danish at high confidence), so the pin must route to
#    Whisper WITHOUT --engine. Case-insensitive word check on JSON output;
#    "Hej" is the fixture's opening word.
echo "-- danish -> whisper (routed) --"
DA_JSON="$($BIN --transcribe-file "$FIXTURES/da.aiff" --language da --json)"
echo "$DA_JSON"
echo "$DA_JSON" | grep -qi '"hej' || fail "Danish transcript missing expected word 'hej'"
echo "$DA_JSON" | grep -q '"engine":"whisper"' || fail "Danish fixture did not route to whisper"

# 2. English fixture, pinned "en" routes to Parakeet (the low-latency default) —
#    together with #1 this covers both engines through the ROUTER, not --engine.
echo "-- english -> parakeet (routed) --"
EN_JSON="$($BIN --transcribe-file "$FIXTURES/en.aiff" --language en --json)"
echo "$EN_JSON"
echo "$EN_JSON" | grep -qi "hello" || fail "English transcript missing expected word 'hello'"
echo "$EN_JSON" | grep -q '"engine":"parakeet"' || fail "English fixture did not route to parakeet"

# 2b. --engine override still bypasses the router (forced-engine contract).
echo "-- english -> whisper (forced) --"
EN_OUT="$($BIN --transcribe-file "$FIXTURES/en.aiff" --engine whisper --language en)"
echo "$EN_OUT"
echo "$EN_OUT" | grep -qi "hello" || fail "English (whisper) transcript missing expected word 'hello'"

# 3. Silence fixture must be gated out before ever reaching an engine.
#    Exit 3 alone is NOT enough: the post-ASR hallucination filter also maps to
#    exit 3, so a broken/unavailable VAD that fails open (gate=vadUnavailable),
#    sends the raw silence to Parakeet, and gets a blocklisted ghost back would
#    still exit 3. Grep the stderr diagnostics for the VAD-gate drop reason
#    specifically so that regression can't masquerade as a correctly gated run.
echo "-- silence -> gated --"
SILENCE_OUT="$(mktemp)"
set +e
$BIN --transcribe-file "$FIXTURES/silence.wav" >"$SILENCE_OUT" 2>&1
SILENCE_EXIT=$?
set -e
cat "$SILENCE_OUT"
[ "$SILENCE_EXIT" -eq 3 ] || fail "silence.wav exited $SILENCE_EXIT, expected 3"
grep -q "dropped: silence" "$SILENCE_OUT" \
    || fail "silence.wav was not dropped by the VAD gate (expected 'dropped: silence' on stderr — hallucination-filter drop or VAD fail-open?)"
grep -q "gate=silence" "$SILENCE_OUT" \
    || fail "silence.wav gate decision was not 'silence' (VAD unavailable / fail-open path taken?)"
rm -f "$SILENCE_OUT"

echo "CLI e2e: OK"
