# subshout

Native macOS dictation: hotkey → local Parakeet ASR → paste at cursor.
Apple Silicon only. Everything runs on-device: no accounts, no cloud, no
telemetry.

## Install

```bash
git clone git@github.com:CameronFranke/Subshout.git
cd Subshout
./install.sh
```

`install.sh` builds a relocatable Python daemon bundle, builds
`subshout.app`, copies it to `/Applications`, strips quarantine metadata,
ad-hoc signs when possible, and launches the app. First install can take
several minutes because it builds the bundled Python environment. The first
recording may also download Parakeet weights (~1.2 GB).

Grant **Microphone** and **Accessibility** when macOS asks. Default hotkey:
**double-tap left ⌥ (Option)**. Rebind it from the menu bar icon → Settings →
Hotkey.

For a non-launching install smoke test, use `./install.sh --no-launch`.

Uninstall:

```bash
./uninstall.sh
```

Use `./uninstall.sh --purge` only if you also want to remove cached Parakeet
model weights from `~/.cache/huggingface`.

## Requirements

- macOS 13 Ventura or newer
- Apple Silicon Mac (M1 or newer)
- Xcode command-line tools (`xcode-select --install`)
- [`uv`](https://github.com/astral-sh/uv)
- Disk space: roughly 1.5–2 GB for the bundled app plus ~1.2 GB for model
  weights downloaded on first model load

## What it does

Press the hotkey to start recording, speak, press again to stop. subshout
captures microphone audio, transcribes it locally with NVIDIA Parakeet via
[`parakeet-mlx`](https://github.com/senstella/parakeet-mlx), writes the text to
the clipboard, and posts ⌘V into the frontmost app.

Default trigger mode is **toggle**. Settings also support **hold-to-talk**,
custom hotkeys, model selection, start/stop sounds, login-item control, and
resetting the floating level pill position.

## Permissions

macOS asks for two permissions:

- **Microphone** — used only while a recording is active. The CoreAudio engine
  is torn down after each take so Control Center should show the mic released
  within about a second.
- **Accessibility** — required for the global hotkey event tap and for posting
  ⌘V. subshout listens for the configured hotkey and does not modify normal key
  events.

If you grant Accessibility after the app is already running, click the menu bar
icon → **Re-install hotkey listener**.

## Troubleshooting

**Hotkey does nothing after granting Accessibility.**  Re-install the hotkey
listener from the menu bar icon. macOS often requires the event tap to be
re-armed after permission changes.

**First recording is slow.**  The selected Parakeet model downloads on first
use, then the daemon warms it with a short silence transcription. Subsequent
recordings should be fast.

**It pasted into the wrong app.**  subshout pastes into whatever app is
frontmost when transcription finishes, the same as pressing ⌘V yourself. The
transcript remains on the clipboard so you can paste again manually.

**The pill is in a weird place.**  Drag it where you want it, or use menu bar
icon → Reset pill position.

**Daemon will not start.**  Check `~/Library/Logs/subshout/daemon.log`, then try
Restart daemon from the menu. Re-run `./install.sh` if the bundled daemon is
missing or corrupt.

## Paths

| Item | Path |
|---|---|
| Installed app | `/Applications/subshout.app` |
| Python daemon log | `~/Library/Logs/subshout/daemon.log` |
| Swift app log | Console.app subsystem `com.cameronfranke.SubShout` |
| Daemon socket | `~/Library/Application Support/subshout/daemon.sock` |
| User defaults | `defaults read com.cameronfranke.SubShout` |
| Bundled daemon | `/Applications/subshout.app/Contents/Resources/shout-daemon/` |

## Development

Useful commands:

```bash
uv sync
uv run pytest -m 'not integration'
cd mac && swift build --product SubShout
cd .. && scripts/run-dev.sh
```

Swift unit tests require full Xcode because they import XCTest:

```bash
cd mac && swift test --parallel
```

The production install path is:

```bash
./install.sh
```

Project status, remaining release work, and maintenance notes live in
[`TODO.md`](TODO.md). CI runs Python tests, Swift build/tests, and shellcheck on
push/PR.

## Architecture

```
┌────────────────────┐   spawn     ┌──────────────────────┐
│   subshout.app     │ ───────────▶│ shout-daemon (Python)│
│   Swift / SwiftUI  │             │ parakeet-mlx + MLX   │
│                    │ ◀── UDS ───▶│ asyncio server       │
└────────────────────┘ framed JSON └──────────────────────┘
       │                                          ▲
       │ AVAudioEngine                            │
       │ → 16 kHz mono float32 PCM ───────────────┘
```

Wire protocol: 4-byte big-endian header length → UTF-8 JSON header containing
`payload_len` → optional binary payload. See
[`shout_daemon/protocol.py`](shout_daemon/protocol.py) and
[`mac/Sources/SubShout/WireProtocol.swift`](mac/Sources/SubShout/WireProtocol.swift).

## Naming

User-facing name: **subshout**. Internal identifiers keep camel/snake case:
bundle ID `com.cameronfranke.SubShout`, Swift target `SubShout`, Python package
`shout_daemon`, Python CLI `shout-daemon`.

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx) by Senstella
- NVIDIA Parakeet TDT model weights
- [`mlx-community`](https://huggingface.co/mlx-community) MLX ports
- [`python-build-standalone`](https://github.com/indygreg/python-build-standalone)
