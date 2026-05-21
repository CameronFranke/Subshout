"""subshout ASR daemon.

Loads a parakeet-mlx model into memory and serves transcription requests
over a Unix domain socket. The macOS Swift app (`subshout.app`) is the
intended client; see `mac/Sources/SubShout/DaemonClient.swift`.

The Python package name (`shout_daemon`) and the CLI script name
(`shout-daemon`) are left unchanged from the pre-rename codebase
because they're internal-only — the user never invokes them by hand;
`subshout.app` spawns this from
`subshout.app/Contents/Resources/shout-daemon/bin/shout-daemon`.

Public API surfaces:
    - `ParakeetASR` (asr.py): MLX model wrapper.
    - `MODELS` (models.py): curated HF model list.
    - `DaemonServer`, `run` (server.py): UDS server.
    - `encode_message`, `read_message_*`, `Message`, `ProtocolError` (protocol.py).
    - `main()` (__main__.py): CLI entry point, exposed as `shout-daemon`.
"""

from .asr import ParakeetASR, TranscriptionResult
from .models import MODELS, ModelInfo, by_id
from .protocol import (
    Message,
    ProtocolError,
    encode_message,
    read_message_async,
    read_message_sync,
)
from .server import DAEMON_VERSION, DaemonServer, run

__all__ = [
    "DAEMON_VERSION",
    "DaemonServer",
    "MODELS",
    "Message",
    "ModelInfo",
    "ParakeetASR",
    "ProtocolError",
    "TranscriptionResult",
    "by_id",
    "encode_message",
    "read_message_async",
    "read_message_sync",
    "run",
]
