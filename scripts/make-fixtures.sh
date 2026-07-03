#!/bin/bash
# Generate the audio fixtures the CLI e2e checks transcribe against.
#
# `say -v Samantha` (and other named voices) are NOT guaranteed to exist on every
# machine, so we pick the first *installed* voice from a preference list by
# scanning `say -v '?'` rather than hard-coding one. Danish prefers Sara/Magnus,
# English prefers Daniel/Fred (both clean, unambiguous names). Fixtures are
# generated, not committed (see .gitignore).
set -euo pipefail

cd "$(dirname "$0")/.."
FIXTURES="Tests/fixtures"
mkdir -p "$FIXTURES"

VOICES="$(say -v '?')"

# Print the first candidate that appears (as a voice name) in `say -v '?'`.
# Voice lines look like "Sara                da_DK    # ...", so we anchor the
# candidate at the start of the line followed by whitespace.
pick_voice() {
    local cand
    for cand in "$@"; do
        if grep -q "^${cand}[[:space:]]" <<<"$VOICES"; then
            echo "$cand"
            return 0
        fi
    done
    return 1
}

DA_VOICE="$(pick_voice Sara Magnus)" || {
    echo "error: no Danish voice found (tried Sara, Magnus). Install one in System Settings > Accessibility > Spoken Content." >&2
    exit 1
}
EN_VOICE="$(pick_voice Daniel Fred Samantha)" || {
    echo "error: no English voice found (tried Daniel, Fred, Samantha)." >&2
    exit 1
}

echo "Danish voice:  $DA_VOICE"
echo "English voice: $EN_VOICE"

say -v "$DA_VOICE" -o "$FIXTURES/da.aiff" "Hej med dig, det her er en test af diktering."
say -v "$EN_VOICE" -o "$FIXTURES/en.aiff" "Hello, this is a test of the dictation pipeline."

# 2 s of pure digital silence at 16 kHz mono — must be gated out (exit code 3).
python3 - "$FIXTURES/silence.wav" <<'PY'
import sys, wave, struct
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)          # 16-bit PCM
    w.setframerate(16000)
    w.writeframes(struct.pack("<%dh" % 32000, *([0] * 32000)))   # 2 s of zeros
PY

echo "Fixtures written to $FIXTURES/: da.aiff, en.aiff, silence.wav"
