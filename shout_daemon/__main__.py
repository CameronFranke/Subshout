"""CLI entry point for the subshout ASR daemon.

Two modes:

* `--smoke [--preload MODEL_ID]` — load a model, transcribe 1s of silence
  (cold + warm), and exit. Useful for packaging/hardware sanity checks.
* default — run the Unix-socket server. The Swift app is the intended client.

In production the Swift app passes `--socket` and `--log-file` explicitly,
pointing at `~/Library/Application Support/subshout/daemon.sock` and
`~/Library/Logs/subshout/daemon.log` respectively.  The defaults below
are only for the rare hand-launch case.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import numpy as np

from .asr import ParakeetASR
from .models import MODELS
from .server import DAEMON_VERSION, run


DEFAULT_MODEL = "mlx-community/parakeet-tdt-0.6b-v2"
DEFAULT_SOCKET = Path.home() / "Library/Application Support/subshout/daemon.sock"
DEFAULT_LOG_FILE = Path.home() / "Library/Logs/subshout/daemon.log"


def _smoke(model_id: str) -> int:
    """Load a model and transcribe 1s of silence as a sanity check."""
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


def _configure_logging(log_file: Path | None, verbose: bool) -> None:
    """Send daemon logs to stderr by default, or to a file when given."""
    level = logging.DEBUG if verbose else logging.INFO
    fmt = "%(asctime)s %(levelname)s %(name)s: %(message)s"
    handlers: list[logging.Handler] = []
    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        handlers.append(logging.FileHandler(log_file, mode="a", encoding="utf-8"))
    else:
        handlers.append(logging.StreamHandler(sys.stderr))
    logging.basicConfig(level=level, format=fmt, handlers=handlers, force=True)


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="shout-daemon",
        description="subshout ASR daemon: parakeet-mlx behind a Unix socket.",
    )
    p.add_argument(
        "--socket",
        type=Path,
        default=DEFAULT_SOCKET,
        help=f"Unix socket path (default: {DEFAULT_SOCKET})",
    )
    p.add_argument(
        "--preload",
        metavar="MODEL_ID",
        nargs="?",
        const=DEFAULT_MODEL,
        default=None,
        help=(
            "Preload a model at startup (and warm it up). With no value, "
            f"defaults to {DEFAULT_MODEL}. If omitted entirely, the daemon "
            "loads lazily on the first 'load_model' request."
        ),
    )
    p.add_argument(
        "--log-file",
        type=Path,
        default=None,
        help=(
            "Append logs to this file. If omitted, logs go to stderr "
            f"(suggested: {DEFAULT_LOG_FILE})."
        ),
    )
    p.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable DEBUG logging.",
    )
    p.add_argument(
        "--smoke",
        action="store_true",
        help="Run the smoke test instead of starting the server.",
    )
    p.add_argument(
        "--version",
        action="version",
        version=f"shout-daemon {DAEMON_VERSION}",
    )
    return p


def _validate_model_id(model_id: str | None) -> None:
    """Warn (don't error) if the user picks an unknown model id."""
    if model_id is None:
        return
    known = {m.hf_id for m in MODELS}
    if model_id not in known:
        print(
            f"shout-daemon: warning: model_id {model_id!r} is not in the "
            f"curated list. parakeet-mlx will still try to load it.",
            file=sys.stderr,
        )


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    _configure_logging(args.log_file, args.verbose)

    if args.smoke:
        return _smoke(args.preload or DEFAULT_MODEL)

    _validate_model_id(args.preload)
    try:
        run(args.socket, preload_model=args.preload)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
