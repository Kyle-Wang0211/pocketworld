"""Canonical fail-closed storage for one 22-stage exact coefficient tile."""

from __future__ import annotations

import hashlib
from typing import Mapping, Sequence


MAGIC = b"PWTL1\0\0\0"
STREAM_COUNT = 22


def _encode_varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("varint value must be non-negative")
    output = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        output.append(byte | (0x80 if value else 0))
        if not value:
            return bytes(output)


def _decode_varint(payload: bytes, position: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if position >= len(payload) or shift > 63:
            raise ValueError("invalid tile stream varint")
        byte = payload[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, position
        shift += 7


def _one_stream(entry: Mapping[str, object]) -> bytes:
    strings = entry["strings"]
    if (
        not isinstance(strings, list)
        or len(strings) != 1
        or not isinstance(strings[0], list)
        or len(strings[0]) != 1
        or not isinstance(strings[0][0], bytes)
    ):
        raise ValueError("tile document requires one batch and one entropy stream")
    return strings[0][0]


def _flatten_encoded(encoded: Mapping[str, object]) -> list[bytes]:
    streams = [
        _one_stream(encoded["z_cbcr"]),
        _one_stream(encoded["z_y"]),
        _one_stream(encoded["cbcr_anchor"]),
        _one_stream(encoded["cbcr_non_anchor"]),
    ]
    for key in ("y1", "y234"):
        entries = encoded[key]
        if not isinstance(entries, list) or len(entries) != 9:
            raise ValueError(f"{key} must contain nine frequency groups")
        streams.extend(_one_stream(entry) for entry in entries)
    return streams


def encode_tile_document(
    encoded: Mapping[str, object] | Sequence[bytes],
) -> bytes:
    streams = (
        _flatten_encoded(encoded)
        if isinstance(encoded, Mapping)
        else [bytes(stream) for stream in encoded]
    )
    if len(streams) != STREAM_COUNT:
        raise ValueError("tile document requires exactly 22 entropy streams")
    payload = b"".join(_encode_varint(len(stream)) + stream for stream in streams)
    return MAGIC + hashlib.sha256(payload).digest() + payload


def decode_tile_document(document: bytes) -> dict[str, object]:
    if len(document) < len(MAGIC) + 32 or not document.startswith(MAGIC):
        raise ValueError("invalid tile stream envelope")
    expected_sha256 = document[len(MAGIC) : len(MAGIC) + 32]
    payload = document[len(MAGIC) + 32 :]
    if hashlib.sha256(payload).digest() != expected_sha256:
        raise ValueError("tile stream payload SHA-256 mismatch")
    streams: list[bytes] = []
    position = 0
    for _ in range(STREAM_COUNT):
        stream_bytes, position = _decode_varint(payload, position)
        if stream_bytes > len(payload) - position:
            raise ValueError("truncated tile entropy stream")
        streams.append(payload[position : position + stream_bytes])
        position += stream_bytes
    if position != len(payload):
        raise ValueError("unexpected trailing tile entropy bytes")

    def entry(stream: bytes, shape: tuple[int, int]) -> dict[str, object]:
        return {"strings": [[stream]], "shape": shape}

    return {
        "z_cbcr": entry(streams[0], (32, 32)),
        "z_y": entry(streams[1], (4, 4)),
        "cbcr_anchor": entry(streams[2], (64, 64)),
        "cbcr_non_anchor": entry(streams[3], (64, 64)),
        "y1": [entry(stream, (16, 16)) for stream in streams[4:13]],
        "y234": [entry(stream, (16, 16)) for stream in streams[13:22]],
    }
