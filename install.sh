#!/usr/bin/env bash
# subshout installer.
#
#   git clone https://github.com/CameronFranke/Subshout
#   cd Subshout
#   ./install.sh
#
# Builds a relocatable Python env + shout_daemon, builds the Swift app,
# assembles subshout.app, copies it to /Applications, ad-hoc signs it,
# and launches it unless --no-launch is passed. Registers a Login Item
# on first launch (toggle in Settings → About if you want to opt out).

set -euo pipefail

LAUNCH=1
for arg in "$@"; do
    case "$arg" in
        --no-launch) LAUNCH=0 ;;
        -h|--help)
            cat <<'EOF'
Usage: ./install.sh [--no-launch]

Builds a relocatable Python daemon bundle, builds subshout.app, installs it to
/Applications, strips quarantine metadata, and ad-hoc signs when possible.

Options:
  --no-launch   install/codesign the app but do not open it
EOF
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="subshout.app"
DEST="/Applications/$APP_NAME"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "subshout is macOS-only." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "subshout is Apple Silicon only (this machine is $(uname -m))." >&2
    exit 1
fi

# Tooling preflight.  Each missing piece gets a clear hint.
missing=()
command -v swift >/dev/null 2>&1 || missing+=("swift (run: xcode-select --install)")
command -v uv    >/dev/null 2>&1 || missing+=("uv    (run: brew install uv  OR  curl -LsSf https://astral.sh/uv/install.sh | sh)")
command -v curl  >/dev/null 2>&1 || missing+=("curl")
if (( ${#missing[@]} )); then
    echo "Missing required tools:" >&2
    for m in "${missing[@]}"; do echo "  • $m" >&2; done
    exit 1
fi

chmod +x "$REPO/scripts/"*.sh "$REPO/install.sh" "$REPO/uninstall.sh" 2>/dev/null || true

echo "==> Building daemon bundle (downloads ~50 MB of standalone Python the first time)..."
"$REPO/scripts/build-daemon-bundle.sh"

echo "==> Building subshout.app..."
"$REPO/scripts/build-app.sh" release

echo "==> Installing to /Applications..."
# If a previous subshout is running, ask it to quit so we can replace it.
# LSUIElement apps do not always answer AppleScript reliably, so fall back to
# terminating the process by executable name before copying the new bundle.
osascript -e 'tell application "subshout" to quit' 2>/dev/null || true
sleep 1
if pgrep -x SubShout >/dev/null 2>&1; then
    pkill -x SubShout 2>/dev/null || true
    sleep 1
fi
rm -rf -- "${DEST:?}"
cp -R "$REPO/build/$APP_NAME" "$DEST"

# Strip the quarantine xattr.  Locally-built apps don't actually carry
# it, but `cp -R` from a downloaded source tree might preserve some
# stragglers (e.g. on the bundled Python interpreter).
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Ad-hoc sign the local build when codesign is available. This does not require
# an Apple Developer account, but it avoids a class of Gatekeeper/library-load
# complaints when the bundled Python imports native `.so` extensions. The
# explicit designated requirement keeps the app's TCC identity stable across
# local rebuilds; the default ad-hoc requirement is just a cdhash, which changes
# every install and makes Accessibility/Input Monitoring appear enabled while
# still not matching the current binary.
if command -v codesign >/dev/null 2>&1; then
    echo "==> Ad-hoc signing..."
    if ! codesign \
        --force \
        --deep \
        --sign - \
        --identifier com.cameronfranke.SubShout \
        --requirements '=designated => identifier "com.cameronfranke.SubShout"' \
        "$DEST"; then
        echo "WARNING: ad-hoc signing failed; continuing because this is a local unsigned build." >&2
    fi
fi

if [[ "$LAUNCH" -eq 1 ]]; then
    echo "==> Launching..."
    open "$DEST"
    echo "==> Opening Input Monitoring settings (enable subshout if prompted/listed)..."
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent' || true
else
    echo "==> Installed; skipping launch (--no-launch)."
fi

cat <<'EOF'

────────────────────────────────────────────────────────────────────
subshout is now installed.

  • Microphone:   accept the system prompt the first time you record.
  • Input Monitoring: open System Settings → Privacy & Security →
    Input Monitoring, enable subshout.  (Needed for the global hotkey.)
  • Accessibility: open System Settings → Privacy & Security →
    Accessibility, enable subshout.  (Needed for synthesizing ⌘V to paste.)
  • After granting either permission, click the menu-bar icon →
    "Re-install hotkey listener".
  • Default hotkey: double-tap left ⌥ (Option).  Change it in
    Settings (⌘, from the menu bar).
  • subshout starts automatically on login.  Toggle this in
    Settings → About, or in System Settings → General → Login Items.

Logs:    ~/Library/Logs/subshout/daemon.log
Socket:  ~/Library/Application Support/subshout/daemon.sock

To uninstall:  ./uninstall.sh
────────────────────────────────────────────────────────────────────
EOF
