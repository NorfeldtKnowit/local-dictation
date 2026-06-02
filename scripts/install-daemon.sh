#!/usr/bin/env bash
# Installs local-dictation as a per-user LaunchAgent. Points at the
# binary inside dist/local-dictation.app so launchd inherits the app's
# bundle identity (and the TCC grants attached to it).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/local-dictation.app"
BIN="$APP/Contents/MacOS/local-dictation"
LABEL="com.norfeldt.local-dictation"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ ! -x "$BIN" ]; then
  echo "App not installed at $APP" >&2
  echo "Run:  swift build -c release  &&  scripts/build-app.sh  &&  scripts/install-app.sh" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
mkdir -p "$HOME/Library/Logs"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/local-dictation.out.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/local-dictation.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl enable "gui/$(id -u)/$LABEL"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed LaunchAgent: $PLIST"
echo "Pointing at: $BIN"
launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|path)' | sed 's/^/  /'
