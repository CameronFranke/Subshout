"""Microphone capture for the Shout UI.

Records mono float32 at 16 kHz (what Parakeet wants) into an in-memory
buffer, then writes to a temp WAV for transcription.
"""

from __future__ import annotations

import queue
import tempfile
import threading
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

SAMPLE_RATE = 16_000
CHANNELS = 1


class Recorder:
    """Background mic recorder. Thread-safe start/stop."""

    def __init__(self, device: int | None = None) -> None:
        self.device = device
        self._stream: sd.InputStream | None = None
        self._chunks: list[np.ndarray] = []
        self._q: queue.Queue[np.ndarray] = queue.Queue()
        self._drain_thread: threading.Thread | None = None
        self._stop_drain = threading.Event()
        self._level = 0.0  # latest RMS, for the meter
        self._lock = threading.Lock()

    # ------------- lifecycle -------------

    def start(self) -> None:
        if self._stream is not None:
            return
        self._chunks = []
        self._stop_drain.clear()
        self._q = queue.Queue()
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            device=self.device,
            blocksize=0,  # let PortAudio pick
            callback=self._callback,
        )
        self._stream.start()
        self._drain_thread = threading.Thread(target=self._drain, daemon=True)
        self._drain_thread.start()

    def stop(self) -> np.ndarray:
        if self._stream is None:
            return np.zeros(0, dtype=np.float32)
        self._stream.stop()
        self._stream.close()
        self._stream = None
        self._stop_drain.set()
        if self._drain_thread is not None:
            self._drain_thread.join(timeout=1.0)
            self._drain_thread = None
        # drain anything still in the queue
        while True:
            try:
                self._chunks.append(self._q.get_nowait())
            except queue.Empty:
                break
        if not self._chunks:
            return np.zeros(0, dtype=np.float32)
        audio = np.concatenate(self._chunks).astype(np.float32, copy=False)
        return audio

    # ------------- internals -------------

    def _callback(self, indata, frames, time_info, status) -> None:  # noqa: ANN001
        if status:
            # Don't crash on overflows; just note them.
            print(f"[audio] {status}")
        # indata shape: (frames, channels)
        chunk = indata[:, 0].copy() if indata.ndim == 2 else indata.copy()
        self._q.put(chunk)
        rms = float(np.sqrt(np.mean(chunk * chunk)) + 1e-12)
        with self._lock:
            self._level = rms

    def _drain(self) -> None:
        while not self._stop_drain.is_set():
            try:
                chunk = self._q.get(timeout=0.1)
            except queue.Empty:
                continue
            self._chunks.append(chunk)

    # ------------- public read-only -------------

    @property
    def level(self) -> float:
        with self._lock:
            return self._level

    @property
    def seconds_recorded(self) -> float:
        # approximate, includes anything not yet drained
        n_drained = sum(c.shape[0] for c in self._chunks)
        n_pending = sum(c.shape[0] for c in list(self._q.queue))
        return (n_drained + n_pending) / SAMPLE_RATE


def list_input_devices() -> list[tuple[int, str]]:
    devices = sd.query_devices()
    out: list[tuple[int, str]] = []
    for i, d in enumerate(devices):
        if d.get("max_input_channels", 0) > 0:
            out.append((i, d["name"]))
    return out


def default_input_device() -> int | None:
    try:
        d = sd.default.device
        if isinstance(d, (list, tuple)):
            return d[0] if d[0] is not None and d[0] >= 0 else None
        return d if d is not None and d >= 0 else None
    except Exception:
        return None


def write_wav(audio: np.ndarray, path: Path | None = None) -> Path:
    """Write float32 mono audio to a 16 kHz WAV file. Returns the path."""
    if path is None:
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        tmp.close()
        path = Path(tmp.name)
    sf.write(str(path), audio, SAMPLE_RATE, subtype="FLOAT")
    return path
