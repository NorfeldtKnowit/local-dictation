#!/usr/bin/env bash
# Assembles dist/local-dictation.app from the SPM release binary.
# Run after `swift build -c release`.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/local-dictation"
APP="$ROOT/dist/local-dictation.app"

# Sign with a STABLE identity so macOS preserves Accessibility / Input
# Monitoring / Microphone grants across rebuilds. Ad-hoc ("-") changes the
# binary's cdhash every build, so TCC treats each rebuild as a new app and
# silently drops every grant. A real signing identity keys TCC on the
# certificate, which survives rebuilds. Resolution (env override or the
# keychain's Apple Development cert) lives in signing-id.sh.
. "$ROOT/scripts/signing-id.sh"

if [ ! -f "$BIN" ]; then
  echo "Binary not found at $BIN — run 'swift build -c release' first." >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/local-dictation"
chmod +x "$APP/Contents/MacOS/local-dictation"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.norfeldt.local-dictation</string>
  <key>CFBundleName</key>
  <string>LocalDictation</string>
  <key>CFBundleDisplayName</key>
  <string>Local Dictation</string>
  <key>CFBundleExecutable</key>
  <string>local-dictation</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Local Dictation captures your voice while you hold Right Option and transcribes it locally with Whisper. Audio never leaves your machine.</string>
</dict>
</plist>
PLIST

# Sign the bundle (not just the inner binary) so TCC keys consent on
# the bundle identity.
#
# Intentionally NOT using --options runtime: hardened runtime requires
# additional entitlements (e.g. com.apple.security.device.audio-input).
# Without hardened runtime, NSMicrophoneUsageDescription in Info.plist
# alone is enough for TCC to prompt and add us to the Microphone allowlist.
codesign \
  --force \
  --deep \
  --sign "$SIGN_ID" \
  --identifier com.norfeldt.local-dictation \
  "$APP"

echo "Built: $APP (signed with $SIGN_ID)"
codesign --display --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
