"""Server tests that don't touch the MLX model.

We exercise: status, error paths (unknown_type, not_loaded, bad_request,
busy), stale-socket cleanup, socket permissions, and clean shutdown. The real
`load_model` / `transcribe` happy path needs Parakeet weights and is covered by
the integration test instead.
"""

from __future__ import annotations

import asyncio
import contextlib
import os
import shutil
import stat
import tempfile
from collections.abc import Iterator
from pathlib import Path

import pytest

from shout_daemon.protocol import (
    Message,
    encode_message,
    read_message_async,
)
from shout_daemon.server import DaemonServer


# ---------------------------------------------------------------------------- helpers


@pytest.fixture
def socket_path() -> Iterator[Path]:
    """Yield a short Unix-socket path and clean it up afterwards.

    macOS caps `sun_path` at ~104 bytes. pytest's default `tmp_path` often lives
    under `/private/var/folders/...`, which is long enough to skip the very
    tests we care about. Keep socket tests under `/tmp/subshout-test-*` so they
    run reliably both locally and in CI.
    """
    tmp_dir = Path(tempfile.mkdtemp(prefix="subshout-test-", dir="/tmp"))
    try:
        yield tmp_dir / "d.sock"
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


async def _client_send(
    writer: asyncio.StreamWriter, header: dict, payload: bytes = b""
) -> None:
    writer.write(encode_message(header, payload))
    await writer.drain()


async def _client_recv(reader: asyncio.StreamReader) -> Message:
    async def read_exact(n: int) -> bytes:
        return await reader.readexactly(n)

    return await read_message_async(read_exact)


async def _connect(socket_path: Path):
    return await asyncio.open_unix_connection(path=str(socket_path))


async def _wait_for_socket(path: Path, timeout: float = 5.0) -> None:
    """Spin until `path` is a real Unix socket.

    Waiting for `exists()` is not enough: the stale-socket regression test plants
    a regular file first, and the server should replace it with a socket.
    """
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while True:
        with contextlib.suppress(FileNotFoundError):
            if stat.S_ISSOCK(path.stat().st_mode):
                return
        if loop.time() > deadline:
            raise TimeoutError(f"socket {path} never became a Unix socket")
        await asyncio.sleep(0.01)


async def _run_server_test(socket_path: Path, body):
    """Start a DaemonServer, run `body(server)`, then make sure it cleaned up."""
    server = DaemonServer(socket_path, preload_model=None)
    serve_task = asyncio.create_task(server.serve(register_signals=False))
    try:
        await _wait_for_socket(socket_path)
        await body(server)
    finally:
        server.request_stop()
        await asyncio.wait_for(serve_task, timeout=5.0)


# ---------------------------------------------------------------------------- tests


def test_status_returns_not_ready_when_no_model_loaded(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        reader, writer = await _connect(sock)
        try:
            await _client_send(writer, {"type": "status"})
            resp = await _client_recv(reader)
            assert resp.type == "ok"
            assert resp.header["ready"] is False
            assert resp.header["model_id"] is None
            assert isinstance(resp.header["version"], str)
        finally:
            writer.close()
            await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_transcribe_without_model_returns_not_loaded(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        reader, writer = await _connect(sock)
        try:
            # Even with a malformed payload, not_loaded is checked first.
            await _client_send(
                writer,
                {"type": "transcribe", "sample_rate": 16000},
                payload=b"\x00\x00\x00\x00",
            )
            resp = await _client_recv(reader)
            assert resp.type == "error"
            assert resp.header["code"] == "not_loaded"
        finally:
            writer.close()
            await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_unknown_message_type_returns_error(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        reader, writer = await _connect(sock)
        try:
            await _client_send(writer, {"type": "wat"})
            resp = await _client_recv(reader)
            assert resp.type == "error"
            assert resp.header["code"] == "unknown_type"
        finally:
            writer.close()
            await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_load_model_without_model_id_is_bad_request(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        reader, writer = await _connect(sock)
        try:
            await _client_send(writer, {"type": "load_model"})
            resp = await _client_recv(reader)
            assert resp.type == "error"
            assert resp.header["code"] == "bad_request"
            assert "model_id" in resp.header["message"]
        finally:
            writer.close()
            await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_second_client_is_rejected_with_busy(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        # First client connects and stays connected.
        _r1, w1 = await _connect(sock)

        # Wait for the server to mark itself busy. The flag flips
        # synchronously at the top of `_handle_client`, but the coroutine
        # has to actually start running.
        for _ in range(100):
            if server._client_busy:  # noqa: SLF001 (test-only access)
                break
            await asyncio.sleep(0.01)
        assert server._client_busy, "server never registered first client"

        # Second client connects and should immediately receive a busy error.
        r2, w2 = await _connect(sock)
        try:
            resp = await asyncio.wait_for(_client_recv(r2), timeout=2.0)
            assert resp.type == "error"
            assert resp.header["code"] == "busy"
        finally:
            w2.close()
            with contextlib.suppress(Exception):
                await w2.wait_closed()

        w1.close()
        await w1.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_shutdown_closes_server_and_unlinks_socket(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        reader, writer = await _connect(sock)
        await _client_send(writer, {"type": "shutdown"})
        resp = await _client_recv(reader)
        assert resp.type == "ok"
        writer.close()
        await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))
    # After serve() returned, the socket file must be gone.
    assert not sock.exists()


def test_stale_socket_is_removed_on_startup(socket_path: Path):
    sock = socket_path
    # Plant a leftover file that looks like a stale socket from a crashed run.
    sock.parent.mkdir(parents=True, exist_ok=True)
    sock.write_bytes(b"")
    assert sock.exists()
    assert not stat.S_ISSOCK(sock.stat().st_mode)

    async def body(server: DaemonServer):
        # If we got here, the server bound successfully — i.e. the stale
        # file was removed and replaced by a real socket.
        assert stat.S_ISSOCK(sock.stat().st_mode)
        reader, writer = await _connect(sock)
        try:
            await _client_send(writer, {"type": "status"})
            resp = await _client_recv(reader)
            assert resp.type == "ok"
        finally:
            writer.close()
            await writer.wait_closed()

    asyncio.run(_run_server_test(sock, body))


def test_socket_has_owner_only_perms(socket_path: Path):
    sock = socket_path

    async def body(server: DaemonServer):
        st = os.stat(sock)
        # Exactly user rw — no group, no other.
        assert (st.st_mode & 0o777) == 0o600

    asyncio.run(_run_server_test(sock, body))
