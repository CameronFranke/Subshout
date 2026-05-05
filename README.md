# Shout — Parakeet test bench

A tiny browser UI for trying out NVIDIA Parakeet ASR models locally on Apple
Silicon via [`parakeet-mlx`](https://github.com/senstella/parakeet-mlx).

This is **step 1** of the larger plan to build a Superwhisper replacement —
just a simple "click record, see what comes out" sandbox so we can compare
models and feel the latency.

## Run

```bash
uv run shout
```

That opens `http://127.0.0.1:7860` in your browser. Pick a model from the
dropdown, click **Load model**, then use the microphone widget to record and
see the transcript.

Useful flags:

```bash
uv run shout --port 7870
uv run shout --no-browser                                        # don't auto-open a tab
uv run shout --preload mlx-community/parakeet-tdt-0.6b-v2        # warm the model at startup
```

First run for a given model downloads weights from HuggingFace
(~600 MB for the 0.6B models, ~2 GB for the 1.1B ones) into the standard
HF cache (`~/.cache/huggingface`).

## Models included

| HF id | Notes |
|---|---|
| `mlx-community/parakeet-tdt-0.6b-v2` | **Default.** English, ~600M, top of OpenASR leaderboard for size. |
| `mlx-community/parakeet-tdt-0.6b-v3` | Newer, multilingual. v2 usually preferred for English-only. |
| `mlx-community/parakeet-tdt-1.1b` | Larger, slightly better WER, ~2× memory and latency. |
| `mlx-community/parakeet-rnnt-1.1b` | RNN-T variant for comparison. |
| `mlx-community/parakeet-tdt_ctc-110m` | Tiny + fastest, noticeably worse WER. |

You can also paste any other HF model id into the dropdown (it accepts custom
values).

## Measured perf on this machine (M4 Pro)

For `mlx-community/parakeet-tdt-0.6b-v2`, bf16:

| Clip length | Cold (first call, kernel compile) | Warm |
|---|---|---|
| 3s | ~1.15s (≈ 2.6× RTFx) | ~0.08s (≈ 36× RTFx) |
| 10s | — | ~0.14s (≈ 70× RTFx) |

The first transcription after loading is slow because MLX has to compile its
kernels; the daemon-style design (model stays resident) means subsequent
transcriptions are fast.

## Layout

```
shout/
├── shout/
│   ├── app.py        # Gradio UI + handlers
│   ├── asr.py        # ParakeetASR wrapper (load + transcribe ndarray)
│   ├── audio.py      # Mic helpers (kept for the daemon stage)
│   └── models.py     # Curated model list
└── pyproject.toml
```

## Notes / quirks

- We bypass `parakeet-mlx`'s own audio file loader (which shells out to
  ffmpeg) and feed the model a numpy array directly via `get_logmel` +
  `model.generate`. So **no ffmpeg dependency**.
- Gradio resamples mic audio to 16 kHz on the client; we double-check on the
  server using `soxr` if needed.
- The model stays loaded between recordings — only the first transcription
  pays the kernel-compile tax.

## Next steps (per the design discussion)

1. ✅ Test bench (this).
2. Daemon mode: global hotkey, push-to-talk, paste at cursor.
3. Optional regex/dictionary jargon substitution layer.
4. Optional small-LLM cleanup pass (Qwen 1.5B / Llama 3.2 1B via mlx-lm),
   bound to a separate hotkey.
