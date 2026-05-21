#!/usr/bin/env bash
# Build a debug subshout.app and launch it pointing at the dev daemon
# wrapper (uv run shout-daemon).
#
# First run will:
#   1) ask for Microphone permission (system dialog)
#   2) ask for Accessibility permission (you'll need to add subshout in
#      System Settings → Privacy & Security → Accessibility, then use
#      the menu's "Re-install hotkey listener")
#   3) download Parakeet weights (~1.2 GB the first time)
#
# Logs:
#   ~/Library/Logs/subshout/daemon.log               — Python daemon
#   Console.app, subsystem=com.cameronfranke.SubShout — Swift app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$REPO_ROOT/scripts/build-app.sh" debug

export SHOUT_DAEMON_CMD="$REPO_ROOT/scripts/dev-daemon.sh"
echo "==> SHOUT_DAEMON_CMD=$SHOUT_DAEMON_CMD"
echo "==> launching $REPO_ROOT/build/subshout.app"
exec "$REPO_ROOT/build/subshout.app/Contents/MacOS/SubShout"
