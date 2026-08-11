from __future__ import annotations

import hashlib
from pathlib import Path
import sys

import numpy as np
import pytest


EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_DIR))

from cross_photo_group_codec import (  # noqa: E402
    decode_mod16_residual,
    decode_protected_payload,
    decode_uvarint,
    encode_mod16_residual,
    encode_protected_payload,
    encode_uvarint,
    validate_backward_parent_map,
)


def test_uvarint_round_trip_and_truncation() -> None:
    for value in (0, 1, 127, 128, 16384, (1 << 63) - 1):
        encoded = encode_uvarint(value)
        decoded, consumed = decode_uvarint(encoded)
        assert decoded == value
        assert consumed == len(encoded)

    with pytest.raises(ValueError, match="truncated"):
        decode_uvarint(b"\x80")


def test_mod16_residual_preserves_every_int16_bit_pattern() -> None:
    parent_u16 = np.array(
        [0, 1, 32767, 32768, 65534, 65535], dtype=np.uint16
    )
    child_u16 = np.array(
        [65535, 32768, 32767, 1, 0, 65534], dtype=np.uint16
    )
    parent = parent_u16.view(np.int16).reshape(2, 3)
    child = child_u16.view(np.int16).reshape(2, 3)

    residual = encode_mod16_residual(child, parent)
    restored = decode_mod16_residual(residual, parent)

    assert residual.dtype == np.dtype("<u2")
    assert restored.dtype == np.dtype("<i2")
    assert restored.tobytes() == child.astype("<i2", copy=False).tobytes()


def test_protected_payload_round_trip_and_corruption_rejection() -> None:
    sections = (b"header", bytes(range(255)), b"parents")
    payload = encode_protected_payload("arm-a-child", sections)
    decoded = decode_protected_payload(payload, expected_kind="arm-a-child")
    assert decoded == sections
    assert hashlib.sha256(payload).hexdigest()

    corrupt = bytearray(payload)
    corrupt[len(corrupt) // 2] ^= 0x80
    with pytest.raises(ValueError, match="digest"):
        decode_protected_payload(bytes(corrupt), expected_kind="arm-a-child")
    with pytest.raises(ValueError):
        decode_protected_payload(payload[:-1], expected_kind="arm-a-child")
    with pytest.raises(ValueError, match="kind"):
        decode_protected_payload(payload, expected_kind="arm-b-child")


def test_parent_map_is_backward_and_group_local() -> None:
    # Three frames with two blocks each. 0xffffffff is the literal sentinel.
    parents = np.array(
        [0xFFFFFFFF, 0xFFFFFFFF, 0, 1, 2, 3], dtype=np.uint32
    )
    validate_backward_parent_map(
        parents,
        frame_block_offsets=(0, 2, 4, 6),
    )

    forward = parents.copy()
    forward[2] = 4
    with pytest.raises(ValueError, match="earlier"):
        validate_backward_parent_map(
            forward,
            frame_block_offsets=(0, 2, 4, 6),
        )

    with pytest.raises(ValueError, match="offset"):
        validate_backward_parent_map(
            parents,
            frame_block_offsets=(0, 3, 2, 6),
        )

