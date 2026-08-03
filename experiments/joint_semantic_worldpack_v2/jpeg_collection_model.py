from __future__ import annotations

import hashlib
import io
import json
import struct
from dataclasses import dataclass
from itertools import product

import numpy as np

from jpeg_exact import ExactJpegFrame, make_exact_jpeg_frame


Q32 = 1 << 32
LOCAL_RADIUS_BLOCKS = 2
RANSAC_SEED = 20260803
RANSAC_ITERATIONS = 512
RANSAC_THRESHOLD_PIXELS = 4.0


class CollectionModelError(RuntimeError):
    pass


LOCAL_OFFSETS = tuple(
    sorted(
        product(range(-LOCAL_RADIUS_BLOCKS, LOCAL_RADIUS_BLOCKS + 1), repeat=2),
        key=lambda offset: (abs(offset[0]) + abs(offset[1]), offset[1], offset[0]),
    )
)


def _normalized_dlt(source: np.ndarray, destination: np.ndarray) -> np.ndarray:
    if source.shape != destination.shape or source.shape[0] < 4 or source.shape[1] != 2:
        raise CollectionModelError("homography fitting requires paired 2D points")

    def normalize(points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        center = points.mean(axis=0)
        centered = points - center
        mean_distance = np.sqrt(np.square(centered).sum(axis=1)).mean()
        if not np.isfinite(mean_distance) or mean_distance <= 1e-12:
            raise CollectionModelError("degenerate homography point set")
        scale = np.sqrt(2.0) / mean_distance
        transform = np.array(
            [
                [scale, 0.0, -scale * center[0]],
                [0.0, scale, -scale * center[1]],
                [0.0, 0.0, 1.0],
            ],
            dtype=np.float64,
        )
        homogeneous = np.column_stack((points, np.ones(len(points))))
        normalized = (transform @ homogeneous.T).T[:, :2]
        return normalized, transform

    source_normalized, source_transform = normalize(source)
    destination_normalized, destination_transform = normalize(destination)
    rows = []
    for (x, y), (u, v) in zip(
        source_normalized, destination_normalized, strict=True
    ):
        rows.append((-x, -y, -1.0, 0.0, 0.0, 0.0, u * x, u * y, u))
        rows.append((0.0, 0.0, 0.0, -x, -y, -1.0, v * x, v * y, v))
    matrix = np.asarray(rows, dtype=np.float64)
    if np.linalg.matrix_rank(matrix) < 8:
        raise CollectionModelError("degenerate homography sample")
    _, _, right = np.linalg.svd(matrix, full_matrices=True)
    normalized_homography = right[-1].reshape(3, 3)
    homography = (
        np.linalg.inv(destination_transform)
        @ normalized_homography
        @ source_transform
    )
    if abs(homography[2, 2]) <= 1e-15:
        raise CollectionModelError("homography normalization failed")
    homography /= homography[2, 2]
    return homography


def _squared_reprojection_errors(
    homography: np.ndarray, source: np.ndarray, destination: np.ndarray
) -> np.ndarray:
    homogeneous = np.column_stack((source, np.ones(len(source))))
    projected = (homography @ homogeneous.T).T
    denominator = projected[:, 2]
    valid = np.abs(denominator) > 1e-15
    coordinates = np.full_like(destination, np.inf, dtype=np.float64)
    coordinates[valid] = projected[valid, :2] / denominator[valid, None]
    return np.square(coordinates - destination).sum(axis=1)


def fit_homography_q32(
    child_points: np.ndarray,
    root_points: np.ndarray,
    *,
    seed: int = RANSAC_SEED,
    iterations: int = RANSAC_ITERATIONS,
    threshold_pixels: float = RANSAC_THRESHOLD_PIXELS,
) -> tuple[tuple[int, ...], int]:
    child = np.asarray(child_points, dtype=np.float64)
    root = np.asarray(root_points, dtype=np.float64)
    if child.shape != root.shape or child.ndim != 2 or child.shape[1] != 2:
        raise CollectionModelError("homography point arrays do not match")
    if len(child) < 4 or not np.isfinite(child).all() or not np.isfinite(root).all():
        raise CollectionModelError("homography input is invalid")

    generator = np.random.default_rng(seed)
    best_homography: np.ndarray | None = None
    best_inliers: np.ndarray | None = None
    best_count = -1
    best_squared_error = np.inf
    threshold_squared = threshold_pixels * threshold_pixels
    for _ in range(iterations):
        sample = generator.choice(len(child), size=4, replace=False)
        try:
            candidate = _normalized_dlt(child[sample], root[sample])
        except CollectionModelError:
            continue
        errors = _squared_reprojection_errors(candidate, child, root)
        inliers = errors <= threshold_squared
        count = int(inliers.sum())
        squared_error = float(errors[inliers].sum()) if count else np.inf
        if count > best_count or (
            count == best_count and squared_error < best_squared_error
        ):
            best_homography = candidate
            best_inliers = inliers
            best_count = count
            best_squared_error = squared_error
    if best_homography is None or best_inliers is None or best_count < 4:
        raise CollectionModelError("deterministic RANSAC found no homography")

    refined = _normalized_dlt(child[best_inliers], root[best_inliers])
    refined_errors = _squared_reprojection_errors(refined, child, root)
    refined_inliers = refined_errors <= threshold_squared
    if int(refined_inliers.sum()) >= 4 and not np.array_equal(
        refined_inliers, best_inliers
    ):
        refined = _normalized_dlt(child[refined_inliers], root[refined_inliers])
    refined /= refined[2, 2]
    quantized = np.rint(refined.reshape(-1) * Q32).astype(np.int64)
    quantized[8] = Q32
    return tuple(int(value) for value in quantized), int(refined_inliers.sum())


def _coefficient_components(frame: ExactJpegFrame) -> tuple[np.ndarray, ...]:
    flat = np.frombuffer(frame.coefficient_payload, dtype="<i2")
    result = []
    offset = 0
    for count in frame.coefficient_counts:
        result.append(flat[offset : offset + count].reshape(-1, 64))
        offset += count
    if offset != len(flat):
        raise CollectionModelError("coefficient frame accounting mismatch")
    return tuple(result)


def _base_parent_coordinates(
    child_shape: tuple[int, int],
    root_shape: tuple[int, int],
    child_luma_shape: tuple[int, int],
    root_luma_shape: tuple[int, int],
    homography_q32: tuple[int, ...],
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    child_height, child_width = child_shape
    root_height, root_width = root_shape
    child_scale_y = child_luma_shape[0] // child_height
    child_scale_x = child_luma_shape[1] // child_width
    root_scale_y = root_luma_shape[0] // root_height
    root_scale_x = root_luma_shape[1] // root_width
    if min(child_scale_x, child_scale_y, root_scale_x, root_scale_y) < 1:
        raise CollectionModelError("invalid JPEG component sampling geometry")

    row, column = np.indices((child_height, child_width), dtype=np.int64)
    x2 = ((column.reshape(-1) * 2 + 1) * 8 * child_scale_x).astype(np.int64)
    y2 = ((row.reshape(-1) * 2 + 1) * 8 * child_scale_y).astype(np.int64)
    h = np.asarray(homography_q32, dtype=np.int64)
    numerator_x = h[0] * x2 + h[1] * y2 + 2 * h[2]
    numerator_y = h[3] * x2 + h[4] * y2 + 2 * h[5]
    denominator = h[6] * x2 + h[7] * y2 + 2 * h[8]
    negative = denominator < 0
    numerator_x = np.where(negative, -numerator_x, numerator_x)
    numerator_y = np.where(negative, -numerator_y, numerator_y)
    denominator = np.where(negative, -denominator, denominator)
    valid = (denominator > 0) & (numerator_x >= 0) & (numerator_y >= 0)
    safe_denominator = np.where(valid, denominator, 1)
    root_columns = numerator_x // (safe_denominator * 8 * root_scale_x)
    root_rows = numerator_y // (safe_denominator * 8 * root_scale_y)
    valid &= (
        (root_columns >= 0)
        & (root_columns < root_width)
        & (root_rows >= 0)
        & (root_rows < root_height)
    )
    return root_rows, root_columns, valid


def _predict_component(
    root: np.ndarray,
    child: np.ndarray,
    root_shape: tuple[int, int],
    child_shape: tuple[int, int],
    root_luma_shape: tuple[int, int],
    child_luma_shape: tuple[int, int],
    homography_q32: tuple[int, ...],
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    root32 = np.asarray(root, dtype=np.int32)
    child32 = np.asarray(child, dtype=np.int32)
    root_rows, root_columns, base_valid = _base_parent_coordinates(
        child_shape,
        root_shape,
        child_luma_shape,
        root_luma_shape,
        homography_q32,
    )
    root_height, root_width = root_shape
    best_cost = np.abs(child32).sum(axis=1, dtype=np.int64)
    best_selector = np.zeros(len(child32), dtype=np.uint8)

    for selector, (delta_x, delta_y) in enumerate(LOCAL_OFFSETS, start=1):
        rows = root_rows + delta_y
        columns = root_columns + delta_x
        valid = (
            base_valid
            & (rows >= 0)
            & (rows < root_height)
            & (columns >= 0)
            & (columns < root_width)
        )
        predicted = np.zeros_like(child32)
        indexes = rows[valid] * root_width + columns[valid]
        predicted[valid] = root32[indexes]
        cost = np.abs(child32 - predicted).sum(axis=1, dtype=np.int64)
        improve = valid & (cost < best_cost)
        best_cost[improve] = cost[improve]
        best_selector[improve] = selector

    predicted = np.zeros_like(child32)
    for selector, (delta_x, delta_y) in enumerate(LOCAL_OFFSETS, start=1):
        chosen = best_selector == selector
        if not chosen.any():
            continue
        rows = root_rows[chosen] + delta_y
        columns = root_columns[chosen] + delta_x
        predicted[chosen] = root32[rows * root_width + columns]

    inter_cost = np.abs(child32 - predicted).sum(axis=0, dtype=np.int64)
    intra_cost = np.abs(child32).sum(axis=0, dtype=np.int64)
    frequency_selectors = (inter_cost <= intra_cost).astype(np.uint8)
    predicted[:, frequency_selectors == 0] = 0
    residual = child32 - predicted
    return best_selector, frequency_selectors, residual


@dataclass(frozen=True)
class EncodedChild:
    parent_ordinal: int
    child_ordinal: int
    child_to_root_homography_q32: tuple[int, ...]
    homography_inlier_count: int
    root_component_shapes: tuple[tuple[int, int], ...]
    child_component_shapes: tuple[tuple[int, int], ...]
    local_block_selectors: bytes
    frequency_selectors: bytes
    residual_int32_le: bytes
    child_restart_interval: int
    child_header: bytes
    child_source_bytes: int
    child_source_sha256: str
    jpeg_tool_sha256: str
    expected_frame_sha256: str

    @property
    def residual_count(self) -> int:
        return len(self.residual_int32_le) // 4

    def canonical_bytes(self) -> bytes:
        metadata = json.dumps(
            {
                "schema": "pw_quantized_homography_local_dct_v1",
                "parent_ordinal": self.parent_ordinal,
                "child_ordinal": self.child_ordinal,
                "homography_q32": self.child_to_root_homography_q32,
                "homography_inlier_count": self.homography_inlier_count,
                "root_component_shapes": self.root_component_shapes,
                "child_component_shapes": self.child_component_shapes,
                "child_restart_interval": self.child_restart_interval,
                "child_source_bytes": self.child_source_bytes,
                "child_source_sha256": self.child_source_sha256,
                "jpeg_tool_sha256": self.jpeg_tool_sha256,
                "expected_frame_sha256": self.expected_frame_sha256,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        output = io.BytesIO()
        output.write(b"PWPREDICT\x01")
        for payload in (
            metadata,
            self.child_header,
            self.local_block_selectors,
            self.frequency_selectors,
            self.residual_int32_le,
        ):
            output.write(struct.pack("<Q", len(payload)))
            output.write(payload)
        return output.getvalue()


def encode_child_frames(
    *,
    parent_ordinal: int,
    child_ordinal: int,
    root: ExactJpegFrame,
    child: ExactJpegFrame,
    child_to_root_homography_q32: tuple[int, ...],
    homography_inlier_count: int,
) -> EncodedChild:
    if parent_ordinal >= child_ordinal:
        raise CollectionModelError("photo dependencies must point backward")
    if len(root.component_shapes) != len(child.component_shapes):
        raise CollectionModelError("root and child JPEG component counts differ")
    if len(child_to_root_homography_q32) != 9:
        raise CollectionModelError("homography must contain nine Q32 values")
    root_components = _coefficient_components(root)
    child_components = _coefficient_components(child)
    local_selectors = bytearray()
    frequency_selectors = bytearray()
    residuals = []
    for root_component, child_component, root_shape, child_shape in zip(
        root_components,
        child_components,
        root.component_shapes,
        child.component_shapes,
        strict=True,
    ):
        local, frequency, residual = _predict_component(
            root_component,
            child_component,
            root_shape,
            child_shape,
            root.component_shapes[0],
            child.component_shapes[0],
            child_to_root_homography_q32,
        )
        local_selectors.extend(local.tobytes())
        frequency_selectors.extend(frequency.tobytes())
        residuals.append(np.asarray(residual, dtype="<i4").reshape(-1))
    residual_payload = np.concatenate(residuals).astype("<i4", copy=False).tobytes()
    return EncodedChild(
        parent_ordinal=parent_ordinal,
        child_ordinal=child_ordinal,
        child_to_root_homography_q32=child_to_root_homography_q32,
        homography_inlier_count=homography_inlier_count,
        root_component_shapes=root.component_shapes,
        child_component_shapes=child.component_shapes,
        local_block_selectors=bytes(local_selectors),
        frequency_selectors=bytes(frequency_selectors),
        residual_int32_le=residual_payload,
        child_restart_interval=child.restart_interval,
        child_header=child.header,
        child_source_bytes=child.source_bytes,
        child_source_sha256=child.source_sha256,
        jpeg_tool_sha256=child.tool_sha256,
        expected_frame_sha256=hashlib.sha256(child.serialized).hexdigest(),
    )


def decode_child_frame(root: ExactJpegFrame, encoded: EncodedChild) -> ExactJpegFrame:
    if encoded.parent_ordinal >= encoded.child_ordinal:
        raise CollectionModelError("encoded dependency is not backward")
    if root.component_shapes != encoded.root_component_shapes:
        raise CollectionModelError("root component geometry changed")
    root_components = _coefficient_components(root)
    selector_offset = 0
    frequency_offset = 0
    residual_offset = 0
    coefficient_payloads = []
    residual_flat = np.frombuffer(encoded.residual_int32_le, dtype="<i4")
    for root_component, root_shape, child_shape in zip(
        root_components,
        encoded.root_component_shapes,
        encoded.child_component_shapes,
        strict=True,
    ):
        block_count = child_shape[0] * child_shape[1]
        selectors = np.frombuffer(
            encoded.local_block_selectors[selector_offset : selector_offset + block_count],
            dtype=np.uint8,
        )
        selector_offset += block_count
        frequency = np.frombuffer(
            encoded.frequency_selectors[frequency_offset : frequency_offset + 64],
            dtype=np.uint8,
        )
        frequency_offset += 64
        if len(frequency) != 64 or not np.isin(frequency, (0, 1)).all():
            raise CollectionModelError("invalid frequency selector")
        if not np.isin(selectors, np.arange(len(LOCAL_OFFSETS) + 1)).all():
            raise CollectionModelError("invalid local selector")

        root_rows, root_columns, base_valid = _base_parent_coordinates(
            child_shape,
            root_shape,
            encoded.child_component_shapes[0],
            encoded.root_component_shapes[0],
            encoded.child_to_root_homography_q32,
        )
        predicted = np.zeros((block_count, 64), dtype=np.int32)
        root32 = np.asarray(root_component, dtype=np.int32)
        root_width = root_shape[1]
        for selector, (delta_x, delta_y) in enumerate(LOCAL_OFFSETS, start=1):
            chosen = selectors == selector
            if not chosen.any():
                continue
            rows = root_rows[chosen] + delta_y
            columns = root_columns[chosen] + delta_x
            valid = (
                base_valid[chosen]
                & (rows >= 0)
                & (rows < root_shape[0])
                & (columns >= 0)
                & (columns < root_shape[1])
            )
            if not valid.all():
                raise CollectionModelError("local selector points outside root")
            predicted[chosen] = root32[rows * root_width + columns]
        predicted[:, frequency == 0] = 0
        coefficient_count = block_count * 64
        residual = residual_flat[
            residual_offset : residual_offset + coefficient_count
        ].reshape(block_count, 64)
        residual_offset += coefficient_count
        restored = predicted.astype(np.int64) + residual.astype(np.int64)
        if (restored < -32768).any() or (restored > 32767).any():
            raise CollectionModelError("coefficient residual overflow")
        coefficient_payloads.append(restored.astype("<i2").tobytes())
    if (
        selector_offset != len(encoded.local_block_selectors)
        or frequency_offset != len(encoded.frequency_selectors)
        or residual_offset != len(residual_flat)
    ):
        raise CollectionModelError("prediction payload accounting mismatch")
    frame = make_exact_jpeg_frame(
        source_bytes=encoded.child_source_bytes,
        source_sha256=encoded.child_source_sha256,
        tool_sha256=encoded.jpeg_tool_sha256,
        restart_interval=encoded.child_restart_interval,
        header=encoded.child_header,
        component_shapes=encoded.child_component_shapes,
        coefficient_payload=b"".join(coefficient_payloads),
    )
    if hashlib.sha256(frame.serialized).hexdigest() != encoded.expected_frame_sha256:
        raise CollectionModelError("decoded exact JPEG frame identity mismatch")
    return frame

