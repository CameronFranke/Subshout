# Shout

Native macOS dictation app. Push-to-talk hotkey → local Parakeet ASR → paste at cursor.
Aiming to replace Superwhisper.

**Status:** under construction. See [`TODO.md`](./TODO.md) for the design and
phase plan. The end-user README will land at Phase 11.

## Repo layout (during development)

- `shout_daemon/` — Python package. Loads `parakeet-mlx`, will serve over a
  Unix socket. CLI: `uv run shout-daemon --smoke` for a Phase 0 sanity check.
- `mac/` — Swift `.app` (not yet started).
- `tests/` — daemon tests.

## Phase 0 sanity check

```bash
uv sync
uv run shout-daemon --smoke
```

Expect: model load (~5–15s first time, downloads weights), then a cold
transcription (~1s) and a warm one (<100ms) of 1s of silence. Output text
will be empty — that's fine; we're verifying the pipeline, not the model.
