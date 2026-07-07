#!/usr/bin/env bash
# Copies dist/local-dictation.app into ~/Applications (the standard
# user-level apps folder) and re-signs it. Run this after build-app.sh
# and before install-daemon.sh.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/local-dictation.app"
DST="$HOME/Applications/local-dictation.app"

# Must match build-app.sh so the installed copy keeps the same code-signing
# identity (and therefore the same TCC grants) across rebuilds.
. "$ROOT/scripts/signing-id.sh"

if [ ! -d "$SRC" ]; then
  echo "Source app not found at $SRC — run scripts/build-app.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Applications"
rm -rf "$DST"
cp -R "$SRC" "$DST"

codesign \
  --force \
  --deep \
  --sign "$SIGN_ID" \
  --identifier com.norfeldt.local-dictation \
  "$DST"

echo "Installed: $DST"
echo "Launch it once from Finder (~/Applications) or run:"
echo "  open \"$DST\""
echo "macOS will prompt for Microphone + Accessibility on first launch."
