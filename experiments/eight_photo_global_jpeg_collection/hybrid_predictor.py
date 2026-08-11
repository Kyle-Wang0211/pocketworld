from __future__ import annotations

from dataclasses import dataclass, replace

import numpy as np


Q20 = 1 << 20
LOW_FREQUENCIES = np.array((0, 1, 8, 16, 9, 2, 3, 10, 17, 24), dtype=np.int64)
MODE_ZERO = 0
MODE_GLOBAL = 1
MODE_LOCAL_SEARCH = 2
MODE_LEFT = 3
MODE_TOP = 4
VALID_MODES = frozenset((MODE_ZERO, MODE_GLOBAL, MODE_LOCAL_SEARCH, MODE_LEFT, MODE_TOP))


class PredictorError(RuntimeError):
    pass


@dataclass(frozen=True)
class GeometryCandidates:
    global_parent_indexes: np.ndarray
    local_parent_indexes: np.ndarray
    parent_width: int
    parent_height: int
    child_width: int
    child_height: int

    def __post_init__(self) -> None:
        expected = self.child_width * self.child_height
        if min(
            self.parent_width,
            self.parent_height,
            self.child_width,
            self.child_height,
        ) <= 0:
            raise PredictorError("component dimensions must be positive")
        global_indexes = np.asarray(self.global_parent_indexes, dtype=np.int32)
        local_indexes = np.asarray(self.local_parent_indexes, dtype=np.int32)
        if global_indexes.shape != (expected,) or local_indexes.shape != (expected,):
            raise PredictorError("geometry map length does not match child blocks")
        object.__setattr__(self, "global_parent_indexes", global_indexes)
        object.__setattr__(self, "local_parent_indexes", local_indexes)


@dataclass(frozen=True)
class EncodedComponent:
    parent_width: int
    parent_height: int
    child_width: int
    child_height: int
    global_parent_indexes: tuple[int, ...]
    local_parent_indexes: tuple[int, ...]
    scale_q20: tuple[int, ...]
    bias_q20: tuple[int, ...]
    frequency_enabled: bytes
    modes: bytes
    motion_dx: tuple[int, ...]
    motion_dy: tuple[int, ...]
    residual_int16_le: bytes

    @property
    def block_count(self) -> int:
        return self.child_width * self.child_height

    def with_modes(self, modes: bytes) -> "EncodedComponent":
        return replace(self, modes=modes)


