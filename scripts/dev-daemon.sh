#!/usr/bin/env bash
# Dev wrapper for the Python daemon.  The Swift app launches this via
# `SHOUT_DAEMON_CMD=path/to/dev-daemon.sh` so we don't need a full bundled
# Python env during development.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
exec uv run shout-daemon "$@"
