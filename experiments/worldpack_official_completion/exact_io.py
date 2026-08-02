"""Canonical byte frames used by every codec arm in this experiment."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct


_MAGIC = b"PWEF"
_VERSION = 1
_HEADER = struct.Struct("<4sBBHIQQQ32s")


@dataclass(frozen=True)
class ExactFrame:
    stream_type: str
    element_width: int
    count: int
    ordinal: int
    payload: bytes

    def __post_init__(self) -> None:
        encoded_type = self.stream_type.encode("utf-8")
        if not encoded_type or len(encoded_type) > 255:
            raise ValueError("stream type must contain 1 to 255 UTF-8 bytes")
        if self.element_width <= 0:
            raise ValueError("element width must be positive")
        if self.count < 0 or self.ordinal < 0:
            raise ValueError("count and ordinal must be non-negative")
        if len(self.payload) != self.element_width * self.count:
            raise ValueError("payload length does not match typed element count")

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.payload).hexdigest()


def encode_frame(frame: ExactFrame) -> bytes:
    encoded_type = frame.stream_type.encode("utf-8")
    payload_sha = hashlib.sha256(frame.payload).digest()
    header = _HEADER.pack(
        _MAGIC,
        _VERSION,
        len(encoded_type),
        0,
        frame.element_width,
        frame.count,
        frame.ordinal,
        len(frame.payload),
        payload_sha,
    )
    return header + encoded_type + frame.payload


def decode_frame(encoded: bytes) -> ExactFrame:
    if len(encoded) < _HEADER.size:
        raise ValueError("exact frame is truncated")
    (
        magic,
        version,
        type_length,
        reserved,
        element_width,
        count,
        ordinal,
        payload_length,
        payload_sha,
    ) = _HEADER.unpack_from(encoded)
    if magic != _MAGIC or version != _VERSION or reserved != 0:
        raise ValueError("exact frame header is invalid")
    expected_length = _HEADER.size + type_length + payload_length
    if expected_length != len(encoded):
        raise ValueError("exact frame length is invalid")
    try:
        stream_type = encoded[
            _HEADER.size : _HEADER.size + type_length
        ].decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("exact frame stream type is invalid UTF-8") from error
    payload = encoded[_HEADER.size + type_length :]
    if payload_length != element_width * count:
        raise ValueError("exact frame typed length is inconsistent")
    if hashlib.sha256(payload).digest() != payload_sha:
        raise ValueError("exact frame payload SHA-256 mismatch")
    return ExactFrame(
        stream_type=stream_type,
        element_width=element_width,
        count=count,
        ordinal=ordinal,
        payload=payload,
    )

