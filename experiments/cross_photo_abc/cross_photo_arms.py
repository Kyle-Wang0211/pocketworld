"""Encoder-only predictors for the exact cross-photo JPEG benchmark."""

from __future__ import annotations

from dataclasses import dataclass
import math
import struct
from typing import Sequence

import cv2
import numpy as np

from cross_photo_group_codec import (
    LITERAL_PARENT,
    decode_mod16_residual,
    decode_uvarint,
    encode_mod16_residual,
    encode_uvarint,
)


_FLOW_MAGIC = b"PWFLW1\0\0"
_FLOW_QUANTIZATION = 8


@dataclass(frozen=True)
class FlowGrid:
    source_width: int
    source_height: int
    spacing: int
    quantized: np.ndarray

    def __post_init__(self) -> None:
        values = np.asarray(self.quantized)
        if self.source_width <= 0 or self.source_height <= 0 or self.spacing <= 0:
            raise ValueError("flow-grid dimensions and spacing must be positive")
        if values.ndim != 3 or values.shape[2] != 2 or values.dtype != np.int16:
            raise ValueError("flow grid must have shape HxWx2 and dtype int16")
        if values.shape[0] < 2 or values.shape[1] < 2:
            raise ValueError("flow grid must contain at least 2x2 samples")

    def to_bytes(self) -> bytes:
        height, width, _ = self.quantized.shape
        header = struct.pack(
            "<8sIIIIII",
            _FLOW_MAGIC,
            1,
            self.source_width,
            self.source_height,
            self.spacing,
            width,
            height,
        )
        return header + np.ascontiguousarray(self.quantized, dtype="<i2").tobytes()

    @staticmethod
    def from_bytes(data: bytes) -> "FlowGrid":
        header_size = struct.calcsize("<8sIIIIII")
        if len(data) < header_size:
            raise ValueError("truncated flow grid")
        magic, version, source_width, source_height, spacing, width, height = (
            struct.unpack("<8sIIIIII", data[:header_size])
        )
        if magic != _FLOW_MAGIC or version != 1 or width < 2 or height < 2:
            raise ValueError("unsupported flow-grid header")
        expected = header_size + width * height * 2 * 2
        if len(data) != expected:
            raise ValueError("flow-grid byte length mismatch")
        quantized = (
            np.frombuffer(data[header_size:], dtype="<i2")
            .reshape(height, width, 2)
            .copy()
        )
        return FlowGrid(source_width, source_height, spacing, quantized)


def dense_flow_grid(
    target_gray: np.ndarray,
    parent_gray: np.ndarray,
    *,
    image_scale: float,
    spacing: int,
) -> FlowGrid:
    """Estimate target-to-parent DIS flow and store a quantized sparse grid."""

    target = np.asarray(target_gray)
    parent = np.asarray(parent_gray)
    if (
        target.ndim != 2
        or parent.ndim != 2
        or target.shape != parent.shape
        or target.dtype != np.uint8
        or parent.dtype != np.uint8
    ):
        raise ValueError("flow inputs must be same-shaped uint8 luma images")
    if not 0 < image_scale <= 1 or spacing <= 0:
        raise ValueError("invalid dense-flow scale or spacing")
    source_height, source_width = target.shape
    scaled_width = max(16, int(round(source_width * image_scale)))
    scaled_height = max(16, int(round(source_height * image_scale)))
    target_small = cv2.resize(
        target,
        (scaled_width, scaled_height),
        interpolation=cv2.INTER_AREA,
    )
    parent_small = cv2.resize(
        parent,
        (scaled_width, scaled_height),
        interpolation=cv2.INTER_AREA,
    )
    estimator = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    flow_small = estimator.calc(target_small, parent_small, None)
    grid_width = max(2, math.ceil((source_width - 1) / spacing) + 1)
    grid_height = max(2, math.ceil((source_height - 1) / spacing) + 1)
    grid = cv2.resize(
        flow_small,
        (grid_width, grid_height),
        interpolation=cv2.INTER_LINEAR,
    ).astype(np.float64)
    grid[..., 0] *= source_width / scaled_width
    grid[..., 1] *= source_height / scaled_height
    quantized = np.clip(
        np.rint(grid * _FLOW_QUANTIZATION),
        np.iinfo(np.int16).min,
        np.iinfo(np.int16).max,
    ).astype("<i2")
    return FlowGrid(source_width, source_height, spacing, quantized)


