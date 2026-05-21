#!/usr/bin/env bash
# Build subshout.app from the SwiftPM target.
#
# Usage: scripts/build-app.sh [debug|release]
#
# Output: build/subshout.app
#
# In dev, run with SHOUT_DAEMON_CMD pointing at scripts/dev-daemon.sh.
# For a real distributable .app, run scripts/build-daemon-bundle.sh first
# (or use install.sh, which chains them) — that drops a relocatable
# Python env at mac/Resources/shout-daemon/, which this script copies
# into Contents/Resources/shout-daemon/.
#
# Display name is intentionally lowercase ("subshout"); the Swift target
# / binary stays camel-case ("SubShout") because that's an internal
# identifier never shown to the user.
set -euo pipefail

CONFIG="${1:-debug}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_DIR="$REPO_ROOT/mac"
BUILD_DIR="$REPO_ROOT/build"
APP="$BUILD_DIR/subshout.app"
DAEMON_BUNDLE="$MAC_DIR/Resources/shout-daemon"

cd "$MAC_DIR"
echo "==> swift build -c $CONFIG --product SubShout"
swift build -c "$CONFIG" --product SubShout

BINARY="$MAC_DIR/.build/$CONFIG/SubShout"
if [[ ! -f "$BINARY" ]]; then
    echo "build failed: expected binary at $BINARY" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf -- "${APP:?}"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/SubShout"
chmod +x "$APP/Contents/MacOS/SubShout"
cp "$MAC_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"

# Copy the bundled daemon if it exists.  In dev (run-dev.sh) this dir
# won't be present and the app will fall back to SHOUT_DAEMON_CMD.
if [[ -d "$DAEMON_BUNDLE" ]]; then
    echo "==> copying bundled daemon: $DAEMON_BUNDLE → $APP/Contents/Resources/shout-daemon"
    cp -R "$DAEMON_BUNDLE" "$APP/Contents/Resources/shout-daemon"
else
    echo "==> (no bundled daemon at $DAEMON_BUNDLE; .app will need SHOUT_DAEMON_CMD)"
fi

# Strip the quarantine xattr from anything we just produced.  Not
# strictly needed when the user runs this script themselves (no quarantine
# is applied to locally-built files), but harmless and makes the bundle
# easier to move around afterwards.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "==> $APP"
