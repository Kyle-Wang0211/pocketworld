"""Exact, fail-closed primitives shared by the cross-photo A/B/C benchmark.

This module is deliberately independent from PocketWorld production code.  It
defines only reversible integer transforms and a small integrity-protected
container used by the host experiment.
"""

from __future__ import annotations

import hashlib
import hmac
import struct
from typing import Sequence

import numpy as np


_PAYLOAD_MAGIC = b"PWCGRP1\0"
_PAYLOAD_VERSION = 1
_DIGEST_BYTES = 32
LITERAL_PARENT = 0xFFFFFFFF


def encode_uvarint(value: int) -> bytes:
    """Encode a non-negative uint64 using canonical LEB128."""

    if value < 0 or value > 0xFFFFFFFFFFFFFFFF:
        raise ValueError("unsigned varint value is outside uint64")
    output = bytearray()
    while value >= 0x80:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)
    return bytes(output)


def decode_uvarint(data: bytes | memoryview, offset: int = 0) -> tuple[int, int]:
    """Decode one canonical uint64 varint and return value and bytes consumed."""

    view = memoryview(data)
    if offset < 0 or offset > len(view):
        raise ValueError("varint offset is outside payload")
    start = offset
    value = 0
    shift = 0
    while True:
        if offset >= len(view):
            raise ValueError("truncated varint")
        byte = int(view[offset])
        offset += 1
        if shift == 63 and byte > 1:
            raise ValueError("varint exceeds uint64")
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            consumed = offset - start
            if encode_uvarint(value) != bytes(view[start:offset]):
                raise ValueError("non-canonical varint")
            return value, consumed
        shift += 7
        if shift > 63:
            raise ValueError("varint exceeds uint64")


def _as_little_uint16(values: np.ndarray) -> np.ndarray:
    array = np.asarray(values)
    if array.dtype.kind not in ("i", "u") or array.dtype.itemsize != 2:
        raise ValueError("coefficient arrays must contain 16-bit integers")
    return np.ascontiguousarray(array, dtype="<i2").view("<u2")


def encode_mod16_residual(child: np.ndarray, parent: np.ndarray) -> np.ndarray:
    """Return the exact modulo-65536 difference of two int16 bit patterns."""

    child_u16 = _as_little_uint16(child)
    parent_u16 = _as_little_uint16(parent)
    if child_u16.shape != parent_u16.shape:
        raise ValueError("child and parent coefficient shapes differ")
    return np.subtract(child_u16, parent_u16, dtype=np.dtype("<u2"))


def decode_mod16_residual(residual: np.ndarray, parent: np.ndarray) -> np.ndarray:
    """Invert :func:`encode_mod16_residual` without arithmetic loss."""

    residual_u16 = _as_little_uint16(residual)
    parent_u16 = _as_little_uint16(parent)
    if residual_u16.shape != parent_u16.shape:
        raise ValueError("residual and parent coefficient shapes differ")
    restored_u16 = np.add(
        residual_u16,
        parent_u16,
        dtype=np.dtype("<u2"),
    )
    return np.ascontiguousarray(restored_u16).view("<i2")


def encode_protected_payload(kind: str, sections: Sequence[bytes]) -> bytes:
    """Encode a versioned section container followed by a SHA-256 digest."""

    kind_bytes = kind.encode("utf-8")
    if not kind_bytes or len(kind_bytes) > 255:
        raise ValueError("payload kind must use 1..255 UTF-8 bytes")
    if len(sections) > 0xFFFF:
        raise ValueError("payload has too many sections")
    normalized = tuple(bytes(section) for section in sections)
    output = bytearray(_PAYLOAD_MAGIC)
    output.extend(struct.pack("<H", _PAYLOAD_VERSION))
    output.append(len(kind_bytes))
    output.extend(kind_bytes)
    output.extend(struct.pack("<H", len(normalized)))
    for section in normalized:
        output.extend(struct.pack("<Q", len(section)))
    for section in normalized:
        output.extend(section)
    output.extend(hashlib.sha256(output).digest())
    return bytes(output)


def decode_protected_payload(
    payload: bytes,
    *,
    expected_kind: str,
) -> tuple[bytes, ...]:
    """Decode a payload only after validating structure, kind, and digest."""

    data = memoryview(payload)
    minimum = len(_PAYLOAD_MAGIC) + 2 + 1 + 2 + _DIGEST_BYTES
    if len(data) < minimum:
        raise ValueError("truncated protected payload")
    if bytes(data[: len(_PAYLOAD_MAGIC)]) != _PAYLOAD_MAGIC:
        raise ValueError("protected payload magic mismatch")
    stored_digest = bytes(data[-_DIGEST_BYTES:])
    calculated = hashlib.sha256(data[:-_DIGEST_BYTES]).digest()
    if not hmac.compare_digest(stored_digest, calculated):
        raise ValueError("protected payload digest mismatch")

    offset = len(_PAYLOAD_MAGIC)

    def take(size: int) -> bytes:
        nonlocal offset
        content_end = len(data) - _DIGEST_BYTES
        if size < 0 or offset + size > content_end:
            raise ValueError("truncated protected payload")
        value = bytes(data[offset : offset + size])
        offset += size
        return value

    version = struct.unpack("<H", take(2))[0]
    if version != _PAYLOAD_VERSION:
        raise ValueError("unsupported protected payload version")
    kind_size = take(1)[0]
    if kind_size == 0:
        raise ValueError("protected payload kind is empty")
    try:
        kind = take(kind_size).decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("protected payload kind is invalid UTF-8") from error
    if kind != expected_kind:
        raise ValueError(f"protected payload kind mismatch: {kind!r}")
    section_count = struct.unpack("<H", take(2))[0]
    sizes = [struct.unpack("<Q", take(8))[0] for _ in range(section_count)]
    sections = tuple(take(size) for size in sizes)
    if offset != len(data) - _DIGEST_BYTES:
        raise ValueError("protected payload has trailing bytes")
    return sections


def validate_backward_parent_map(
    parents: np.ndarray,
    *,
    frame_block_offsets: Sequence[int],
) -> None:
    """Reject references outside the group or into the current/future frame."""

    values = np.asarray(parents)
    if values.ndim != 1 or values.dtype.kind != "u" or values.dtype.itemsize != 4:
        raise ValueError("parent map must be a one-dimensional uint32 array")
    offsets = tuple(int(value) for value in frame_block_offsets)
    if len(offsets) < 2 or offsets[0] != 0 or offsets[-1] != len(values):
        raise ValueError("frame block offset coverage is invalid")
    if any(next_value <= value for value, next_value in zip(offsets, offsets[1:])):
        raise ValueError("frame block offsets must be strictly increasing")

    for frame_index, (start, end) in enumerate(zip(offsets, offsets[1:])):
        for parent in values[start:end]:
            parent_value = int(parent)
            if parent_value == LITERAL_PARENT:
                continue
            if frame_index == 0 or parent_value >= start:
                raise ValueError("parent must reference an earlier frame block")