def _sample_flow(grid: FlowGrid, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    values = grid.quantized.astype(np.float64) / _FLOW_QUANTIZATION
    height, width, _ = values.shape
    gx = np.clip(x / max(1, grid.source_width - 1) * (width - 1), 0, width - 1)
    gy = np.clip(y / max(1, grid.source_height - 1) * (height - 1), 0, height - 1)
    x0 = np.floor(gx).astype(np.int64)
    y0 = np.floor(gy).astype(np.int64)
    x1 = np.minimum(x0 + 1, width - 1)
    y1 = np.minimum(y0 + 1, height - 1)
    wx = (gx - x0)[:, None]
    wy = (gy - y0)[:, None]
    top = values[y0, x0] * (1 - wx) + values[y0, x1] * wx
    bottom = values[y1, x0] * (1 - wx) + values[y1, x1] * wx
    return top * (1 - wy) + bottom * wy


def flow_parent_block_bases(
    grid: FlowGrid,
    *,
    target_width_blocks: int,
    target_height_blocks: int,
    parent_width_blocks: int,
    parent_height_blocks: int,
) -> tuple[np.ndarray, np.ndarray]:
    """Map target block centers through the stored flow grid."""

    if min(
        target_width_blocks,
        target_height_blocks,
        parent_width_blocks,
        parent_height_blocks,
    ) <= 0:
        raise ValueError("block dimensions must be positive")
    block_y, block_x = np.meshgrid(
        np.arange(target_height_blocks, dtype=np.float64),
        np.arange(target_width_blocks, dtype=np.float64),
        indexing="ij",
    )
    pixel_x = (block_x.ravel() + 0.5) * grid.source_width / target_width_blocks
    pixel_y = (block_y.ravel() + 0.5) * grid.source_height / target_height_blocks
    flow = _sample_flow(grid, pixel_x, pixel_y)
    parent_x = np.rint(
        (pixel_x + flow[:, 0]) * parent_width_blocks / grid.source_width - 0.5
    ).astype(np.int32)
    parent_y = np.rint(
        (pixel_y + flow[:, 1]) * parent_height_blocks / grid.source_height - 0.5
    ).astype(np.int32)
    return parent_x, parent_y


def _validated_coefficients(values: np.ndarray, *, name: str) -> np.ndarray:
    coefficients = np.asarray(values)
    if (
        coefficients.ndim != 2
        or coefficients.shape[1] != 64
        or coefficients.dtype.kind not in ("i", "u")
        or coefficients.dtype.itemsize != 2
    ):
        raise ValueError(f"{name} coefficients must have shape Nx64 and int16 bits")
    return np.ascontiguousarray(coefficients, dtype="<i2")


def pack_residual_planes(residual: np.ndarray) -> bytes:
    """Byte-shuffle exact uint16 residuals by DCT coefficient plane."""

    values = _validated_coefficients(residual, name="residual").view("<u2")
    low = (values & np.uint16(0xFF)).astype(np.uint8).T
    high = (values >> np.uint16(8)).astype(np.uint8).T
    return np.ascontiguousarray(low).tobytes() + np.ascontiguousarray(high).tobytes()


def unpack_residual_planes(data: bytes, *, block_count: int) -> np.ndarray:
    if block_count < 0 or len(data) != block_count * 64 * 2:
        raise ValueError("residual-plane byte length mismatch")
    plane_bytes = block_count * 64
    low = np.frombuffer(data[:plane_bytes], dtype=np.uint8).reshape(64, block_count)
    high = np.frombuffer(data[plane_bytes:], dtype=np.uint8).reshape(64, block_count)
    values = low.T.astype(np.uint16) | (high.T.astype(np.uint16) << np.uint16(8))
    return np.ascontiguousarray(values, dtype="<u2")


def _local_parent_indices(
    selectors: np.ndarray,
    *,
    base_x: np.ndarray,
    base_y: np.ndarray,
    parent_width_blocks: int,
    parent_height_blocks: int,
    radius: int,
) -> np.ndarray:
    selector_values = np.asarray(selectors, dtype=np.uint8)
    bx = np.asarray(base_x, dtype=np.int64)
    by = np.asarray(base_y, dtype=np.int64)
    if selector_values.ndim != 1 or bx.shape != selector_values.shape or by.shape != bx.shape:
        raise ValueError("local selector and base-coordinate shapes differ")
    side = radius * 2 + 1
    candidate_count = side * side
    if radius < 0 or candidate_count >= LITERAL_PARENT:
        raise ValueError("invalid local search radius")
    literal = selector_values == 255
    if np.any((selector_values >= candidate_count) & ~literal):
        raise ValueError("local selector is outside neighborhood")
    dx = (selector_values.astype(np.int64) % side) - radius
    dy = (selector_values.astype(np.int64) // side) - radius
    px = bx + dx
    py = by + dy
    invalid = (
        (px < 0)
        | (px >= parent_width_blocks)
        | (py < 0)
        | (py >= parent_height_blocks)
    ) & ~literal
    if np.any(invalid):
        raise ValueError("local selector maps outside parent component")
    indices = py * parent_width_blocks + px
    indices[literal] = -1
    return indices


def encode_local_component(
    child: np.ndarray,
    parent: np.ndarray,
    *,
    base_x: np.ndarray,
    base_y: np.ndarray,
    parent_width_blocks: int,
    parent_height_blocks: int,
    radius: int,
) -> tuple[np.ndarray, np.ndarray]:
    child_coefficients = _validated_coefficients(child, name="child")
    parent_coefficients = _validated_coefficients(parent, name="parent")
    if len(parent_coefficients) != parent_width_blocks * parent_height_blocks:
        raise ValueError("parent coefficient count differs from layout")
    bx = np.asarray(base_x, dtype=np.int64)
    by = np.asarray(base_y, dtype=np.int64)
    if bx.shape != (len(child_coefficients),) or by.shape != bx.shape:
        raise ValueError("base-coordinate count differs from child blocks")
    side = radius * 2 + 1
    if radius < 0 or side * side > 255:
        raise ValueError("invalid local search radius")

    best_score = np.full(len(child_coefficients), np.iinfo(np.int64).max, np.int64)
    selectors = np.full(len(child_coefficients), 255, dtype=np.uint8)
    best_indices = np.full(len(child_coefficients), -1, dtype=np.int64)
    child_i32 = child_coefficients.astype(np.int32)
    for selector, (dy, dx) in enumerate(
        (dy, dx)
        for dy in range(-radius, radius + 1)
        for dx in range(-radius, radius + 1)
    ):
        px = bx + dx
        py = by + dy
        valid = (
            (px >= 0)
            & (px < parent_width_blocks)
            & (py >= 0)
            & (py < parent_height_blocks)
        )
        positions = np.flatnonzero(valid)
        if len(positions) == 0:
            continue
        indices = py[positions] * parent_width_blocks + px[positions]
        difference = child_i32[positions] - parent_coefficients[indices].astype(np.int32)
        score = np.abs(difference).sum(axis=1, dtype=np.int64)
        improved = score < best_score[positions]
        selected_positions = positions[improved]
        best_score[selected_positions] = score[improved]
        selectors[selected_positions] = selector
        best_indices[selected_positions] = indices[improved]

    prediction = np.zeros_like(child_coefficients)
    predicted = best_indices >= 0
    prediction[predicted] = parent_coefficients[best_indices[predicted]]
    return selectors, encode_mod16_residual(child_coefficients, prediction)


def decode_local_component(
    selectors: np.ndarray,
    residual: np.ndarray,
    parent: np.ndarray,
    *,
    base_x: np.ndarray,
    base_y: np.ndarray,
    parent_width_blocks: int,
    parent_height_blocks: int,
    radius: int,
) -> np.ndarray:
    parent_coefficients = _validated_coefficients(parent, name="parent")
    indices = _local_parent_indices(
        selectors,
        base_x=base_x,
        base_y=base_y,
        parent_width_blocks=parent_width_blocks,
        parent_height_blocks=parent_height_blocks,
        radius=radius,
    )
    residual_values = np.asarray(residual)
    if residual_values.shape != (len(indices), 64):
        raise ValueError("local residual shape differs from selector count")
    prediction = np.zeros((len(indices), 64), dtype="<i2")
    predicted = indices >= 0
    prediction[predicted] = parent_coefficients[indices[predicted]]
    return decode_mod16_residual(residual_values, prediction)


def _uniform_training_sample(
    frames: Sequence[np.ndarray],
    maximum: int,
) -> np.ndarray:
    counts = np.array([len(frame) for frame in frames], dtype=np.int64)
    offsets = np.concatenate((np.array([0], dtype=np.int64), np.cumsum(counts)))
    total = int(offsets[-1])
    sample_count = min(total, maximum)
    global_indices = np.linspace(0, total - 1, sample_count, dtype=np.int64)
    sample = np.empty((sample_count, 64), dtype=np.float32)
    frame_indices = np.searchsorted(offsets[1:], global_indices, side="right")
    for frame_index in np.unique(frame_indices):
        selected = frame_indices == frame_index
        local = global_indices[selected] - offsets[frame_index]
        sample[selected] = frames[int(frame_index)][local].astype(np.float32)
    return sample


def build_faiss_parent_maps(
    frames: Sequence[np.ndarray],
    *,
    seed: int,
    requested_nlist: int,
    nprobe: int,
    max_training_vectors: int,
    query_batch: int = 32768,
) -> tuple[np.ndarray, ...]:
    """Select one earlier-frame DCT block for every non-root block."""

    if not frames or requested_nlist <= 0 or nprobe <= 0 or max_training_vectors <= 0:
        raise ValueError("invalid Faiss forest configuration")
    normalized = tuple(
        _validated_coefficients(frame, name=f"frame {index}")
        for index, frame in enumerate(frames)
    )
    if any(len(frame) == 0 for frame in normalized):
        raise ValueError("Faiss frames cannot be empty")

    import faiss  # Loaded only by arm B.

    training = _uniform_training_sample(normalized, max_training_vectors)
    nlist = min(requested_nlist, max(1, len(training) // 39))
    quantizer = faiss.IndexFlatL2(64)
    index = faiss.IndexIVFFlat(quantizer, 64, nlist, faiss.METRIC_L2)
    index.cp.seed = int(seed)
    index.cp.niter = 10
    index.nprobe = min(nprobe, nlist)
    index.train(training)

    maps: list[np.ndarray] = [
        np.full(len(normalized[0]), LITERAL_PARENT, dtype=np.uint32)
    ]
    index.add(normalized[0].astype(np.float32))
    for frame in normalized[1:]:
        parent_map = np.empty(len(frame), dtype=np.uint32)
        vectors = frame.astype(np.float32)
        for start in range(0, len(frame), query_batch):
            end = min(start + query_batch, len(frame))
            _, neighbors = index.search(vectors[start:end], 1)
            selected = neighbors[:, 0]
            if np.any(selected < 0) or np.any(selected >= index.ntotal):
                raise RuntimeError("Faiss failed to return an earlier parent")
            parent_map[start:end] = selected.astype(np.uint32)
        maps.append(parent_map)
        index.add(vectors)
    return tuple(maps)


def encode_global_component(
    child: np.ndarray,
    parent_pool: np.ndarray,
    parent_map: np.ndarray,
) -> np.ndarray:
    child_coefficients = _validated_coefficients(child, name="child")
    pool = _validated_coefficients(parent_pool, name="parent pool")
    parents = np.asarray(parent_map)
    if parents.shape != (len(child_coefficients),) or parents.dtype.kind != "u":
        raise ValueError("global parent-map shape or type is invalid")
    if np.any(parents >= len(pool)):
        raise ValueError("global parent map references outside earlier pool")
    return encode_mod16_residual(child_coefficients, pool[parents.astype(np.int64)])


def decode_global_component(
    residual: np.ndarray,
    parent_pool: np.ndarray,
    parent_map: np.ndarray,
) -> np.ndarray:
    pool = _validated_coefficients(parent_pool, name="parent pool")
    parents = np.asarray(parent_map)
    residual_values = np.asarray(residual)
    if (
        parents.ndim != 1
        or parents.dtype.kind != "u"
        or residual_values.shape != (len(parents), 64)
        or np.any(parents >= len(pool))
    ):
        raise ValueError("global residual or parent map is invalid")
    return decode_mod16_residual(
        residual_values,
        pool[parents.astype(np.int64)],
    )


def encode_parent_deltas(parent_map: np.ndarray, *, current_start: int) -> bytes:
    parents = np.asarray(parent_map)
    if parents.ndim != 1 or parents.dtype.kind != "u" or current_start < 0:
        raise ValueError("invalid parent map or current block start")
    output = bytearray()
    for block_index, parent in enumerate(parents):
        current = current_start + block_index
        parent_value = int(parent)
        if parent_value >= current_start or parent_value >= current:
            raise ValueError("parent delta must reference an earlier frame")
        output.extend(encode_uvarint(current - parent_value))
    return bytes(output)


def decode_parent_deltas(
    data: bytes,
    *,
    current_start: int,
    count: int,
) -> np.ndarray:
    if current_start < 0 or count < 0:
        raise ValueError("invalid parent-delta dimensions")
    parents = np.empty(count, dtype=np.uint32)
    offset = 0
    for block_index in range(count):
        delta, consumed = decode_uvarint(data, offset)
        offset += consumed
        current = current_start + block_index
        if delta == 0 or delta > current:
            raise ValueError("parent delta does not reference an earlier block")
        parent = current - delta
        if parent >= current_start:
            raise ValueError("parent delta does not reference an earlier frame")
        parents[block_index] = parent
    if offset != len(data):
        raise ValueError("parent-delta stream has trailing bytes")
    return parents
