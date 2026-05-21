"""Unix-domain-socket server for the subshout ASR daemon.

One Swift client at a time. Frame format and message kinds live in
`protocol.py`. All MLX work is offloaded to the dedicated executor inside
`ParakeetASR`, so the asyncio event loop stays responsive (e.g. it can still
process `status` even while a long load is in flight).

Lifecycle:

* `serve()` binds the socket *first*, then kicks off any preload as a
  background task. The Swift client can therefore connect immediately on
  app launch and poll `status` until `ready=true`. This matters for the
  first-run case where Parakeet weights have to download (could be minutes).

Side effects worth knowing about:

* Creates the parent directory of the socket path if missing.
* Removes a stale socket file at startup (with a warning).
* `chmod 0o600` on the socket so other local users can't connect.
* Registers SIGINT/SIGTERM handlers (skippable for tests via
  `register_signals=False`).
* Unlinks the socket file on shutdown.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
import signal
from pathlib import Path
from typing import Optional

import numpy as np

from .asr import ParakeetASR
from .protocol import (
    Message,
    ProtocolError,
    encode_message,
    read_message_async,
)


log = logging.getLogger("shout_daemon.server")

DAEMON_VERSION = "0.1.0"

# After loading a model we run a tiny silence buffer through it so MLX
# compiles its kernels now, not on the user's first real utterance.
_WARMUP_SECONDS = 0.25
_WARMUP_SR = 16_000


class _ClientError(Exception):
    """Raised by handlers to send a structured `error` response and continue."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class DaemonServer:
    def __init__(
        self,
        socket_path: Path,
        preload_model: Optional[str] = None,
    ) -> None:
        self.socket_path = Path(socket_path)
        self.preload_model = preload_model
        self.asr = ParakeetASR()
        self._server: Optional[asyncio.AbstractServer] = None
        self._client_busy = False
        self._stop = asyncio.Event()
        self._preload_task: Optional[asyncio.Task] = None

    # ------------------------------------------------------------------ lifecycle

    async def serve(self, register_signals: bool = True) -> None:
        """Run the server until shutdown. Returns when the server has stopped."""
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            log.warning("removing stale socket at %s", self.socket_path)
            try:
                self.socket_path.unlink()
            except OSError as e:
                raise RuntimeError(
                    f"could not remove stale socket {self.socket_path}: {e}"
                ) from e

        # Bind first so the client can connect even while we're still
        # downloading model weights in the background.
        self._server = await asyncio.start_unix_server(
            self._handle_client, path=str(self.socket_path)
        )
        try:
            os.chmod(self.socket_path, 0o600)
        except OSError as e:
            log.warning("could not chmod socket: %s", e)
        log.info("listening on %s", self.socket_path)

        if self.preload_model:
            self._preload_task = asyncio.create_task(
                self._preload_in_background(self.preload_model)
            )

        if register_signals:
            loop = asyncio.get_running_loop()
            for sig in (signal.SIGINT, signal.SIGTERM):
                with contextlib.suppress(NotImplementedError, ValueError):
                    loop.add_signal_handler(sig, self._stop.set)

        try:
            await self._stop.wait()
        finally:
            await self._shutdown()

    def request_stop(self) -> None:
        """Trip the shutdown event. Safe to call from any coroutine on the loop."""
        self._stop.set()

    async def _shutdown(self) -> None:
        if self._preload_task and not self._preload_task.done():
            self._preload_task.cancel()
            with contextlib.suppress(asyncio.CancelledError, Exception):
                await self._preload_task
        if self._server is not None:
            self._server.close()
            with contextlib.suppress(Exception):
                await self._server.wait_closed()
        with contextlib.suppress(FileNotFoundError):
            self.socket_path.unlink()
        log.info("shut down")

    async def _preload_in_background(self, model_id: str) -> None:
        try:
            log.info("preload (background): %s", model_id)
            await asyncio.get_running_loop().run_in_executor(
                None, self.asr.load, model_id
            )
            await self._warmup()
            log.info("preload complete")
        except asyncio.CancelledError:
            log.info("preload cancelled")
            raise
        except Exception:
            log.exception("preload failed")

    # ------------------------------------------------------------------ warmup

    async def _warmup(self) -> None:
        n = int(_WARMUP_SECONDS * _WARMUP_SR)
        silence = np.zeros(n, dtype=np.float32)
        log.info("warmup: transcribing %.2fs of silence", _WARMUP_SECONDS)
        await asyncio.get_running_loop().run_in_executor(
            None, self.asr.transcribe_array, silence, _WARMUP_SR
        )

    # ------------------------------------------------------------------ clients

    async def _handle_client(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("peername") or "<unix>"
        if self._client_busy:
            log.warning("rejecting concurrent client %s", peer)
            try:
                writer.write(
                    encode_message(
                        {
                            "type": "error",
                            "code": "busy",
                            "message": "another client is already connected",
                        }
                    )
                )
                with contextlib.suppress(Exception):
                    await writer.drain()
            finally:
                writer.close()
                with contextlib.suppress(Exception):
                    await writer.wait_closed()
            return

        self._client_busy = True
        log.info("client connected: %s", peer)
        try:
            await self._client_loop(reader, writer)
        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            log.info("client disconnected mid-frame")
        except ProtocolError as e:
            log.warning("protocol error from client: %s", e)
        except Exception:
            log.exception("client handler crashed")
        finally:
            writer.close()
            with contextlib.suppress(Exception):
                await writer.wait_closed()
            self._client_busy = False
            log.info("client closed")

    async def _client_loop(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        async def read_exact(n: int) -> bytes:
            return await reader.readexactly(n)

        while not self._stop.is_set():
            try:
                msg = await read_message_async(read_exact)
            except asyncio.IncompleteReadError as e:
                if e.partial:
                    log.warning(
                        "client closed mid-frame (%d/%s bytes)",
                        len(e.partial),
                        e.expected,
                    )
                return

            resp_header, resp_payload = await self._dispatch(msg)
            writer.write(encode_message(resp_header, resp_payload))
            try:
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError):
                log.info("client went away while we were responding")
                return

            if msg.type == "shutdown":
                self._stop.set()
                return

    # ------------------------------------------------------------------ dispatch

    async def _dispatch(self, msg: Message) -> tuple[dict, bytes]:
        t = msg.type
        try:
            if t == "load_model":
                return await self._do_load(msg), b""
            if t == "transcribe":
                return await self._do_transcribe(msg), b""
            if t == "status":
                return self._do_status(), b""
            if t == "shutdown":
                return {"type": "ok"}, b""
            return (
                {
                    "type": "error",
                    "code": "unknown_type",
                    "message": f"unknown message type {t!r}",
                },
                b"",
            )
        except _ClientError as e:
            return (
                {"type": "error", "code": e.code, "message": str(e)},
                b"",
            )
        except Exception as e:  # pragma: no cover - last-resort safety net
            log.exception("error handling %r", t)
            return (
                {
                    "type": "error",
                    "code": "internal",
                    "message": f"{type(e).__name__}: {e}",
                },
                b"",
            )

    async def _do_load(self, msg: Message) -> dict:
        model_id = msg.header.get("model_id")
        if not isinstance(model_id, str) or not model_id:
            raise _ClientError("bad_request", "load_model requires 'model_id' (string)")
        log.info("load_model %s", model_id)
        load_seconds = await asyncio.get_running_loop().run_in_executor(
            None, self.asr.load, model_id
        )
        await self._warmup()
        return {
            "type": "ok",
            "model_id": model_id,
            "load_seconds": float(load_seconds),
        }

    async def _do_transcribe(self, msg: Message) -> dict:
        if self.asr.model is None:
            raise _ClientError(
                "not_loaded",
                "no model loaded; send 'load_model' first or wait for preload",
            )
        sr = msg.header.get("sample_rate", 16_000)
        if not isinstance(sr, int) or isinstance(sr, bool) or sr <= 0:
            raise _ClientError("bad_request", f"bad sample_rate: {sr!r}")
        if len(msg.payload) % 4 != 0:
            raise _ClientError(
                "bad_request",
                f"payload not aligned to float32 (4 bytes): {len(msg.payload)} bytes",
            )
        if not msg.payload:
            raise _ClientError("bad_request", "empty audio payload")

        # `np.frombuffer` returns a read-only view; copy so MLX can use it
        # without surprises and so the underlying bytes can be GC'd.
        audio = np.frombuffer(msg.payload, dtype="<f4").astype(
            np.float32, copy=True
        )

        result = await asyncio.get_running_loop().run_in_executor(
            None, self.asr.transcribe_array, audio, sr
        )
        return {
            "type": "ok",
            "text": result.text,
            "audio_seconds": float(result.audio_seconds),
            "transcribe_seconds": float(result.transcribe_seconds),
        }

    def _do_status(self) -> dict:
        return {
            "type": "ok",
            "ready": self.asr.model is not None,
            "model_id": self.asr.model_id,
            "version": DAEMON_VERSION,
        }


def run(
    socket_path: Path,
    preload_model: Optional[str] = None,
) -> None:
    """Blocking entry point. Runs an asyncio loop until SIGTERM/SIGINT."""
    server = DaemonServer(socket_path, preload_model=preload_model)
    asyncio.run(server.serve())
