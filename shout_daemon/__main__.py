"""CLI entry point for the Shout ASR daemon.

This is intentionally a thin shell during Phase 0. Phase 1 fills in the
Unix-socket server (see TODO.md). Until then, `--smoke` is the only thing
that does real work: it loads a model, transcribes a synthetic clip, and
prints the result. Useful for verifying the package after restructuring.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

from .asr import ParakeetASR
from .models import MODELS


DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
DEFAULT_SOCKET = Path.home() / "Library/Application Support/Shout/daemon.sock"


def _smoke(model_id: str) -> int:
    """Load a model and transcribe 1s of silence. Phase 0 sanity check."""
    print(f"[smoke] loading {model_id} ...", flush=True)
    asr = ParakeetASR()
    load_s = asr.load(model_id)
    print(f"[smoke] loaded in {load_s:.2f}s", flush=True)

    audio = np.zeros(16_000, dtype=np.float32)  # 1s silence @ 16kHz
    print("[smoke] transcribing 1s silence (cold) ...", flush=True)
    r1 = asr.transcribe_array(audio, sample_rate=16_000)
    print(f"[smoke] cold: {r1.transcribe_seconds*1000:.0f}ms  text={r1.text!r}", flush=True)

    print("[smoke] transcribing 1s silence (warm) ...", flush=True)
    r2 = asr.transcribe_array(audio, sample_rate=16_000)
    print(f"[smoke] warm: {r2.transcribe_seconds*1000:.0f}ms  text={r2.text!r}", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="shout-daemon")
    p.add_argument(
        "--socket",
        type=Path,
        default=DEFAULT_SOCKET,
        help="Unix socket path (Phase 1; ignored during Phase 0).",
    )
    p.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        choices=[m.hf_id for m in MODELS] + [DEFAULT_MODEL],
        help="HF model id to preload.",
    )
    p.add_argument(
        "--smoke",
        action="store_true",
        help="Load the model, transcribe 1s of silence, exit. Phase 0 sanity check.",
    )
    args = p.parse_args(argv)

    if args.smoke:
        return _smoke(args.model)

    print(
        "shout-daemon: socket server not yet implemented (Phase 1).\n"
        "Run with --smoke for a Phase 0 sanity check.",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
