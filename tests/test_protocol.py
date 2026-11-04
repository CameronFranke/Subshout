"""Frame encode/decode round-trips and malformed-input handling."""

from __future__ import annotations

import asyncio
import io
import json
import struct

import pytest

from shout_daemon.protocol import (
    MAX_HEADER_BYTES,
    MAX_PAYLOAD_BYTES,
    Message,
    ProtocolError,
    encode_message,
    normalize_vocabulary,
    read_message_async,
    read_message_sync,
)


def _reader_for(buf: bytes):
    """Return a sync read_exact callable backed by an in-memory buffer."""
    stream = io.BytesIO(buf)

    def _read(n: int) -> bytes:
        out = stream.read(n)
        if len(out) != n:
            raise ProtocolError(f"short read: wanted {n}, got {len(out)}")
        return out

    return _read


@pytest.mark.parametrize(
    "value",
    [None, "word", {}, [1], [None], [True], [""], [" \t\n"],
     ["bad\x00word"], ["bad\x7fword"], ["bad\u200bword"], ["\ud800"],
     ["a" * 257], ["é" * 129], ["word"] * 129],
)
def test_vocabulary_rejects_malformed_or_oversize_entries(value):
    with pytest.raises(ValueError, match="vocabulary"):
        normalize_vocabulary(value)


def test_vocabulary_normalizes_and_deduplicates():
    assert normalize_vocabulary([]) == []
    assert normalize_vocabulary(
        ["  New\t York\n", "new york", "Straße", "STRASSE", "Café"]
    ) == ["New York", "Straße", "Café"]


def test_vocabulary_accepts_exact_limits_after_normalization():
    assert len(normalize_vocabulary([str(i) for i in range(128)])) == 128
    assert normalize_vocabulary(["  " + "é" * 128 + "\n"]) == ["é" * 128]
    assert normalize_vocabulary(["a" * 256]) == ["a" * 256]


# ---------------------------------------------------------------------------- encode


def test_encode_overrides_payload_len_in_header():
    raw = encode_message({"type": "transcribe", "payload_len": 999}, payload=b"abcd")
    (hlen,) = struct.unpack(">I", raw[:4])
    header = json.loads(raw[4 : 4 + hlen].decode("utf-8"))
    assert header["payload_len"] == 4
    assert raw[4 + hlen :] == b"abcd"


def test_encode_zero_payload_omits_payload_bytes():
    raw = encode_message({"type": "status"})
    (hlen,) = struct.unpack(">I", raw[:4])
    assert len(raw) == 4 + hlen


def test_encode_rejects_oversize_header():
    big = {"type": "x", "blob": "a" * (MAX_HEADER_BYTES + 1)}
    with pytest.raises(ProtocolError, match="header too large"):
        encode_message(big)


# ---------------------------------------------------------------------------- decode


def test_round_trip_with_payload():
    payload = b"\x00\x00\x80?" * 4  # four float32 1.0s, just bytes here
    raw = encode_message(
        {"type": "transcribe", "sample_rate": 16000}, payload=payload
    )
    msg = read_message_sync(_reader_for(raw))
    assert msg.type == "transcribe"
    assert msg.header["sample_rate"] == 16000
    assert msg.header["payload_len"] == len(payload)
    assert msg.payload == payload


def test_round_trip_no_payload():
    raw = encode_message({"type": "status"})
    msg = read_message_sync(_reader_for(raw))
    assert msg.type == "status"
    assert msg.payload == b""


def test_decode_rejects_zero_header_len():
    with pytest.raises(ProtocolError, match="header_len is 0"):
        read_message_sync(_reader_for(struct.pack(">I", 0)))


def test_decode_rejects_oversize_header_len():
    with pytest.raises(ProtocolError, match="header_len too large"):
        read_message_sync(_reader_for(struct.pack(">I", MAX_HEADER_BYTES + 1)))


def test_decode_rejects_non_object_header():
    payload = json.dumps([1, 2, 3]).encode()
    raw = struct.pack(">I", len(payload)) + payload
    with pytest.raises(ProtocolError, match="JSON object"):
        read_message_sync(_reader_for(raw))


def test_decode_rejects_invalid_json():
    payload = b"{not json"
    raw = struct.pack(">I", len(payload)) + payload
    with pytest.raises(ProtocolError, match="not valid JSON"):
        read_message_sync(_reader_for(raw))


def test_decode_rejects_negative_payload_len():
    payload = json.dumps({"type": "x", "payload_len": -1}).encode()
    raw = struct.pack(">I", len(payload)) + payload
    with pytest.raises(ProtocolError, match="bad payload_len"):
        read_message_sync(_reader_for(raw))


def test_decode_rejects_huge_payload_len():
    payload = json.dumps(
        {"type": "x", "payload_len": MAX_PAYLOAD_BYTES + 1}
    ).encode()
    raw = struct.pack(">I", len(payload)) + payload
    with pytest.raises(ProtocolError, match="payload_len too large"):
        read_message_sync(_reader_for(raw))


def test_decode_rejects_bool_as_payload_len():
    # JSON `true` decodes to Python True, which is an int subclass; we reject.
    payload = json.dumps({"type": "x", "payload_len": True}).encode()
    raw = struct.pack(">I", len(payload)) + payload
    with pytest.raises(ProtocolError, match="bad payload_len"):
        read_message_sync(_reader_for(raw))


def test_short_read_in_payload_raises():
    raw = encode_message({"type": "x"}, payload=b"hello")
    truncated = raw[:-2]
    with pytest.raises(ProtocolError):
        read_message_sync(_reader_for(truncated))


# ---------------------------------------------------------------------------- async


def test_read_message_async_round_trips():
    raw = encode_message({"type": "status"})

    async def go() -> Message:
        stream = io.BytesIO(raw)

        async def read_exact(n: int) -> bytes:
            out = stream.read(n)
            if len(out) != n:
                raise ProtocolError("short")
            return out

        return await read_message_async(read_exact)

    msg = asyncio.run(go())
    assert msg.type == "status"


def test_message_type_handles_missing_or_non_string():
    assert Message(header={}, payload=b"").type == ""
    assert Message(header={"type": 7}, payload=b"").type == ""
    assert Message(header={"type": "ok"}, payload=b"").type == "ok"
