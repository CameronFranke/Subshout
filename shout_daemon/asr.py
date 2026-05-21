"""Thin wrapper around parakeet-mlx.

All MLX calls (load + inference) are dispatched onto a single dedicated
worker thread. MLX streams are per-thread: arrays created on thread A
cannot be evaluated on thread B without raising
``RuntimeError: There is no Stream(gpu, 0) in current thread``.

The daemon's IPC layer accepts requests on whatever thread ``asyncio`` / the
socket server hands us. Funnelling everything through
one ``ThreadPoolExecutor(max_workers=1)`` gives us a stable "MLX thread"
for the lifetime of the process.
"""

from __future__ import annotations

import time
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable, TypeVar

import mlx.core as mx
import numpy as np

from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel
from parakeet_mlx.parakeet import BaseParakeet


T = TypeVar("T")


@dataclass
class TranscriptionResult:
    text: str
    audio_seconds: float
    transcribe_seconds: float

    @property
    def rtfx(self) -> float:
        if self.transcribe_seconds <= 0:
            return float("inf")
        return self.audio_seconds / self.transcribe_seconds


class ParakeetASR:
    def __init__(self) -> None:
        self.model: BaseParakeet | None = None
        self.model_id: str | None = None
        self.load_seconds: float = 0.0
        # Single dedicated MLX thread. Daemon so it doesn't block exit.
        self._executor = ThreadPoolExecutor(
            max_workers=1, thread_name_prefix="mlx"
        )

    def _run(self, fn: Callable[[], T]) -> T:
        """Run ``fn`` on the dedicated MLX thread and return its result."""
        fut: Future[T] = self._executor.submit(fn)
        return fut.result()

    def load(self, hf_id: str) -> float:
        """Load (or reload) a model. Returns load wall time in seconds."""
        if self.model is not None and self.model_id == hf_id:
            return self.load_seconds

        def _do_load() -> float:
            # Drop the old one explicitly so MLX can free memory before loading.
            self.model = None
            self.model_id = None
            t0 = time.perf_counter()
            self.model = from_pretrained(hf_id)
            self.load_seconds = time.perf_counter() - t0
            self.model_id = hf_id
            return self.load_seconds

        return self._run(_do_load)

    def transcribe_array(
        self, audio: np.ndarray, sample_rate: int = 16_000
    ) -> TranscriptionResult:
        """Transcribe a 1-D float32 numpy array at the model's sample rate.

        Bypasses parakeet-mlx's ffmpeg-backed file loader so we don't need
        ffmpeg installed. Mirrors the model's own preprocessing.
        """
        if self.model is None:
            raise RuntimeError("Model not loaded")
        if audio.ndim != 1:
            audio = audio.reshape(-1)
        audio = audio.astype(np.float32, copy=False)
        audio_seconds = audio.shape[0] / float(sample_rate)

        def _do_transcribe() -> TranscriptionResult:
            assert self.model is not None
            t0 = time.perf_counter()
            x = mx.array(audio)
            mel = get_logmel(x, self.model.preprocessor_config)
            results = self.model.generate(mel)
            text = results[0].text if results else ""
            dt = time.perf_counter() - t0
            return TranscriptionResult(
                text=text,
                audio_seconds=audio_seconds,
                transcribe_seconds=dt,
            )

        return self._run(_do_transcribe)
