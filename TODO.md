# subshout TODO / state

Last updated: 2026-05-21

## Current state

subshout is a native macOS menu-bar dictation app for Apple Silicon:

1. Swift app captures mic audio, handles global hotkey/settings/pill UI, writes
   transcripts to the pasteboard, and posts ⌘V.
2. Python daemon serves Parakeet MLX transcription over a Unix-domain socket.
3. Clone-and-run install path builds a bundled Python daemon and installs
   `/Applications/subshout.app`.

The old Phase 0–11 planning docs were consolidated here. This file is now the
single project status / TODO document; README.md is for end users.

## Implemented

### App behavior

- Menu-bar app with glyph status and menu actions.
- Default hotkey: double-tap left Option.
- Hotkey rebinding UI supports modifier double-taps and key combos.
- Toggle and hold-to-talk trigger modes.
- Per-recording `AVAudioEngine` lifecycle so the mic releases after each take.
- Live floating level pill with spectrum bars and resettable position.
- Start/stop sounds using system Tink/Pop sounds.
- Pasteboard write + synthetic ⌘V paste, with auto-paste skipped when subshout
  itself is frontmost.
- Settings window for hotkey, trigger mode, model, sounds, and login item.
- Login item support through `SMAppService.mainApp`.

### Python daemon

- `shout_daemon/protocol.py`: framed JSON + optional binary payload.
- `shout_daemon/server.py`: asyncio Unix socket server, single-client guard,
  stale-socket cleanup, socket permissions, status/load/transcribe/shutdown.
- `shout_daemon/asr.py`: Parakeet wrapper pinned to one MLX worker thread.
- Daemon binds the socket before preloading so the app can poll readiness during
  first-run model download.
- Warmup transcription after model load to pay the first MLX compile cost before
  the user's first real take.

### Packaging / repo

- User-facing rename landed as `subshout`.
- Internal identifiers remain `SubShout`, `shout_daemon`, and `shout-daemon`.
- `install.sh` / `uninstall.sh` at repo root.
- `scripts/build-daemon-bundle.sh`: python-build-standalone + `uv pip install
  --target` bundle at `mac/Resources/shout-daemon/`.
- `scripts/build-app.sh`: SwiftPM build → `build/subshout.app`, copying the
  daemon bundle when present.
- `scripts/run-dev.sh`: debug app with `SHOUT_DAEMON_CMD=scripts/dev-daemon.sh`.
- MIT license.
- GitHub Actions CI for Python tests, Swift build/tests, and shellcheck.

## Verification snapshot

Commands that should be green before a release:

```bash
uv run pytest -m 'not integration'
cd mac && swift build --product SubShout
cd mac && swift test --parallel       # requires full Xcode, not just CLT
bash -n install.sh uninstall.sh scripts/*.sh
./install.sh                          # slow/full end-to-end install path
```

Current local notes:

- `uv run pytest -m 'not integration'` passes.
- `swift build --product SubShout` passes with Command Line Tools.
- `./install.sh --no-launch` builds the daemon bundle, builds release app,
  installs to `/Applications`, ad-hoc signs, and verifies after running the
  bundled daemon `--version`.
- `swift test` requires full Xcode/XCTest. Local CLT-only environments fail with
  `no such module 'XCTest'`; CI/full Xcode should run it.
- The final hardware smoke test is still required after launching the installed
  app: grant Mic/Accessibility → record → transcribe → paste → quit/relaunch.

## Before v0.1.0

1. Launch `/Applications/subshout.app` and verify model download, Mic /
   Accessibility prompts, recording, paste, and login-item toggle.
2. Verify Swift tests on a full-Xcode machine or in CI.
3. Push to `git@github.com:CameronFranke/Subshout.git`.
4. Configure GitHub branch protection for `main`:
   - require PR before merge;
   - require 1 approval;
   - require CI status checks;
   - block force pushes and branch deletion.
5. Optional: add `.github/CODEOWNERS` with `* @CameronFranke` if you want every
   PR to request you explicitly.
6. Tag the first release after the install/hardware smoke test passes:
   `git tag v0.1.0 && git push origin main --tags`.

## Deferred / intentionally skipped

- DMG and GitHub Release asset workflow. Clone-and-run is the only v0.1 install
  path for now. If this becomes worth doing, add `scripts/make-dmg.sh` and a
  tag-triggered release workflow.
- App icon (`mac/Resources/AppIcon.icns` + `CFBundleIconFile`). Without this,
  Finder/Dock use the generic app icon when Settings is visible.
- `CONTRIBUTING.md`. Not needed until outside contributions are expected.
- Notarization / Developer ID signing. Current path is local build + quarantine
  stripping + best-effort ad-hoc signing.

## Repo hygiene rules

- Do not commit `data/`; those are local Pi/session artifacts.
- Do not commit `mac/Resources/shout-daemon/`; it is a generated ~GB-scale
  daemon bundle.
- Do not commit `build/`, `mac/.build/`, `.venv/`, `.cache/`, `__pycache__/`, or
  pytest cache directories.
- Keep README.md user-facing. Put implementation state and release TODOs here.

## Gotchas

- macOS Unix socket paths are short. Tests use `/tmp/subshout-test-*` paths so
  server tests do not skip under long pytest temp directories.
- `AVAudioEngine.stop()` alone does not release the mic; the recorder must drop
  the engine/converter/format objects between recordings.
- Input Monitoring is required for the global event tap; Accessibility is
  required for synthetic paste.
- The system Globe/Fn key is reserved by macOS and is rejected by the hotkey
  recorder.
- Audio sent to the daemon must be little-endian float32 mono PCM, 16 kHz.
- `SHOUT_DAEMON_CMD` is for development only; production resolves the bundled
  `Contents/Resources/shout-daemon/bin/shout-daemon`.
