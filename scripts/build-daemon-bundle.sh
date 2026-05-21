#!/usr/bin/env bash
# Build a relocatable Python environment + shout_daemon + parakeet-mlx,
# and stage it at mac/Resources/shout-daemon/.  The .app bundle includes
# this directory under Contents/Resources/ so the released app can run
# the daemon without any system Python or uv on the user's machine.
#
# Layout produced:
#
#   mac/Resources/shout-daemon/
#     ├── bin/
#     │   ├── python3                ← symlink into the standalone interpreter
#     │   └── shout-daemon           ← shim that runs `python3 -m shout_daemon`
#     ├── interpreter/               ← python-build-standalone tarball, extracted
#     │   ├── bin/python3.12
#     │   └── lib/...
#     └── site-packages/             ← `uv pip install --target` output
#         ├── shout_daemon/
#         ├── parakeet_mlx/
#         ├── mlx/
#         └── ...
#
# The shim in bin/shout-daemon prepends our site-packages onto PYTHONPATH
# and exec's the bundled interpreter.  Because the interpreter is a
# python-build-standalone tarball — designed to be relocatable — and our
# site-packages directory contains no compiled-in absolute paths (we
# strip __pycache__ and verify), the whole bundle is movable: works in
# the dev tree, works inside /Applications/subshout.app/Contents/Resources.
#
# Re-runs are idempotent + cached.  The python-build-standalone tarball
# is cached under .cache/ so iterating on dependency lists doesn't
# re-download a 50 MB interpreter every time.
#
# Usage: scripts/build-daemon-bundle.sh [--clean]
#
#   --clean   wipe and rebuild from scratch (still uses the cached tarball)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="$REPO_ROOT/.cache/build-daemon-bundle"
BUNDLE_DIR="$REPO_ROOT/mac/Resources/shout-daemon"

PY_VERSION="3.12.7"
# python-build-standalone release that ships 3.12.7 for aarch64-apple-darwin.
# Keep this pinned.  When you bump it: read the release notes for any
# packaging changes (PEP 668, install layout, etc.).
PBS_RELEASE="20241016"
PBS_ARCHIVE="cpython-${PY_VERSION}+${PBS_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
PBS_URL="https://github.com/indygreg/python-build-standalone/releases/download/${PBS_RELEASE}/${PBS_ARCHIVE}"
PBS_SHA256="" # optional; if set we'll verify

CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "this script only runs on macOS (Apple Silicon)" >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "subshout is Apple Silicon only; this machine is $(uname -m)" >&2
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "this script requires 'uv' (https://github.com/astral-sh/uv) on PATH" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
    echo "==> --clean: removing $BUNDLE_DIR"
    rm -rf -- "${BUNDLE_DIR:?}"
fi

# ----------------------------------------------------------------- 1) interpreter

ARCHIVE_PATH="$CACHE_DIR/$PBS_ARCHIVE"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
    echo "==> downloading python-build-standalone ${PY_VERSION}+${PBS_RELEASE}"
    curl -fL --retry 3 -o "$ARCHIVE_PATH.tmp" "$PBS_URL"
    mv "$ARCHIVE_PATH.tmp" "$ARCHIVE_PATH"
else
    echo "==> using cached interpreter tarball at $ARCHIVE_PATH"
fi

if [[ -n "$PBS_SHA256" ]]; then
    echo "==> verifying sha256"
    echo "$PBS_SHA256  $ARCHIVE_PATH" | shasum -a 256 -c -
fi

INTERP_DIR="$BUNDLE_DIR/interpreter"
if [[ ! -x "$INTERP_DIR/bin/python3" ]]; then
    echo "==> extracting interpreter to $INTERP_DIR"
    rm -rf -- "${INTERP_DIR:?}"
    mkdir -p "$INTERP_DIR"
    # The tarball contains a top-level `python/` directory; strip it.
    tar -xzf "$ARCHIVE_PATH" -C "$INTERP_DIR" --strip-components=1
fi

# Sanity check: interpreter runs and reports the expected version.
INTERP_BIN="$INTERP_DIR/bin/python3"
if [[ ! -x "$INTERP_BIN" ]]; then
    echo "interpreter not at $INTERP_BIN — extraction layout changed?" >&2
    exit 1
fi
ACTUAL_VERSION="$("$INTERP_BIN" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
if [[ "$ACTUAL_VERSION" != "$PY_VERSION" ]]; then
    echo "WARNING: extracted interpreter is $ACTUAL_VERSION, expected $PY_VERSION"
fi

# ----------------------------------------------------------------- 2) site-packages