def apply_affine_q20(
    values: np.ndarray,
    scale_q20: np.ndarray,
    bias_q20: np.ndarray,
) -> np.ndarray:
    source = np.asarray(values, dtype=np.int64)
    scale = np.asarray(scale_q20, dtype=np.int64)
    bias = np.asarray(bias_q20, dtype=np.int64)
    if source.shape[-1] != len(scale) or scale.shape != bias.shape:
        raise PredictorError("affine model width mismatch")
    numerator = source * scale + bias
    return (numerator + Q20 // 2) // Q20


def _fit_affine_q20(parent: np.ndarray, child: np.ndarray, indexes: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    valid = (indexes >= 0) & (indexes < len(parent))
    scale = np.full(64, Q20, dtype=np.int64)
    bias = np.zeros(64, dtype=np.int64)
    if int(np.count_nonzero(valid)) < 4:
        return scale, bias
    x = parent[indexes[valid]].astype(np.float64)
    y = child[valid].astype(np.float64)
    x_mean = x.mean(axis=0)
    y_mean = y.mean(axis=0)
    variance = np.sum((x - x_mean) ** 2, axis=0)
    covariance = np.sum((x - x_mean) * (y - y_mean), axis=0)
    candidate_scale = np.divide(
        covariance,
        variance,
        out=np.ones(64, dtype=np.float64),
        where=variance > 0,
    )
    candidate_bias = y_mean - candidate_scale * x_mean
    candidate_scale_q20 = np.rint(candidate_scale * Q20).astype(np.int64)
    candidate_bias_q20 = np.rint(candidate_bias * Q20).astype(np.int64)
    candidate_prediction = apply_affine_q20(
        parent[indexes[valid]], candidate_scale_q20, candidate_bias_q20
    )
    identity_error = np.abs(y.astype(np.int64) - x.astype(np.int64)).sum(axis=0)
    candidate_error = np.abs(y.astype(np.int64) - candidate_prediction).sum(axis=0)
    accepted = (
        (candidate_scale >= 0.75)
        & (candidate_scale <= 1.25)
        & (candidate_error < identity_error)
    )
    scale[accepted] = candidate_scale_q20[accepted]
    bias[accepted] = candidate_bias_q20[accepted]
    return scale, bias


def _offsets(radius: int) -> tuple[tuple[int, int], ...]:
    if radius < 0 or radius > 127:
        raise PredictorError("search radius must be between zero and 127")
    return tuple(
        sorted(
            (
                (delta_x, delta_y)
                for delta_y in range(-radius, radius + 1)
                for delta_x in range(-radius, radius + 1)
            ),
            key=lambda value: (
                abs(value[0]) + abs(value[1]),
                value[1],
                value[0],
            ),
        )
    )


def _safe_parent_indexes(indexes: np.ndarray, parent_blocks: int) -> tuple[np.ndarray, np.ndarray]:
    valid = (indexes >= 0) & (indexes < parent_blocks)
    return np.where(valid, indexes, 0), valid


def _low_cost(target: np.ndarray, predicted: np.ndarray) -> np.ndarray:
    return np.abs(
        target[:, LOW_FREQUENCIES].astype(np.int64)
        - predicted[:, LOW_FREQUENCIES].astype(np.int64)
    ).sum(axis=1)


def encode_component(
    parent_coefficients: np.ndarray,
    child_coefficients: np.ndarray,
    geometry: GeometryCandidates,
    *,
    search_radius: int,
) -> EncodedComponent:
    parent = np.asarray(parent_coefficients, dtype=np.int16)
    child = np.asarray(child_coefficients, dtype=np.int16)
    if parent.ndim != 2 or parent.shape[1] != 64:
        raise PredictorError("parent coefficients must have shape N x 64")
    if child.shape != (geometry.child_width * geometry.child_height, 64):
        raise PredictorError("child coefficients do not match component geometry")
    if len(parent) != geometry.parent_width * geometry.parent_height:
        raise PredictorError("parent coefficients do not match component geometry")

    scale, bias = _fit_affine_q20(parent, child, geometry.global_parent_indexes)
    blocks = len(child)
    modes = np.full(blocks, MODE_ZERO, dtype=np.uint8)
    motion_dx = np.zeros(blocks, dtype=np.int16)
    motion_dy = np.zeros(blocks, dtype=np.int16)
    best_cost = np.abs(child[:, LOW_FREQUENCIES].astype(np.int64)).sum(axis=1)

    global_safe, global_valid = _safe_parent_indexes(
        geometry.global_parent_indexes, len(parent)
    )
    global_prediction = apply_affine_q20(parent[global_safe], scale, bias)
    global_cost = _low_cost(child, global_prediction)
    improve = global_valid & (global_cost < best_cost)
    modes[improve] = MODE_GLOBAL
    best_cost[improve] = global_cost[improve]

    local_base = geometry.local_parent_indexes.astype(np.int64)
    base_rows = local_base // geometry.parent_width
    base_columns = local_base % geometry.parent_width
    local_valid_base = (local_base >= 0) & (local_base < len(parent))
    for delta_x, delta_y in _offsets(search_radius):
        rows = base_rows + delta_y
        columns = base_columns + delta_x
        valid = (
            local_valid_base
            & (rows >= 0)
            & (rows < geometry.parent_height)
            & (columns >= 0)
            & (columns < geometry.parent_width)
        )
        indexes = np.where(valid, rows * geometry.parent_width + columns, 0)
        prediction = apply_affine_q20(parent[indexes], scale, bias)
        cost = _low_cost(child, prediction)
        improve = valid & (cost < best_cost)
        modes[improve] = MODE_LOCAL_SEARCH
        motion_dx[improve] = delta_x
        motion_dy[improve] = delta_y
        best_cost[improve] = cost[improve]

    rows, columns = np.indices(
        (geometry.child_height, geometry.child_width), dtype=np.int64
    )
    flat_rows = rows.reshape(-1)
    flat_columns = columns.reshape(-1)
    left_indexes = np.maximum(np.arange(blocks, dtype=np.int64) - 1, 0)
    left_valid = flat_columns > 0
    left_cost = _low_cost(child, child[left_indexes])
    improve = left_valid & (left_cost < best_cost)
    modes[improve] = MODE_LEFT
    best_cost[improve] = left_cost[improve]

    top_indexes = np.maximum(
        np.arange(blocks, dtype=np.int64) - geometry.child_width, 0
    )
    top_valid = flat_rows > 0
    top_cost = _low_cost(child, child[top_indexes])
    improve = top_valid & (top_cost < best_cost)
    modes[improve] = MODE_TOP

    predicted = np.zeros(child.shape, dtype=np.int64)
    chosen = modes == MODE_GLOBAL
    predicted[chosen] = global_prediction[chosen]
    for delta_x, delta_y in _offsets(search_radius):
        chosen = (
            (modes == MODE_LOCAL_SEARCH)
            & (motion_dx == delta_x)
            & (motion_dy == delta_y)
        )
        if not np.any(chosen):
            continue
        rows = base_rows[chosen] + delta_y
        columns = base_columns[chosen] + delta_x
        indexes = rows * geometry.parent_width + columns
        predicted[chosen] = apply_affine_q20(parent[indexes], scale, bias)
    chosen = modes == MODE_LEFT
    predicted[chosen] = child[left_indexes[chosen]]
    chosen = modes == MODE_TOP
    predicted[chosen] = child[top_indexes[chosen]]

    residual64 = child.astype(np.int64) - predicted
    inter_error = np.abs(residual64).sum(axis=0)
    zero_error = np.abs(child.astype(np.int64)).sum(axis=0)
    frequency_enabled = inter_error < zero_error
    unsafe = np.any((residual64 < -32768) | (residual64 > 32767), axis=0)
    frequency_enabled[unsafe] = False
    predicted[:, ~frequency_enabled] = 0
    residual64 = child.astype(np.int64) - predicted
    if np.any((residual64 < -32768) | (residual64 > 32767)):
        raise PredictorError("exact residual exceeds int16")

    return EncodedComponent(
        parent_width=geometry.parent_width,
        parent_height=geometry.parent_height,
        child_width=geometry.child_width,
        child_height=geometry.child_height,
        global_parent_indexes=tuple(int(value) for value in geometry.global_parent_indexes),
        local_parent_indexes=tuple(int(value) for value in geometry.local_parent_indexes),
        scale_q20=tuple(int(value) for value in scale),
        bias_q20=tuple(int(value) for value in bias),
        frequency_enabled=frequency_enabled.astype(np.uint8).tobytes(),
        modes=modes.tobytes(),
        motion_dx=tuple(int(value) for value in motion_dx),
        motion_dy=tuple(int(value) for value in motion_dy),
        residual_int16_le=residual64.astype("<i2").tobytes(),
    )


def decode_component(parent_coefficients: np.ndarray, encoded: EncodedComponent) -> np.ndarray:
    parent = np.asarray(parent_coefficients, dtype=np.int16)
    if parent.shape != (encoded.parent_width * encoded.parent_height, 64):
        raise PredictorError("parent coefficients do not match encoded geometry")
    blocks = encoded.block_count
    if (
        len(encoded.global_parent_indexes) != blocks
        or len(encoded.local_parent_indexes) != blocks
        or len(encoded.modes) != blocks
        or len(encoded.motion_dx) != blocks
        or len(encoded.motion_dy) != blocks
        or len(encoded.frequency_enabled) != 64
        or len(encoded.scale_q20) != 64
        or len(encoded.bias_q20) != 64
        or len(encoded.residual_int16_le) != blocks * 64 * 2
    ):
        raise PredictorError("encoded component length mismatch")
    modes = np.frombuffer(encoded.modes, dtype=np.uint8)
    if any(int(mode) not in VALID_MODES for mode in modes):
        raise PredictorError("encoded component contains an invalid mode")
    scale = np.asarray(encoded.scale_q20, dtype=np.int64)
    bias = np.asarray(encoded.bias_q20, dtype=np.int64)
    enabled = np.frombuffer(encoded.frequency_enabled, dtype=np.uint8)
    if np.any(enabled > 1):
        raise PredictorError("encoded frequency mask is invalid")
    residual = np.frombuffer(encoded.residual_int16_le, dtype="<i2").reshape(blocks, 64)
    global_indexes = np.asarray(encoded.global_parent_indexes, dtype=np.int64)
    local_indexes = np.asarray(encoded.local_parent_indexes, dtype=np.int64)
    motion_dx = np.asarray(encoded.motion_dx, dtype=np.int64)
    motion_dy = np.asarray(encoded.motion_dy, dtype=np.int64)
    restored = np.zeros((blocks, 64), dtype=np.int16)

    for block in range(blocks):
        mode = int(modes[block])
        prediction = np.zeros(64, dtype=np.int64)
        if mode == MODE_GLOBAL:
            parent_index = int(global_indexes[block])
            if not 0 <= parent_index < len(parent):
                raise PredictorError("global parent index exceeds component")
            prediction = apply_affine_q20(parent[parent_index], scale, bias)
        elif mode == MODE_LOCAL_SEARCH:
            base = int(local_indexes[block])
            if not 0 <= base < len(parent):
                raise PredictorError("local parent index exceeds component")
            row, column = divmod(base, encoded.parent_width)
            row += int(motion_dy[block])
            column += int(motion_dx[block])
            if not (0 <= row < encoded.parent_height and 0 <= column < encoded.parent_width):
                raise PredictorError("local motion exceeds component")
            prediction = apply_affine_q20(
                parent[row * encoded.parent_width + column], scale, bias
            )
        elif mode == MODE_LEFT:
            if block % encoded.child_width == 0:
                raise PredictorError("left mode crosses a component row")
            prediction = restored[block - 1].astype(np.int64)
        elif mode == MODE_TOP:
            if block < encoded.child_width:
                raise PredictorError("top mode crosses component boundary")
            prediction = restored[block - encoded.child_width].astype(np.int64)
        prediction[enabled == 0] = 0
        value = prediction + residual[block].astype(np.int64)
        if np.any((value < -32768) | (value > 32767)):
            raise PredictorError("restored coefficient exceeds int16")
        restored[block] = value.astype(np.int16)
    return restored

