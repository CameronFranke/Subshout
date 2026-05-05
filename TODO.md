# Shout — TODO / Plan

> Living document. Source of truth for design decisions and progress.
> Update this file as decisions change or phases complete.
> Subagents: read this top-to-bottom before doing anything.

## Vision (one paragraph)

A native macOS dictation app that replaces Superwhisper. Lives in the menu bar
(top-right system tray). Press a global hotkey → record from mic → transcribe
locally with `parakeet-mlx` (`parakeet-tdt-0.6b-v2` by default) → paste at
cursor and leave on clipboard. Distributed via GitHub Releases as an unsigned
`.app` + `.dmg`. Goal: Cameron deletes Superwhisper from his machine.

## Locked-in design decisions

| Topic | Decision |
|---|---|
| **Architecture** | Swift `.app` (UI, hotkey, audio capture, paste) + Python daemon (model, IPC over Unix socket). Daemon bundled inside `Shout.app/Contents/Resources/`. |
| **ASR engine** | `parakeet-mlx` running `mlx-community/parakeet-tdt-0.6b-v2` by default. Reuses existing `shout/asr.py`. |
| **Hotkey default** | Double-tap **left Option (⌥)**. Threshold ~300ms. Disambiguates from normal modifier usage. |
| **Hotkey rebinding** | "Click to record" UI in settings. Bare modifiers → double-tap detection; real keys/combos → single-press detection. |
| **Trigger mode** | Radio: **Toggle** (default) or **Hold-to-talk**. |
| **Floating pill** | Borderless `NSWindow`, `.statusBar` level, bottom-center ~120pt above dock. Siri-style ~12 vertical bars driven by audio RMS. |
| **Sounds** | `/System/Library/Sounds/Tink.aiff` on start, `Pop.aiff` on stop. Toggleable. |
| **Paste** | Put text on `NSPasteboard`, post ⌘V via `CGEventPost`, leave on clipboard. |
| **Model picker** | Menu bar dropdown, uses existing `shout/models.py` list. |
| **Distribution** | GitHub Releases. Unsigned `.dmg`. README includes `xattr -dr com.apple.quarantine /Applications/Shout.app` one-liner. No Apple Developer account yet. |
| **Test bench** | Delete `app.py` and the `gradio` dep. |

## Target repo layout

```
shout/
├── TODO.md                          ← this file
├── README.md                        ← rewrite for end users
├── pyproject.toml                   ← daemon-only deps, no gradio
├── uv.lock
├── shout_daemon/                    ← renamed from shout/
│   ├── __init__.py
│   ├── __main__.py                  ← entry point: `shout-daemon`
│   ├── asr.py                       ← (existing, unchanged)
│   ├── models.py                    ← (existing, unchanged)
│   ├── server.py                    ← Unix socket server, request/response loop
│   └── protocol.py                  ← IPC message schemas
├── mac/
│   ├── Shout.xcodeproj
│   └── Shout/
│       ├── ShoutApp.swift           ← @main, NSStatusItem
│       ├── DaemonClient.swift       ← spawns + talks to Python over UDS
│       ├── HotkeyManager.swift      ← CGEventTap, double-tap detection, rebinding
│       ├── AudioRecorder.swift      ← AVAudioEngine, 16kHz mono float32
│       ├── PillWindow.swift         ← floating overlay + bar visualizer
│       ├── Pasteboard.swift         ← clipboard + ⌘V synth
│       ├── Settings.swift           ← UserDefaults wrapper
│       ├── SettingsWindow.swift     ← SwiftUI settings UI
│       └── Resources/
│           └── shout-daemon/        ← bundled python env (built at packaging time)
├── scripts/
│   ├── build-daemon-bundle.sh       ← uv → standalone python bundle into mac/Shout/Resources/
│   ├── build-app.sh                 ← xcodebuild → Shout.app
│   └── make-dmg.sh                  ← .app → Shout.dmg
└── .github/workflows/
    └── release.yml                  ← tag → build → upload to Releases
```

## Files slated for deletion

- `shout/app.py` — Gradio UI
- `shout/audio.py` — superseded by Swift `AudioRecorder`
- `data/` — POC audio scratch (verify before deleting)
- `tests/` — POC tests, will rewrite for daemon
- `gradio` dep in `pyproject.toml`

## Phase plan

### Phase 0 — Housekeeping ✅
- [x] Rename `shout/` package → `shout_daemon/`
- [x] Delete `app.py`, `audio.py`
- [x] Drop `gradio` (and `sounddevice` — Swift owns mic capture now) from `pyproject.toml`; regen `uv.lock`
- [x] Update `__main__.py` to launch the daemon (placeholder, with `--smoke` sanity check)
- [x] Verify `asr.py` still loads and transcribes via `uv run shout-daemon --smoke` (load 13s, cold 1.08s, warm 54ms on M4 Pro)
- [x] Tests: update import path; non-integration tests pass.

### Phase 1 — Python daemon
- [ ] `shout_daemon/protocol.py` — message types: `LoadModel`, `Transcribe(pcm_f32_16k)`, `Status`, `Shutdown`. JSON header + length-prefixed binary payload.
- [ ] `shout_daemon/server.py` — Unix socket at `~/Library/Application Support/Shout/daemon.sock`. Single-client. Stdout/stderr → log file at `~/Library/Logs/Shout/daemon.log`.
- [ ] CLI: `shout-daemon --socket PATH --preload MODEL_ID`
- [ ] Smoke test: python client sends a WAV, gets text back

