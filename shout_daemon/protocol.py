"""Wire protocol between the Swift app and the Python daemon.

Frame format (all integers big-endian):

    +------------------------------------------+
    | uint32  header_len                       |
    +------------------------------------------+
    | header_len bytes  UTF-8 JSON header      |
    +------------------------------------------+
    | payload_len bytes (raw, may be empty)    |
    +------------------------------------------+

The JSON header is a single object containing at minimum:

    "type":         message kind (string, see below)
    "payload_len":  size in bytes of the binary payload that follows (>= 0)

Message kinds
-------------
Requests (Swift → daemon):
    {"type": "load_model",  "model_id": str}                 (no payload)
    {"type": "transcribe", "sample_rate": int,
     "vocabulary": [str, ...]}                               payload = float32 LE PCM
    vocabulary is optional (default []): at most 128 raw entries, each nonempty
    after whitespace normalization and at most 256 UTF-8 bytes. Non-whitespace
    control characters are rejected; duplicates are removed case-insensitively.
    {"type": "status"}                                        (no payload)
    {"type": "shutdown"}                                      (no payload)

Responses (daemon → Swift), one per request:
    {"type": "ok",    ...request-specific fields...}          (usually no payload)
    {"type": "error", "code": str, "message": str}            (no payload)

Per-request response fields
---------------------------
    load_model  → {"model_id": str, "load_seconds": float}
    transcribe  → {"text": str, "audio_seconds": float, "transcribe_seconds": float}
    status      → {"ready": bool, "model_id": str|null, "version": str}
    shutdown    → {} (server then closes the connection)

Design notes
------------
* Single-client server. The Swift app is the only user; we don't bother with
  multiplexing or request IDs. Strict request/response order on one connection.
* `payload_len` lives in the header (not as a separate frame field) so that
  encoders/decoders only need to track one length prefix at the wire level.
* Big-endian for the length prefix because that's what every other binary
  protocol on a unix socket does. The float32 PCM payload itself is **little**
  endian to match Apple silicon native byte order — no swapping on either side.
"""

from __future__ import annotations

import json
import struct
import unicodedata
from dataclasses import dataclass
from typing import Awaitable, Callable

# Length prefix for the JSON header.
_HEADER_LEN_FMT = ">I"
_HEADER_LEN_BYTES = 4

# Sanity caps. The header is only metadata, so 1 MiB is preposterously large
# but still cheap to validate. The payload cap is 32 MiB (~8.7 minutes of
# float32 16 kHz mono), comfortably above the app's five-minute recording cap
# while preventing an IPC peer from exhausting unified memory.
MAX_HEADER_BYTES = 1 << 20
MAX_PAYLOAD_BYTES = 32 * 1024 * 1024
MAX_VOCABULARY_ENTRIES = 128
MAX_VOCABULARY_PHRASE_BYTES = 256


def normalize_vocabulary(value: object) -> list[str]:
    """Validate request vocabulary without including private phrases in errors."""
    if not isinstance(value, list):
        raise ValueError("vocabulary must be an array of strings")
    if len(value) > MAX_VOCABULARY_ENTRIES:
        raise ValueError("vocabulary must contain at most 128 entries")
    phrases: list[str] = []
    seen: set[str] = set()
    for phrase in value:
        if not isinstance(phrase, str):
            raise ValueError("vocabulary entries must be strings")
        if any(
            unicodedata.category(char).startswith("C") and not char.isspace()
            for char in phrase
        ):
            raise ValueError("vocabulary entries must not contain control characters")
        normalized = " ".join(phrase.split())
        if not normalized:
            raise ValueError("vocabulary entries must not be empty")
        if len(normalized.encode("utf-8")) > MAX_VOCABULARY_PHRASE_BYTES:
            raise ValueError("vocabulary entries must be at most 256 UTF-8 bytes")
        key = normalized.casefold()
        if key not in seen:
            phrases.append(normalized)
            seen.add(key)
    return phrases


class ProtocolError(Exception):
    """Raised on malformed frames, oversize fields, or short reads."""


@dataclass
class Message:
    """A decoded frame: parsed JSON header plus raw payload bytes."""

    header: dict
    payload: bytes

    @property
    def type(self) -> str:
        t = self.header.get("type", "")
        return t if isinstance(t, str) else ""


def encode_message(header: dict, payload: bytes = b"") -> bytes:
    """Serialize a single frame.

    `payload_len` is overwritten from `len(payload)` so callers don't have to
    keep them in sync.
    """
    h = dict(header)
    h["payload_len"] = len(payload)
    raw = json.dumps(h, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_HEADER_BYTES:
        raise ProtocolError(f"header too large: {len(raw)} bytes")
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"payload too large: {len(payload)} bytes")
    return struct.pack(_HEADER_LEN_FMT, len(raw)) + raw + payload


def _decode_header(raw: bytes) -> dict:
    try:
        h = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError as e:
        raise ProtocolError(f"header is not valid UTF-8: {e}") from e
    except json.JSONDecodeError as e:
        raise ProtocolError(f"header is not valid JSON: {e}") from e
    if not isinstance(h, dict):
        raise ProtocolError(
            f"header must be a JSON object, got {type(h).__name__}"
        )
    pl = h.get("payload_len", 0)
    if not isinstance(pl, int) or isinstance(pl, bool) or pl < 0:
        raise ProtocolError(f"bad payload_len: {pl!r}")
    if pl > MAX_PAYLOAD_BYTES:
        raise ProtocolError(f"payload_len too large: {pl}")
    return h


def read_message_sync(read_exact: Callable[[int], bytes]) -> Message:
    """Read one frame from a synchronous source.

    `read_exact(n)` must return exactly n bytes or raise. Use
    `make_sync_read_exact` for a socket helper.
    """
    head = read_exact(_HEADER_LEN_BYTES)
    (hlen,) = struct.unpack(_HEADER_LEN_FMT, head)
    if hlen == 0:
        raise ProtocolError("header_len is 0")
    if hlen > MAX_HEADER_BYTES:
        raise ProtocolError(f"header_len too large: {hlen}")
    raw = read_exact(hlen)
    h = _decode_header(raw)
    pl = int(h["payload_len"])
    payload = read_exact(pl) if pl else b""
    return Message(header=h, payload=payload)


async def read_message_async(
    read_exact: Callable[[int], Awaitable[bytes]],
) -> Message:
    """Async twin of `read_message_sync`."""
    head = await read_exact(_HEADER_LEN_BYTES)
    (hlen,) = struct.unpack(_HEADER_LEN_FMT, head)
    if hlen == 0:
        raise ProtocolError("header_len is 0")
    if hlen > MAX_HEADER_BYTES:
        raise ProtocolError(f"header_len too large: {hlen}")
    raw = await read_exact(hlen)
    h = _decode_header(raw)
    pl = int(h["payload_len"])
    payload = await read_exact(pl) if pl else b""
    return Message(header=h, payload=payload)


def make_sync_read_exact(sock) -> Callable[[int], bytes]:
    """Build a `read_exact` over a blocking socket-like with `.recv(n)`."""

    def _read(n: int) -> bytes:
        if n == 0:
            return b""
        buf = bytearray()
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ProtocolError(
                    f"connection closed with {n - len(buf)} of {n} bytes pending"
                )
            buf.extend(chunk)
        return bytes(buf)

    return _read
