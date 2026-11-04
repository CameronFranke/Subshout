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

from parakeet_mlx import boost, from_pretrained
from parakeet_mlx.audio import get_logmel
from parakeet_mlx.parakeet import (
    BaseParakeet,
    Beam,
    DecodingConfig,
    ParakeetRNNT,
    ParakeetTDT,
)


T = TypeVar("T")

# MLX otherwise retains freed GPU buffers until its allocator reaches its
# default (very large) cache limit. Keep only a modest cache: dictation runs
# serially, so reuse beyond the current request is not worth exhausting unified
# memory.
_MLX_CACHE_LIMIT_BYTES = 256 * 1024 * 1024


class UnsupportedVocabularyError(ValueError):
    """The loaded model cannot apply custom vocabulary during decoding."""


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
        mx.set_cache_limit(_MLX_CACHE_LIMIT_BYTES)

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
            # Loading starts with the checkpoint's original tensors and casts
            # them to BF16. Free the original/load-time intermediates now
            # rather than retaining that high-water allocation indefinitely.
            mx.clear_cache()
            mx.reset_peak_memory()
            self.load_seconds = time.perf_counter() - t0
            self.model_id = hf_id
            return self.load_seconds

        return self._run(_do_load)

    def memory_state(self) -> tuple[int, int, int]:
        """Return MLX active, cached, and peak bytes from the MLX thread."""
        return self._run(
            lambda: (
                mx.get_active_memory(),
                mx.get_cache_memory(),
                mx.get_peak_memory(),
            )
        )

    def transcribe_array(
        self,
        audio: np.ndarray,
        sample_rate: int = 16_000,
        vocabulary: list[str] | None = None,
    ) -> TranscriptionResult:
        """Transcribe a 1-D float32 numpy array at the model's sample rate.

        Bypasses parakeet-mlx's ffmpeg-backed file loader so we don't need
        ffmpeg installed. Mirrors the model's own preprocessing. Vocabulary
        must already be validated by the protocol boundary. A fresh decoder
        config is built per request; empty vocabulary keeps upstream greedy.
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
            decoding_config = None
            if vocabulary:
                # The hybrid TDT/CTC model subclasses TDT and uses its decoder.
                # CTC does not apply Beam.booster: never silently ignore words.
                if not isinstance(self.model, (ParakeetTDT, ParakeetRNNT)):
                    raise UnsupportedVocabularyError(
                        "custom vocabulary requires a TDT or RNN-T model"
                    )
                tokens = self.model.vocabulary
                if not tokens or not all(isinstance(token, str) for token in tokens):
                    raise UnsupportedVocabularyError(
                        "loaded model has no compatible token vocabulary"
                    )
                word_booster = boost.words(
                    {phrase.casefold(): 1.5 for phrase in vocabulary}
                )
                # Matching is case-insensitive, but generated spelling remains
                # the model's own. prebind handles casefold expansions too.
                word_booster = boost.prebind(str.casefold, word_booster)
                decoding_config = DecodingConfig(
                    decoding=Beam(
                        beam_size=2, booster=boost.lift(word_booster, tokens)
                    )
                )
            try:
                x = mx.array(audio)
                mel = get_logmel(x, self.model.preprocessor_config)
                if decoding_config is None:
                    results = self.model.generate(mel)
                else:
                    results = self.model.generate(mel, decoding_config=decoding_config)
                text = results[0].text if results else ""
                # Only text escapes; release feature and decoder buffers.
                del results, mel, x
            finally:
                if decoding_config is not None:
                    # Upstream retains per-state MLX arrays in this global
                    # cache if beam decoding raises before its own cleanup.
                    boost.tabulate.cache_clear()
                mx.clear_cache()
            dt = time.perf_counter() - t0
            return TranscriptionResult(
                text=text,
                audio_seconds=audio_seconds,
                transcribe_seconds=dt,
            )

        return self._run(_do_transcribe)
