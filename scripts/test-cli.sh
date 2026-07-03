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

# 1. Danish fixture, routed to Parakeet (default engine for "da"), case-insensitive
#    word check on JSON output. "Hej" is the fixture's opening word.
echo "-- danish -> parakeet --"
DA_JSON="$($BIN --transcribe-file "$FIXTURES/da.aiff" --language da --json)"
echo "$DA_JSON"
echo "$DA_JSON" | grep -qi '"hej' || fail "Danish transcript missing expected word 'hej'"
echo "$DA_JSON" | grep -q '"engine":"parakeet"' || fail "Danish fixture did not route to parakeet"

# 2. English fixture, forced through Whisper via --engine (dual-engine coverage;
#    the default router would also pick Parakeet for "en", so this exercises the
#    --engine override path specifically).
echo "-- english -> whisper (forced) --"
EN_OUT="$($BIN --transcribe-file "$FIXTURES/en.aiff" --engine whisper --language en)"
echo "$EN_OUT"
echo "$EN_OUT" | grep -qi "hello" || fail "English (whisper) transcript missing expected word 'hello'"

# 3. Silence fixture must be gated out before ever reaching an engine (exit 3).
echo "-- silence -> gated --"
set +e
$BIN --transcribe-file "$FIXTURES/silence.wav" >/tmp/local-dictation-silence.out 2>&1
SILENCE_EXIT=$?
set -e
cat /tmp/local-dictation-silence.out
[ "$SILENCE_EXIT" -eq 3 ] || fail "silence.wav exited $SILENCE_EXIT, expected 3"

echo "CLI e2e: OK"
