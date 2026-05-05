"""Gradio UI for trying out Parakeet ASR models.

Run with:
    uv run shout
or:
    uv run python -m shout
"""

from __future__ import annotations

import argparse
import time

import gradio as gr
import numpy as np

from .asr import ParakeetASR
from .models import MODELS, by_id


# Single shared ASR instance — keeps the model resident between recordings.
_ASR = ParakeetASR()
_LOADED_AT: float | None = None


def _model_choices() -> list[tuple[str, str]]:
    # (label, value) so the dropdown shows the friendly label but stores hf_id
    return [(m.label, m.hf_id) for m in MODELS]


def describe(hf_id: str) -> str:
    info = by_id(hf_id)
    if info is None:
        return "_(custom model id)_"
    return info.description


def load_model(hf_id: str) -> str:
    global _LOADED_AT
    hf_id = (hf_id or "").strip()
    if not hf_id:
        return "❌ Please choose or enter a model id."
    try:
        t0 = time.perf_counter()
        dt = _ASR.load(hf_id)
        wall = time.perf_counter() - t0
        _LOADED_AT = time.time()
        # If the model was already loaded, dt == cached load time, wall ≈ 0
        if wall < 0.05 and _ASR.model_id == hf_id:
            return f"✅ **{hf_id}** already loaded (cached {dt:.2f}s)."
        return f"✅ Loaded **{hf_id}** in {dt:.2f}s. Ready to record."
    except Exception as e:  # noqa: BLE001
        return f"❌ Load failed: `{e}`"


def transcribe(audio: tuple[int, np.ndarray] | None) -> tuple[str, str]:
    """Gradio passes audio as (sample_rate, np.ndarray)."""
    if audio is None:
        return "", "_(no audio recorded)_"
    if _ASR.model is None:
        return "", "❌ Load a model first."

    sr, data = audio
    # Gradio gives int16 by default for mic input; normalize to float32 in [-1, 1]
    if data.dtype.kind == "i":
        max_val = float(np.iinfo(data.dtype).max)
        data = data.astype(np.float32) / max_val
    else:
        data = data.astype(np.float32, copy=False)
    # Mono
    if data.ndim == 2:
        data = data.mean(axis=1)
    # Resample to 16 kHz if needed
    target_sr = 16_000
    if sr != target_sr:
        try:
            import soxr

            data = soxr.resample(data, sr, target_sr).astype(np.float32, copy=False)
        except Exception:
            # Fallback: linear interp
            n_out = int(round(data.shape[0] * target_sr / sr))
            x_old = np.linspace(0, 1, data.shape[0], endpoint=False)
            x_new = np.linspace(0, 1, n_out, endpoint=False)
            data = np.interp(x_new, x_old, data).astype(np.float32)

    try:
        result = _ASR.transcribe_array(data, sample_rate=target_sr)
    except Exception as e:  # noqa: BLE001
        return "", f"❌ Transcribe failed: `{e}`"

    stats = (
        f"audio **{result.audio_seconds:.2f}s**  ·  "
        f"transcribe **{result.transcribe_seconds:.2f}s**  ·  "
        f"RTFx **{result.rtfx:.1f}x**  ·  "
        f"model `{_ASR.model_id}`"
    )
    return result.text, stats


def append_transcript(prev: str, new: str) -> str:
    new = (new or "").strip()
    if not new:
        return prev or ""
    if not prev:
        return new
    return f"{prev}\n\n{new}"


def build_ui() -> gr.Blocks:
    with gr.Blocks(title="Shout — Parakeet test bench") as demo:
        gr.Markdown(
            "# 🐦 Shout — Parakeet test bench\n"
            "Local speech-to-text with NVIDIA Parakeet via MLX. "
            "Pick a model, click **Load**, then record."
        )

        with gr.Row():
            with gr.Column(scale=3):
                model_dd = gr.Dropdown(
                    choices=_model_choices(),
                    value=MODELS[0].hf_id,
                    label="Model",
                    allow_custom_value=True,
                    info="Pick from the list or paste any HF model id.",
                )
                desc_md = gr.Markdown(MODELS[0].description)
            with gr.Column(scale=1, min_width=140):
                load_btn = gr.Button("Load model", variant="primary")
        load_status = gr.Markdown(
            "_Model not loaded yet. First-time loads will download weights from "
            "HuggingFace (~1–2 GB)._"
        )

        with gr.Row():
            mic = gr.Audio(
                sources=["microphone"],
                type="numpy",
                label="Microphone — click record, speak, click stop",
                streaming=False,
            )

        with gr.Row():
            transcribe_btn = gr.Button("Transcribe last clip", variant="primary")
            clear_btn = gr.Button("Clear transcript")

        last_md = gr.Markdown("_(no transcription yet)_")
        transcript = gr.Textbox(
            label="Transcript (appended) — select all + ⌘C to copy",
            lines=10,
            interactive=True,
        )

        # ---------- wiring ----------
        model_dd.change(describe, inputs=model_dd, outputs=desc_md)
        load_btn.click(load_model, inputs=model_dd, outputs=load_status)

        # When the user finishes recording, automatically transcribe.
        last_text_state = gr.State("")
        mic.stop_recording(
            transcribe,
            inputs=mic,
            outputs=[last_text_state, last_md],
        ).then(
            append_transcript,
            inputs=[transcript, last_text_state],
            outputs=transcript,
        )

        # Manual button (handy if auto-transcribe didn't fire, e.g. uploaded file)
        transcribe_btn.click(
            transcribe,
            inputs=mic,
            outputs=[last_text_state, last_md],
        ).then(
            append_transcript,
            inputs=[transcript, last_text_state],
            outputs=transcript,
        )

        clear_btn.click(lambda: "", outputs=transcript)

    return demo


def main() -> None:
    parser = argparse.ArgumentParser(description="Shout — Parakeet test bench")
    parser.add_argument("--port", type=int, default=7860)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--no-browser",
        action="store_true",
        help="Don't auto-open a browser tab.",
    )
    parser.add_argument(
        "--preload",
        type=str,
        default=None,
        help="HF model id to load at startup (e.g. mlx-community/parakeet-tdt-0.6b-v2).",
    )
    args = parser.parse_args()

    if args.preload:
        print(f"Preloading {args.preload}…")
        print(load_model(args.preload))

    demo = build_ui()
    demo.launch(
        server_name=args.host,
        server_port=args.port,
        inbrowser=not args.no_browser,
        quiet=False,
        theme=gr.themes.Soft(),
    )


if __name__ == "__main__":
    main()
