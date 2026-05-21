#!/usr/bin/env bash
# subshout uninstaller. Removes the .app, per-user support/log directories,
# persisted UserDefaults, and (optionally) Parakeet weights from the
# HuggingFace cache.
#
# Usage:
#   ./uninstall.sh              # standard uninstall
#   ./uninstall.sh --dry-run    # show what would be removed, do nothing
#   ./uninstall.sh --purge      # also remove parakeet weights from ~/.cache/huggingface
#   ./uninstall.sh --dry-run --purge

set -euo pipefail

PURGE=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --purge)   PURGE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,9p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

APP="/Applications/subshout.app"
APP_SUPPORT="$HOME/Library/Application Support/subshout"
LOGS="$HOME/Library/Logs/subshout"
BUNDLE_ID="com.cameronfranke.SubShout"
HF_HUB="$HOME/.cache/huggingface/hub"

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> DRY RUN — no files will be touched"
fi

# 1) Quit the running app first. SMAppService unregisters automatically when the
#    .app bundle disappears, but only after the app process has exited.
echo "==> stopping subshout if it's running"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] osascript -e 'tell application \"subshout\" to quit'"
else
    osascript -e 'tell application "subshout" to quit' 2>/dev/null || true
fi
sleep 1

# 2) Remove the .app.
if [[ -d "$APP" ]]; then
    echo "==> removing $APP"
    run rm -rf -- "${APP:?}"
else
    echo "==> $APP not present (nothing to remove)"
fi

# 3) Per-user state (socket dir, logs).
if [[ -d "$APP_SUPPORT" ]]; then
    echo "==> removing $APP_SUPPORT"
    run rm -rf -- "${APP_SUPPORT:?}"
else
    echo "==> $APP_SUPPORT not present"
fi

if [[ -d "$LOGS" ]]; then
    echo "==> removing $LOGS"
    run rm -rf -- "${LOGS:?}"
else
    echo "==> $LOGS not present"
fi

# 4) UserDefaults. Removing the .app drops the SMAppService login-item
#    registration automatically; we just clear persisted preferences.
echo "==> clearing UserDefaults ($BUNDLE_ID)"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] defaults delete $BUNDLE_ID"
else
    defaults delete "$BUNDLE_ID" 2>/dev/null || true
fi

# 5) Optional: nuke Parakeet weights from the HuggingFace cache.
if [[ "$PURGE" -eq 1 ]]; then
    echo "==> --purge: removing parakeet model weights from HuggingFace cache"
    if [[ -d "$HF_HUB" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "[dry-run] find $HF_HUB -maxdepth 1 -type d -iname '*parakeet*' -exec rm -rf {} +"
        else
            find "$HF_HUB" -maxdepth 1 -type d -iname '*parakeet*' -exec rm -rf {} + 2>/dev/null || true
        fi
    else
        echo "==> $HF_HUB not present (nothing to purge)"
    fi
fi

# 6) Verify. If we're not in dry-run, confirm the app/state paths are gone so
#    the user gets a clear pass/fail signal at the end.
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ -d "$APP" ]] || [[ -d "$APP_SUPPORT" ]] || [[ -d "$LOGS" ]]; then
        echo
        echo "WARNING: some paths are still present after uninstall:" >&2
        [[ -d "$APP" ]]         && echo "  $APP" >&2
        [[ -d "$APP_SUPPORT" ]] && echo "  $APP_SUPPORT" >&2
        [[ -d "$LOGS" ]]        && echo "  $LOGS" >&2
        echo "(check permissions or remove them by hand)" >&2
        exit 1
    fi
fi

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "==> dry run complete (nothing was actually removed)"
else
    echo "==> done"
    echo
    echo "Login Item registration was removed automatically when the .app was deleted."
    echo "If you also want to remove the source checkout, remove this directory by hand."
fi
