"""Shout ASR daemon.

Loads a parakeet-mlx model into memory and serves transcription requests
over a Unix domain socket. The macOS Swift app (`Shout.app`) is the
intended client; see `mac/Shout/DaemonClient.swift`.

Public API surfaces:
    - `ParakeetASR` (asr.py): the actual model wrapper.
    - `MODELS` (models.py): curated HF model list.
    - `main()` (__main__.py): CLI entry point, exposed as `shout-daemon`.
"""

from .asr import ParakeetASR, TranscriptionResult
from .models import MODELS, ModelInfo, by_id

__all__ = [
    "MODELS",
    "ModelInfo",
    "ParakeetASR",
    "TranscriptionResult",
    "by_id",
]
