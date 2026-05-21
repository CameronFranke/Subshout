"""End-to-end happy path: server + real Parakeet model.

Marked `integration` so CI / quick runs skip it. Run explicitly:

    uv run pytest -m integration tests/test_server_integration.py
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import numpy as np
import pytest

from shout_daemon.protocol import encode_message, read_message_async
from shout_daemon.server import DaemonServer


pytestmark = pytest.mark.integration


MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v2"


async def _read_one(reader: asyncio.StreamReader):
    async def read_exact(n: int) -> bytes:
        return await reader.readexactly(n)

    return await read_message_async(read_exact)


def _socket_path(tmp_path: Path) -> Path:
    p = tmp_path / "d.sock"
    if len(str(p)) > 100:
        pytest.skip(f"tmp socket path too long: {p}")
    return p


async def _wait_for_socket(path: Path, timeout: float = 30.0) -> None:
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not path.exists():
        if loop.time() > deadline:
            raise TimeoutError(f"socket {path} never appeared")
        await asyncio.sleep(0.05)


async def _wait_for_ready(reader, writer, timeout: float = 600.0) -> None:
    """Poll status until ready=true.  Generous timeout for first-run model download."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        writer.write(encode_message({"type": "status"}))
        await writer.drain()
        resp = await asyncio.wait_for(_read_one(reader), timeout=10.0)
        assert resp.type == "ok"
        if resp.header.get("ready") is True:
            return
        if loop.time() > deadline:
            raise TimeoutError("model never became ready")
        await asyncio.sleep(0.5)


def test_load_model_then_transcribe_silence(tmp_path: Path):
    sock = _socket_path(tmp_path)

    async def body():
        server = DaemonServer(sock, preload_model=None)
        serve_task = asyncio.create_task(server.serve(register_signals=False))
        try:
            await _wait_for_socket(sock)

            reader, writer = await asyncio.open_unix_connection(path=str(sock))
            try:
                # 1. load_model — gives us a load time + warmup.
                writer.write(
                    encode_message({"type": "load_model", "model_id": MODEL_ID})
                )
                await writer.drain()
                resp = await asyncio.wait_for(_read_one(reader), timeout=600.0)
                assert resp.type == "ok", resp.header
                assert resp.header["model_id"] == MODEL_ID

                # 2. transcribe 1s of silence — empty text expected, no error.
                pcm = np.zeros(16_000, dtype="<f4").tobytes()
                writer.write(
                    encode_message(
                        {"type": "transcribe", "sample_rate": 16000},
                        payload=pcm,
                    )
                )
                await writer.drain()
                resp = await asyncio.wait_for(_read_one(reader), timeout=30.0)
                assert resp.type == "ok", resp.header
                assert "text" in resp.header
                assert resp.header["audio_seconds"] == pytest.approx(1.0, rel=0.01)

                # 3. status reflects loaded state.
                writer.write(encode_message({"type": "status"}))
                await writer.drain()
                resp = await asyncio.wait_for(_read_one(reader), timeout=5.0)
                assert resp.type == "ok"
                assert resp.header["ready"] is True
                assert resp.header["model_id"] == MODEL_ID
            finally:
                writer.close()
                await writer.wait_closed()
        finally:
            server.request_stop()
            await asyncio.wait_for(serve_task, timeout=10.0)

    asyncio.run(body())


def test_preload_then_transcribe_rejects_unaligned_payload(tmp_path: Path):
    """Preload runs in the background; we wait for ready, then exercise validation."""
    sock = _socket_path(tmp_path)

    async def body():
        server = DaemonServer(sock, preload_model=MODEL_ID)
        serve_task = asyncio.create_task(server.serve(register_signals=False))
        try:
            await _wait_for_socket(sock)

            reader, writer = await asyncio.open_unix_connection(path=str(sock))
            try:
                await _wait_for_ready(reader, writer)

                writer.write(
                    encode_message(
                        {"type": "transcribe", "sample_rate": 16000},
                        payload=b"\x00\x00\x00",  # 3 bytes — not %4
                    )
                )
                await writer.drain()
                resp = await asyncio.wait_for(_read_one(reader), timeout=10.0)
                assert resp.type == "error"
                assert resp.header["code"] == "bad_request"
            finally:
                writer.close()
                await writer.wait_closed()
        finally:
            server.request_stop()
            await asyncio.wait_for(serve_task, timeout=10.0)

    asyncio.run(body())
