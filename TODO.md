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

## Handoff summary

This is **ready for another developer / agent thread to pick up**, and ready for
clone-and-run testing by a Mac user who is comfortable granting macOS privacy
permissions manually. It is **not polished public-release software yet**.

Known-good as of this handoff:

- Repo is pushed to `https://github.com/CameronFranke/Subshout`.
- `main` and `origin/main` are in sync.
- `./install.sh` builds, installs, ad-hoc signs, launches, and opens the Input
  Monitoring settings pane.
- Manual macOS permissions are still required:
  - Microphone for recording;
  - Input Monitoring for the global hotkey;
  - Accessibility for synthetic paste.
- Hotkey → record → transcribe → paste has been verified locally.
- Built-in Mac mic works.
- Bose QC35 II Bluetooth headset path works after switching capture from
  `AVAudioEngine` to `AVCaptureSession` and starting/stopping capture off the
  main actor.

Important caveats:

- The waveform / pill visualization still needs tuning. It currently feels
  jumpy / slightly behind and is intentionally left for a follow-up pass.
- There is extra diagnostic logging from the install/hotkey/audio debugging
  session. Keep it while stabilizing handoff; trim before a public release.
- `swift test` has not been run on this local machine because it only has Xcode
  Command Line Tools. Full Xcode or CI should run XCTest.
- This is not notarized and does not ship as a DMG. The supported install path
  is still `git clone && ./install.sh`.
- macOS permissions cannot be granted automatically. The installer can only
  open the relevant pane and the app can prompt/status-check; the user must
  enable permissions by hand.

## Implemented

### App behavior

- Menu-bar app with glyph status and menu actions.
- Default hotkey: double-tap left Option.
- Hotkey rebinding UI supports modifier double-taps and key combos.
- Toggle and hold-to-talk trigger modes.
- Microphone capture via `AVCaptureSession` + `AVCaptureAudioDataOutput`, using
  mono float32 PCM. This replaced the earlier `AVAudioEngine` tap path because
  Bluetooth aggregate inputs could start without delivering tap buffers.
- Capture session start/stop happens off the main actor so slow Bluetooth route
  setup/teardown does not freeze the menu-bar app.
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
- `bash -n install.sh uninstall.sh scripts/*.sh` passes.
- `./install.sh` has been run repeatedly and successfully on this machine.
- `swift test` requires full Xcode/XCTest. Local CLT-only environments fail with
  `no such module 'XCTest'`; CI/full Xcode should run it.
- Local hardware smoke currently passes: grant Mic / Input Monitoring /
  Accessibility → hotkey record → transcribe → paste.

## Before calling this public-release-ready

1. Run `cd mac && swift test --parallel` on a full-Xcode machine or verify the
   GitHub Actions Swift test job is green.
2. Tune the waveform / pill visualization:
   - reduce perceived latency;
   - reduce jumpiness;
   - keep it responsive without over-normalizing background noise.
3. Reduce debug logging added during the hotkey/audio stabilization pass. Keep
   useful failure logs, but remove noisy per-recording instrumentation if the
   capture path remains stable.
4. Test the install path on another clean macOS user account or a second Mac:
   - fresh clone;
   - `./install.sh`;
   - grant Microphone / Input Monitoring / Accessibility;
   - record with built-in mic;
   - record with Bluetooth headset if available;
   - verify paste into a normal editor.
5. Configure GitHub branch protection for `main`:
   - require PR before merge;
   - require 1 approval;
   - require CI status checks;
   - block force pushes and branch deletion.
6. Optional: add `.github/CODEOWNERS` with `* @CameronFranke` if every PR should
   request Cameron explicitly.
7. Tag the first release only after the above is green:
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
- Input Monitoring is required for the global event tap; Accessibility is
  required for synthetic paste. Microphone is separate.
- The installer cannot grant privacy permissions automatically. It can open the
  settings pane and print instructions only.
- Local unsigned/ad-hoc-signed app rebuilds can confuse TCC if the code identity
  changes. `install.sh` signs with an explicit designated requirement to keep
  permission identity stable across local rebuilds.
- The system Globe/Fn key is reserved by macOS and is rejected by the hotkey
  recorder.
- Audio sent to the daemon must be little-endian float32 mono PCM, 16 kHz.
- `SHOUT_DAEMON_CMD` is for development only; production resolves the bundled
  `Contents/Resources/shout-daemon/bin/shout-daemon`.
