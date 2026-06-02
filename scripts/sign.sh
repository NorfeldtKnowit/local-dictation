#!/usr/bin/env bash
# Code-signs the release binary with a stable identity so macOS preserves
# Accessibility / Input Monitoring grants across rebuilds.
#
# Without a stable identity, every `swift build` produces a binary with a
# new cdhash and macOS silently un-trusts it — synthetic Cmd+V stops working
# even though the toggle in System Settings still looks enabled.
#
# NOTE: the daemon runs the .app bundle (built by build-app.sh / install-app.sh),
# not this raw binary, so those scripts do the signing that matters for the
# running app. This is mainly for running .build/release directly.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/local-dictation"

# Stable signing identity (same default as build-app.sh / install-app.sh).
# Override with LOCAL_DICTATION_SIGN_ID, or set it to "-" for ad-hoc.
SIGN_ID="${LOCAL_DICTATION_SIGN_ID:-5FA4A452E6583B1C54CA2F9C0CD563CAA77DAA0E}"

if [ ! -f "$BIN" ]; then
  echo "Binary not found at $BIN — run 'swift build -c release' first." >&2
  exit 1
fi

codesign \
  --force \
  --sign "$SIGN_ID" \
  --identifier com.norfeldt.local-dictation \
  "$BIN"

echo "Signed: $BIN"
codesign --display --verbose=2 "$BIN" 2>&1 | sed 's/^/  /'
