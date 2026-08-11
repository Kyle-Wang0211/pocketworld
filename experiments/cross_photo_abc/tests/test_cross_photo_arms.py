from __future__ import annotations

from pathlib import Path
import sys

import cv2
import numpy as np


EXPERIMENT_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_DIR))

from cross_photo_arms import (  # noqa: E402
    build_faiss_parent_maps,
    decode_global_component,
    decode_local_component,
    dense_flow_grid,
    encode_global_component,
    encode_local_component,
    pack_residual_planes,
    unpack_residual_planes,
)
from cross_photo_group_codec import LITERAL_PARENT, validate_backward_parent_map  # noqa: E402


def test_dense_flow_direction_is_target_to_parent() -> None:
    rng = np.random.default_rng(20260802)
    target = rng.integers(0, 256, size=(192, 256), dtype=np.uint8)
    parent = cv2.warpAffine(
        target,
        np.float32([[1, 0, 4], [0, 1, 0]]),
        (target.shape[1], target.shape[0]),
        borderMode=cv2.BORDER_REFLECT,
    )

    grid = dense_flow_grid(target, parent, image_scale=0.5, spacing=32)
    central_dx = grid.quantized[1:-1, 1:-1, 0].astype(np.float32) / 8.0

    assert 2.5 < float(np.median(central_dx)) < 5.5
    assert grid.source_width == 256
    assert grid.source_height == 192
    assert grid.spacing == 32


def test_local_selector_residual_restores_all_coefficient_bits() -> None:
    parent = np.arange(16 * 64, dtype=np.int32).reshape(16, 64)
    parent = ((parent * 31 + 32760) & 0xFFFF).astype(np.uint16).view(np.int16)
    base_x, base_y = np.meshgrid(np.arange(4), np.arange(4))
    source_indices = (base_y.ravel() * 4 + base_x.ravel()).astype(np.int64)
    child = parent[source_indices].copy()
    child.view(np.uint16)[:, 3] ^= np.uint16(0xFFFF)

    selectors, residual = encode_local_component(
        child,
        parent,
        base_x=base_x.ravel(),
        base_y=base_y.ravel(),
        parent_width_blocks=4,
        parent_height_blocks=4,
        radius=2,
    )
    restored = decode_local_component(
        selectors,
        residual,
        parent,
        base_x=base_x.ravel(),
        base_y=base_y.ravel(),
        parent_width_blocks=4,
        parent_height_blocks=4,
        radius=2,
    )

    assert restored.tobytes() == child.astype("<i2", copy=False).tobytes()


def test_faiss_maps_only_to_earlier_frames_and_restores_exactly() -> None:
    rng = np.random.default_rng(7)
    root = rng.integers(-400, 401, size=(64, 64), dtype=np.int16)
    second = np.roll(root, 9, axis=0).copy()
    second.view(np.uint16)[:, 7] += np.uint16(1)
    third = np.roll(second, 5, axis=0).copy()
    third.view(np.uint16)[:, 13] ^= np.uint16(0x8000)
    frames = (root, second, third)

    maps = build_faiss_parent_maps(
        frames,
        seed=20260802,
        requested_nlist=8,
        nprobe=4,
        max_training_vectors=256,
    )
    parents = np.concatenate(maps).astype(np.uint32, copy=False)
    validate_backward_parent_map(
        parents,
        frame_block_offsets=(0, 64, 128, 192),
    )
    assert np.all(maps[0] == LITERAL_PARENT)

    decoded = [root]
    for frame, parent_map in zip(frames[1:], maps[1:], strict=True):
        pool = np.concatenate(decoded, axis=0)
        residual = encode_global_component(frame, pool, parent_map)
        restored = decode_global_component(residual, pool, parent_map)
        assert restored.tobytes() == frame.astype("<i2", copy=False).tobytes()
        decoded.append(restored)


def test_residual_plane_packing_is_bit_exact() -> None:
    values = np.arange(19 * 64, dtype=np.uint16).reshape(19, 64)
    values ^= np.uint16(0xA55A)
    residual = values.view(np.int16)

    packed = pack_residual_planes(residual)
    restored = unpack_residual_planes(packed, block_count=19)

    assert restored.dtype == np.dtype("<u2")
    assert restored.tobytes() == values.astype("<u2", copy=False).tobytes()
