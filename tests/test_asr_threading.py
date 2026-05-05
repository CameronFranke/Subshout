"""Regression tests for the cross-thread MLX bug.

MLX streams are per-thread. If we let Gradio (or any other caller) load
the model on one thread and run inference on another, MLX raises::

    RuntimeError: There is no Stream(gpu, 0) in current thread.

``ParakeetASR`` is supposed to insulate callers from this by routing all
MLX work through a single dedicated worker thread. These tests pin that
behaviour so the bug doesn't silently regress.

Loading a real Parakeet checkpoint is slow and requires network, so the
tests here are marked as integration. Skip with ``-m 'not integration'``
on CI runners that don't have the model cached / a GPU available.
"""

from __future__ import annotations

import os
import threading

import numpy as np
import pytest

from shout_daemon.asr import ParakeetASR


SMALL_MODEL = os.environ.get(
    "SHOUT_TEST_MODEL", "mlx-community/parakeet-tdt-0.6b-v2"
)


def _silence(seconds: float = 1.0, sr: int = 16_000) -> np.ndarray:
    return np.zeros(int(seconds * sr), dtype=np.float32)


def test_executor_thread_is_reused() -> None:
    """All MLX calls must run on the *same* dedicated worker thread."""
    asr = ParakeetASR()
    seen: list[int] = []

    def record_thread() -> int:
        tid = threading.get_ident()
        seen.append(tid)
        return tid

    t1 = asr._run(record_thread)
    t2 = asr._run(record_thread)
    t3 = asr._run(record_thread)

    assert t1 == t2 == t3, f"executor used multiple threads: {seen}"
    assert t1 != threading.get_ident(), (
        "MLX work ran on the calling thread; that defeats the point"
    )


@pytest.mark.integration
def test_transcribe_from_foreign_thread_does_not_raise_stream_error() -> None:
    """Regression: load on thread A, transcribe from thread B.

    Before the fix, this raised ``There is no Stream(gpu, 0) in current
    thread`` because ``mx.eval`` inside ``model.generate`` looked up the
    GPU stream registered on the loading thread. ``ParakeetASR`` now
    funnels both calls onto its internal worker thread, so it must work
    regardless of which thread the user is calling from.
    """
    asr = ParakeetASR()
    asr.load(SMALL_MODEL)  # loads on the executor thread

    audio = _silence(1.0)
    errors: list[BaseException] = []
    result_holder: list[object] = []

    def worker() -> None:
        try:
            result_holder.append(asr.transcribe_array(audio, sample_rate=16_000))
        except BaseException as e:  # noqa: BLE001
            errors.append(e)

    # Spin up a fresh OS thread that has never touched MLX before — this
    # is what Gradio's request workers look like.
    t = threading.Thread(target=worker)
    t.start()
    t.join(timeout=120)

    assert not t.is_alive(), "transcription hung"
    assert not errors, f"transcribe raised from a foreign thread: {errors!r}"
    assert result_holder, "no result returned"
    # Silence-in, anything-out is fine — we only care that no exception fired.