### Phase 2 — Swift app skeleton
- [ ] `mac/Shout.xcodeproj` — SwiftUI app, deployment target macOS 13+
- [ ] `NSStatusItem` with mic glyph, menu items: Record / Settings / Quit
- [ ] `DaemonClient.swift` — spawn bundled `shout-daemon`, connect over UDS, send a hardcoded WAV, log returned text
- [ ] End-to-end: launch app, click "Test transcribe", see text in logs

### Phase 3 — Audio capture
- [ ] `AudioRecorder.swift` — `AVAudioEngine` tap on input, downmix→mono, resample→16kHz, deliver float32 buffers
- [ ] Mic permission request on first run (`NSMicrophoneUsageDescription` in Info.plist)
- [ ] Manual record button in menu bar (start/stop) → end-to-end transcription

### Phase 4 — Global hotkey
- [ ] `HotkeyManager.swift` — `CGEventTap` at `cgSessionEventTap`
- [ ] Double-tap modifier detection (track flagsChanged events, timer-based)
- [ ] Single-press combo detection
- [ ] Accessibility permission request + nag if denied
- [ ] Bind default: double-tap left ⌥
- [ ] "Click to record" rebinding flow in Settings

### Phase 5 — Trigger modes
- [ ] Toggle mode: hotkey → start; hotkey again → stop
- [ ] Hold-to-talk: hotkey down → record; hotkey up → stop. Min duration ~150ms to avoid taps becoming empty recordings.
- [ ] Setting persisted in `UserDefaults`

### Phase 6 — Floating pill
- [ ] `PillWindow.swift` — borderless `NSWindow`, transparent, `.statusBar` level, ignores mouse events, all-spaces collection behavior
- [ ] SwiftUI view: 12 vertical bars, heights from a level buffer
- [ ] Hook level buffer to `AudioRecorder` RMS output (every ~33ms)
- [ ] Fade in on record start, fade out on stop

### Phase 7 — Clipboard + paste
- [ ] `Pasteboard.swift` — write text to `NSPasteboard.general`
- [ ] Synthesize ⌘V via `CGEvent` keyDown/keyUp on `kVK_ANSI_V` with maskCommand
- [ ] No clipboard restore (per decision: leave on clipboard)
- [ ] Handle paste-failed case gracefully (e.g. no focused field) — fall back to clipboard-only + brief notification

### Phase 8 — Sounds
- [ ] `NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff")` on start, `Pop.aiff` on stop
- [ ] Toggle in Settings

### Phase 9 — Settings window
- [ ] SwiftUI `Settings` scene
- [ ] Sections: Hotkey (rebind, mode), Model (picker, "Download" status), Sounds (toggle), About
- [ ] Persist via `@AppStorage` / `UserDefaults`

### Phase 10 — Packaging
- [ ] `scripts/build-daemon-bundle.sh` — produce a standalone, relocatable Python env with `parakeet-mlx` installed (probably via `uv` + `python-build-standalone`). Place at `mac/Shout/Resources/shout-daemon/`.
- [ ] `scripts/build-app.sh` — `xcodebuild` → `Shout.app`, ensure daemon bundle is copied into `Resources/`
- [ ] `scripts/make-dmg.sh` — `create-dmg` or hdiutil
- [ ] Test on a clean Mac account: launch, grant Mic + Accessibility, record, paste

### Phase 11 — Release infra
- [ ] `.github/workflows/release.yml` — on tag `v*`, run build scripts on macOS runner, attach `.dmg` to GitHub Release
- [ ] Rewrite `README.md` for end users: download, quarantine one-liner, permissions, how to use, how to rebind
- [ ] First public release: `v0.1.0`

## Open questions

*(none right now — every design decision above is locked. Add new ones here as they come up.)*

## Notes / gotchas to remember

- **First MLX call after model load is slow** (~1s on M4 Pro for 3s audio) due to kernel compilation. Daemon should `Transcribe` a tiny silence buffer immediately after `LoadModel` to pay this cost upfront — user shouldn't see it.
- **Accessibility permission** is needed for both `CGEventTap` (hotkey listening) AND `CGEventPost` (paste synth). One grant covers both.
- **Mic permission** is separate; triggered by `AVAudioEngine` first use.
- **Bundling Python in a `.app`** is the trickiest part of Phase 10. `python-build-standalone` + `uv pip install --target` into the bundle, then patch shebangs / use `sys.executable` correctly. Plan to spend real time here.
- **Unsigned `.app`** users will hit "cannot be opened" on first launch. README must give the `xattr -dr com.apple.quarantine` line.
- **Modifier-tap disambiguation:** during the double-tap window, if any non-modifier keyDown arrives, cancel the in-flight tap. This is what makes typing `é` not trigger Shout.
- **Don't fight the system Globe key (fn).** macOS reserves it; if a user tries to bind it via "record hotkey," show a polite "this key isn't supported, pick another."
- **Audio format expected by parakeet-mlx:** float32, mono, 16kHz. Confirm in `asr.py` before wiring AVAudioEngine.
- **Existing measured perf** (M4 Pro, 0.6b-v2 bf16): cold ~1.15s for 3s audio, warm ~0.08s for 3s, ~0.14s for 10s. End-to-end target: <300ms from "stop recording" to "text pasted" for typical 5s utterances.

## Status

- **Current phase:** Phase 0 complete. Repo restructured to `shout_daemon/`, Gradio gone, smoke test green. Ready for Phase 1 (Unix socket server + IPC protocol).
- **Last update:** 2026-05-05