SITE_PACKAGES="$BUNDLE_DIR/site-packages"
echo "==> installing dependencies into $SITE_PACKAGES"
rm -rf -- "${SITE_PACKAGES:?}"
mkdir -p "$SITE_PACKAGES"

# Install:
#   * parakeet-mlx (and its transitive deps: mlx, numpy, huggingface-hub, ...)
#   * the local `shout-daemon` package itself (so `python -m shout_daemon` works)
#
# `--python` pins uv to the bundled interpreter so the wheels installed
# match its ABI (cp312-cp312-macosx_*_arm64).  `--target` writes everything
# into a flat site-packages dir we can ship.
( cd "$REPO_ROOT" && uv pip install \
    --python "$INTERP_BIN" \
    --target "$SITE_PACKAGES" \
    --no-cache \
    "parakeet-mlx>=0.5.1" \
    "numpy>=2.0" \
    "soundfile>=0.13.1" \
    "$REPO_ROOT" )

# ----------------------------------------------------------------- 3) shrink

# __pycache__ directories embed absolute paths and mutate after codesigning.
# Strip them from both the standalone interpreter and site-packages; the shim
# also sets PYTHONDONTWRITEBYTECODE so they are not recreated inside the .app.
echo "==> stripping __pycache__"
find "$BUNDLE_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

# Examples / tests live inside several wheels (huggingface_hub, numpy
# stub data, etc.) and add tens of MB.  Trim conservatively — we only
# touch top-level dirs that are clearly "non-runtime".
for trash in \
    "$SITE_PACKAGES"/*/tests \
    "$SITE_PACKAGES"/*/test \
    "$SITE_PACKAGES"/*/examples \
    "$SITE_PACKAGES"/*/docs \
; do
    [[ -d "$trash" ]] && rm -rf "$trash"
done

# ----------------------------------------------------------------- 4) shim

mkdir -p "$BUNDLE_DIR/bin"

# The shim sets up PYTHONPATH and exec's the bundled interpreter.  Using
# $0's directory means the bundle is fully relocatable — works as
# /Applications/subshout.app/Contents/Resources/shout-daemon/bin/shout-daemon
# or under the dev tree, identical script.
cat > "$BUNDLE_DIR/bin/shout-daemon" <<'EOF'
#!/bin/bash
# Auto-generated by scripts/build-daemon-bundle.sh.  Do not edit by hand.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$HERE/.." && pwd)"
export PYTHONPATH="$BUNDLE/site-packages"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
# Don't let a system PYTHONHOME / pyenv / venv leak in.
unset PYTHONHOME
exec "$BUNDLE/interpreter/bin/python3" -m shout_daemon "$@"
EOF
chmod +x "$BUNDLE_DIR/bin/shout-daemon"

# Convenience symlink so a curious user can poke `bin/python3 -V`.
ln -sf "../interpreter/bin/python3" "$BUNDLE_DIR/bin/python3"

# ----------------------------------------------------------------- 5) verify

echo "==> verifying relocatability (no dev-machine paths leaked)"
# `grep -RIl /Users/` is a cheap canary: any matches mean we baked a
# build-time path into the bundle.  The interpreter itself ships `*.pyi`
# stubs that may contain `/Users` in docstrings — we only flag .pth /
# .py / .so / RECORD files which are what would actually load at runtime.
LEAKS=$(grep -RIl --include="*.pth" --include="*.py" --include="RECORD" \
    "$HOME" "$BUNDLE_DIR/site-packages" 2>/dev/null || true)
if [[ -n "$LEAKS" ]]; then
    echo "WARNING: dev-machine paths found in:" >&2
    echo "$LEAKS" >&2
    echo "(this is sometimes false-positive; verify by hand)" >&2
fi

echo "==> smoke-testing the bundle"
# Run the daemon's --version flag.  This exercises:
#   - the shim resolves $HERE correctly
#   - PYTHONPATH lets it import shout_daemon
#   - parakeet_mlx imports cleanly (transitively pulled by shout_daemon)
# We do NOT load a model here — that takes >1GB of network.  Model load
# is exercised by `pytest -m integration`.
"$BUNDLE_DIR/bin/shout-daemon" --version

# The smoke test imports Python modules; keep the final bundle bytecode-free so
# ad-hoc signing remains valid after install.
find "$BUNDLE_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$BUNDLE_DIR" -type f -name "*.pyc" -delete 2>/dev/null || true

# ----------------------------------------------------------------- 6) report

du -sh "$BUNDLE_DIR" 2>/dev/null || true
echo "==> bundle ready: $BUNDLE_DIR"
