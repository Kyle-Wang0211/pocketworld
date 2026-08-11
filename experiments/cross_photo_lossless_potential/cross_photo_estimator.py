from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import struct
from typing import Iterable, Sequence

import numpy as np


REQUIRED_RESULT_KEYS = (
    "photo_ratio",
    "exactness_failures",
    "input_hash_failures",
    "valid_sparse_projections",
    "random_access_group_overflow",
    "source_jpeg_bytes",
    "archive_bytes",
    "mapped_block_fraction",
    "encode_elapsed_ms",
    "decode_elapsed_ms",
    "peak_rss_bytes",
)

_ZIGZAG = np.array(
    (
        0,
        1,
        8,
        16,
        9,
        2,
        3,
        10,
        17,
        24,
        32,
        25,
        18,
        11,
        4,
        5,
        12,
        19,
        26,
        33,
        40,
        48,
        41,
        34,
        27,
        20,
        13,
        6,
        7,
        14,
        21,
        28,
        35,
        42,
        49,
        56,
        57,
        50,
        43,
        36,
        29,
        22,
        15,
        23,
        30,
        37,
        44,
        51,
        58,
        59,
        52,
        45,
        38,
        31,
        39,
        46,
        53,
        60,
        61,
        54,
        47,
        55,
        62,
        63,
    ),
    dtype=np.int32,
)


@dataclass(frozen=True)
class SampleItem:
    index: int
    frame_id: str
    name: str
    path: Path
    bytes: int


@dataclass(frozen=True)
class CoefficientComponent:
    width_blocks: int
    height_blocks: int
    coefficients: np.ndarray

    def __post_init__(self) -> None:
        expected_shape = (self.width_blocks * self.height_blocks, 64)
        if self.width_blocks <= 0 or self.height_blocks <= 0:
            raise ValueError("coefficient component dimensions must be positive")
        if np.asarray(self.coefficients).shape != expected_shape:
            raise ValueError(
                f"coefficient component must have shape {expected_shape}"
            )


@dataclass(frozen=True)
class JpegCoefficientData:
    restart_interval: int
    header: bytes
    components: tuple[CoefficientComponent, ...]

    def __post_init__(self) -> None:
        if not 0 <= self.restart_interval <= 0xFFFFFFFF:
            raise ValueError("restart interval exceeds uint32")
        if not self.header:
            raise ValueError("JPEG header cannot be empty")
        if not self.components:
            raise ValueError("JPEG must contain coefficient components")


@dataclass(frozen=True)
class ArchiveFrame:
    index: int
    name: str
    source_bytes: int
    source_sha256: str
    jpeg: JpegCoefficientData

    def __post_init__(self) -> None:
        if self.index < 0:
            raise ValueError("frame index cannot be negative")
        if not self.name:
            raise ValueError("frame name cannot be empty")
        if self.source_bytes <= 0:
            raise ValueError("source bytes must be positive")
        if len(self.source_sha256) != 64:
            raise ValueError("source SHA-256 must contain 64 hex characters")
        try:
            bytes.fromhex(self.source_sha256)
        except ValueError as error:
            raise ValueError("source SHA-256 is not hexadecimal") from error


class _BinaryReader:
    def __init__(self, data: bytes) -> None:
        self._data = memoryview(data)
        self._offset = 0

    def bytes(self, size: int) -> bytes:
        if size < 0 or size > len(self._data) - self._offset:
            raise ValueError("truncated binary payload")
        value = bytes(self._data[self._offset : self._offset + size])
        self._offset += size
        return value

    def u32(self) -> int:
        return struct.unpack("<I", self.bytes(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.bytes(8))[0]

    def require_end(self) -> None:
        if self._offset != len(self._data):
            raise ValueError("binary payload has trailing bytes")


def _append_u32(output: bytearray, value: int) -> None:
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError("value exceeds uint32")
    output.extend(struct.pack("<I", value))


def _append_u64(output: bytearray, value: int) -> None:
    if not 0 <= value <= 0xFFFFFFFFFFFFFFFF:
        raise ValueError("value exceeds uint64")
    output.extend(struct.pack("<Q", value))


def parse_pwc(data: bytes) -> JpegCoefficientData:
    reader = _BinaryReader(data)
    if reader.bytes(8) != b"PWCJPEG1":
        raise ValueError("PWC magic mismatch")
    if reader.u32() != 1:
        raise ValueError("unsupported PWC version")
    restart_interval = reader.u32()
    component_count = reader.u32()
    header_size = reader.u64()
    if not 1 <= component_count <= 10:
        raise ValueError("invalid PWC component count")
    layouts: list[tuple[int, int, int]] = []
    for _ in range(component_count):
        width_blocks = reader.u32()
        height_blocks = reader.u32()
        coefficient_count = reader.u64()
        expected = width_blocks * height_blocks * 64
        if (
            width_blocks == 0
            or height_blocks == 0
            or coefficient_count != expected
        ):
            raise ValueError("invalid PWC component dimensions")
        layouts.append((width_blocks, height_blocks, coefficient_count))
    header = reader.bytes(header_size)
    components: list[CoefficientComponent] = []
    for width_blocks, height_blocks, coefficient_count in layouts:
        raw = reader.bytes(coefficient_count * 2)
        coefficients = (
            np.frombuffer(raw, dtype="<i2")
            .reshape(width_blocks * height_blocks, 64)
            .copy()
        )
        components.append(
            CoefficientComponent(
                width_blocks=width_blocks,
                height_blocks=height_blocks,
                coefficients=coefficients,
            )
        )
    reader.require_end()
    return JpegCoefficientData(
        restart_interval=restart_interval,
        header=header,
        components=tuple(components),
    )


def serialize_pwc(jpeg: JpegCoefficientData) -> bytes:
    output = bytearray(b"PWCJPEG1")
    _append_u32(output, 1)
    _append_u32(output, jpeg.restart_interval)
    _append_u32(output, len(jpeg.components))
    _append_u64(output, len(jpeg.header))
    for component in jpeg.components:
        _append_u32(output, component.width_blocks)
        _append_u32(output, component.height_blocks)
        _append_u64(output, component.width_blocks * component.height_blocks * 64)
    output.extend(jpeg.header)
    for component in jpeg.components:
        output.extend(
            np.asarray(component.coefficients, dtype="<i2").tobytes(order="C")
        )
    return bytes(output)


def select_consecutive_sample(
    bundle_path: Path,
    photos_directory: Path,
    minimum_bytes: int,
) -> list[SampleItem]:
    decoded = json.loads(bundle_path.read_text(encoding="utf-8"))
    selected: list[SampleItem] = []
    total = 0
    for index, frame in enumerate(decoded["frames"]):
        name = str(frame["highresFilename"])
        path = photos_directory / name
        size = path.stat().st_size
        selected.append(
            SampleItem(
                index=index,
                frame_id=str(frame["id"]),
                name=name,
                path=path,
                bytes=size,
            )
        )
        total += size
        if total >= minimum_bytes:
            break
    if total < minimum_bytes:
        raise ValueError("photo bundle does not contain the requested sample bytes")
    return selected


def make_groups(items: Sequence[int], group_size: int) -> list[list[int]]:
    if group_size <= 0:
        raise ValueError("group_size must be positive")
    return [
        list(items[start : start + group_size])
        for start in range(0, len(items), group_size)
    ]


def adjacent_pairs(items: Sequence[object]) -> list[tuple[object, object]]:
    return list(zip(items[:-1], items[1:], strict=True))


def ratio_threshold_impossible(
    *,
    source_total_bytes: int,
    archive_bytes_so_far: int,
    minimum_ratio: float,
) -> bool:
    if source_total_bytes <= 0 or archive_bytes_so_far <= 0:
        raise ValueError("source and archive bytes must be positive")
    if minimum_ratio <= 0:
        raise ValueError("minimum ratio must be positive")
    return source_total_bytes / archive_bytes_so_far < minimum_ratio


def _quaternion_rotation(quaternion_wxyz: Sequence[float]) -> np.ndarray:
    w, x, y, z = map(float, quaternion_wxyz)
    norm = math.sqrt(w * w + x * x + y * y + z * z)
    if norm == 0:
        raise ValueError("zero quaternion")
    w, x, y, z = w / norm, x / norm, y / norm, z / norm
    return np.array(
        (
            (
                1 - 2 * (y * y + z * z),
                2 * (x * y - z * w),
                2 * (x * z + y * w),
            ),
            (
                2 * (x * y + z * w),
                1 - 2 * (x * x + z * z),
                2 * (y * z - x * w),
            ),
            (
                2 * (x * z - y * w),
                2 * (y * z + x * w),
                1 - 2 * (x * x + y * y),
            ),
        ),
        dtype=np.float64,
    )


def load_registered_poses(path: Path) -> dict[int, np.ndarray]:
    decoded = json.loads(path.read_text(encoding="utf-8"))
    poses: dict[int, np.ndarray] = {}
    for entry in decoded["poses"]:
        if not entry.get("registered", False):
            continue
        pose = np.eye(4, dtype=np.float64)
        pose[:3, :3] = _quaternion_rotation(entry["quat_wxyz"])
        pose[:3, 3] = np.asarray(entry["t"], dtype=np.float64)
        poses[int(entry["frame_id"])] = pose
    return poses


def load_binary_ply_xyz(path: Path) -> np.ndarray:
    data = path.read_bytes()
    marker = b"end_header\n"
    header_end = data.find(marker)
    if header_end < 0:
        raise ValueError("PLY end_header is missing")
    header_end += len(marker)
    header = data[:header_end].decode("ascii")
    if "format binary_little_endian 1.0" not in header:
        raise ValueError("only binary little-endian PLY is supported")
    vertex_line = next(
        (line for line in header.splitlines() if line.startswith("element vertex ")),
        None,
    )
    if vertex_line is None:
        raise ValueError("PLY vertex count is missing")
    vertex_count = int(vertex_line.rsplit(" ", 1)[1])
    expected_properties = (
        "property float x",
        "property float y",
        "property float z",
        "property uchar red",
        "property uchar green",
        "property uchar blue",
    )
    for property_line in expected_properties:
        if property_line not in header:
            raise ValueError(f"unsupported PLY property layout: {property_line}")
    dtype = np.dtype(
        [
            ("x", "<f4"),
            ("y", "<f4"),
            ("z", "<f4"),
            ("red", "u1"),
            ("green", "u1"),
            ("blue", "u1"),
        ]
    )
    vertices = np.frombuffer(data, dtype=dtype, count=vertex_count, offset=header_end)
    if len(vertices) != vertex_count:
        raise ValueError("truncated PLY vertex payload")
    return np.column_stack((vertices["x"], vertices["y"], vertices["z"])).astype(
        np.float64
    )


def project_point(
    world_to_camera: np.ndarray,
    intrinsics: Sequence[float],
    point_xyz: np.ndarray,
) -> tuple[float, float, float] | None:
    point = np.append(np.asarray(point_xyz, dtype=np.float64), 1.0)
    camera = np.asarray(world_to_camera, dtype=np.float64) @ point
    depth = float(camera[2])
    if depth <= 0:
        return None
    fx, fy, cx, cy = map(float, intrinsics)
    return (
        fx * float(camera[0]) / depth + cx,
        fy * float(camera[1]) / depth + cy,
        depth,
    )


def project_points(
    world_to_camera: np.ndarray,
    intrinsics: Sequence[float],
    points_xyz: np.ndarray,
    image_width: int,
    image_height: int,
) -> tuple[np.ndarray, np.ndarray]:
    rotation = world_to_camera[:3, :3]
    translation = world_to_camera[:3, 3]
    camera = points_xyz @ rotation.T + translation
    depth = camera[:, 2]
    valid = depth > 0
    fx, fy, cx, cy = map(float, intrinsics)
    xy = np.empty((len(points_xyz), 2), dtype=np.float64)
    xy[:, 0] = fx * camera[:, 0] / np.where(valid, depth, 1.0) + cx
    xy[:, 1] = fy * camera[:, 1] / np.where(valid, depth, 1.0) + cy
    valid &= (xy[:, 0] >= 0) & (xy[:, 0] < image_width)
    valid &= (xy[:, 1] >= 0) & (xy[:, 1] < image_height)
    return xy, valid


def vote_block_map(
    target_blocks: np.ndarray,
    reference_blocks: np.ndarray,
    *,
    target_width_blocks: int,
    target_height_blocks: int,
    reference_width_blocks: int,
    reference_height_blocks: int,
) -> tuple[np.ndarray, int]:
    if target_blocks.shape != reference_blocks.shape or target_blocks.ndim != 2:
        raise ValueError("target and reference block arrays must have shape Nx2")
    mapping = np.empty(
        (target_height_blocks, target_width_blocks, 2),
        dtype=np.int32,
    )
    for y in range(target_height_blocks):
        mapping[y, :, 0] = np.minimum(
            np.arange(target_width_blocks),
            reference_width_blocks - 1,
        )
        mapping[y, :, 1] = min(y, reference_height_blocks - 1)

    votes: dict[tuple[int, int], dict[tuple[int, int], int]] = {}
    for target, reference in zip(target_blocks, reference_blocks, strict=True):
        tx, ty = map(int, target)
        rx, ry = map(int, reference)
        if not (0 <= tx < target_width_blocks and 0 <= ty < target_height_blocks):
            continue
        if not (
            0 <= rx < reference_width_blocks
            and 0 <= ry < reference_height_blocks
        ):
            continue
        target_key = (tx, ty)
        reference_key = (rx, ry)
        per_target = votes.setdefault(target_key, {})
        per_target[reference_key] = per_target.get(reference_key, 0) + 1

    for (tx, ty), candidates in votes.items():
        (rx, ry), _ = min(
            candidates.items(),
            key=lambda item: (-item[1], item[0][1], item[0][0]),
        )
        mapping[ty, tx] = (rx, ry)
    return mapping, len(votes)


def build_prediction_mappings(
    points_xyz: np.ndarray,
    *,
    target_pose: np.ndarray,
    reference_pose: np.ndarray,
    target_intrinsics: Sequence[float],
    reference_intrinsics: Sequence[float],
    image_width: int,
    image_height: int,
    target_components: Sequence[CoefficientComponent],
    reference_components: Sequence[CoefficientComponent],
) -> tuple[list[np.ndarray], int, int, int]:
    if image_width <= 0 or image_height <= 0:
        raise ValueError("image dimensions must be positive")
    if len(target_components) != len(reference_components):
        raise ValueError("component count differs between prediction frames")
    target_xy, target_valid = project_points(
        target_pose,
        target_intrinsics,
        points_xyz,
        image_width,
        image_height,
    )
    reference_xy, reference_valid = project_points(
        reference_pose,
        reference_intrinsics,
        points_xyz,
        image_width,
        image_height,
    )
    shared_valid = target_valid & reference_valid
    valid_projection_count = int(np.count_nonzero(shared_valid))
    if valid_projection_count == 0:
        raise ValueError("no shared sparse projections for prediction pair")
    target_xy = target_xy[shared_valid]
    reference_xy = reference_xy[shared_valid]
    mappings: list[np.ndarray] = []
    covered_blocks = 0
    total_blocks = 0
    for target, reference in zip(
        target_components,
        reference_components,
        strict=True,
    ):
        target_blocks = np.floor(
            target_xy
            * np.array(
                (
                    target.width_blocks / image_width,
                    target.height_blocks / image_height,
                )
            )
        ).astype(np.int32)
        reference_blocks = np.floor(
            reference_xy
            * np.array(
                (
                    reference.width_blocks / image_width,
                    reference.height_blocks / image_height,
                )
            )
        ).astype(np.int32)
        mapping, component_covered = vote_block_map(
            target_blocks,
            reference_blocks,
            target_width_blocks=target.width_blocks,
            target_height_blocks=target.height_blocks,
            reference_width_blocks=reference.width_blocks,
            reference_height_blocks=reference.height_blocks,
        )
        mappings.append(mapping)
        covered_blocks += component_covered
        total_blocks += target.width_blocks * target.height_blocks
    return mappings, valid_projection_count, covered_blocks, total_blocks


def _write_uvarint(output: bytearray, value: int) -> None:
    if value < 0:
        raise ValueError("unsigned varint cannot encode a negative value")
    while value >= 0x80:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)


def _read_uvarint(data: memoryview, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        if offset >= len(data) or shift > 63:
            raise ValueError("truncated or oversized varint")
        byte = int(data[offset])
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7


def _zigzag_signed(value: int) -> int:
    return (value << 1) ^ (value >> 63)


def _unzigzag_signed(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


def encode_coefficient_tokens(coefficients: np.ndarray) -> bytes:
    blocks = np.asarray(coefficients)
    if blocks.ndim != 2 or blocks.shape[1] != 64:
        raise ValueError("coefficient array must have shape Nx64")
    output = bytearray()
    for block in blocks:
        run = 0
        for coefficient in block[_ZIGZAG]:
            value = int(coefficient)
            if value == 0:
                run += 1
                continue
            _write_uvarint(output, run + 1)
            _write_uvarint(output, _zigzag_signed(value))
            run = 0
        _write_uvarint(output, 0)
    return bytes(output)


def decode_coefficient_tokens(data: bytes, *, block_count: int) -> np.ndarray:
    blocks = np.zeros((block_count, 64), dtype=np.int16)
    view = memoryview(data)
    offset = 0
    for block_index in range(block_count):
        position = 0
        while True:
            encoded_run, offset = _read_uvarint(view, offset)
            if encoded_run == 0:
                break
            position += encoded_run - 1
            if position >= 64:
                raise ValueError("coefficient run exceeds block")
            encoded_value, offset = _read_uvarint(view, offset)
            value = _unzigzag_signed(encoded_value)
            if not -32768 <= value <= 32767:
                raise ValueError("coefficient exceeds int16")
            blocks[block_index, _ZIGZAG[position]] = value
            position += 1
    if offset != len(view):
        raise ValueError("trailing coefficient token bytes")
    return blocks


def _mapping_indices(
    mapping: np.ndarray,
    *,
    target_block_count: int,
    reference_width_blocks: int,
) -> np.ndarray:
    flattened = np.asarray(mapping, dtype=np.int64).reshape(-1, 2)
    if len(flattened) != target_block_count:
        raise ValueError("mapping size does not match target blocks")
    return flattened[:, 1] * reference_width_blocks + flattened[:, 0]


def apply_block_prediction(
    target: np.ndarray,
    reference: np.ndarray,
    mapping: np.ndarray,
    *,
    target_width_blocks: int,
    reference_width_blocks: int,
) -> np.ndarray:
    if len(target) % target_width_blocks != 0:
        raise ValueError("target block width is inconsistent")
    indices = _mapping_indices(
        mapping,
        target_block_count=len(target),
        reference_width_blocks=reference_width_blocks,
    )
    predicted = np.asarray(reference, dtype=np.int32)[indices]
    residual = np.asarray(target, dtype=np.int32) - predicted
    if np.any(residual < -32768) or np.any(residual > 32767):
        raise ValueError("coefficient residual exceeds int16")
    return residual.astype(np.int16)


def invert_block_prediction(
    residual: np.ndarray,
    reference: np.ndarray,
    mapping: np.ndarray,
    *,
    target_width_blocks: int,
    reference_width_blocks: int,
) -> np.ndarray:
    if len(residual) % target_width_blocks != 0:
        raise ValueError("target block width is inconsistent")
    indices = _mapping_indices(
        mapping,
        target_block_count=len(residual),
        reference_width_blocks=reference_width_blocks,
    )
    restored = np.asarray(residual, dtype=np.int32) + np.asarray(
        reference, dtype=np.int32
    )[indices]
    if np.any(restored < -32768) or np.any(restored > 32767):
        raise ValueError("restored coefficient exceeds int16")
    return restored.astype(np.int16)


def encode_group_payload(
    frames: Sequence[ArchiveFrame],
    prediction_mappings: Sequence[Sequence[np.ndarray]],
) -> bytes:
    if not frames:
        raise ValueError("group cannot be empty")
    if len(prediction_mappings) != len(frames) - 1:
        raise ValueError("one prediction mapping is required per non-anchor frame")
    output = bytearray(b"PWCGROUP1")
    _append_u32(output, 1)
    _append_u32(output, len(frames))
    previous_components: tuple[CoefficientComponent, ...] | None = None
    for frame_position, frame in enumerate(frames):
        encoded_name = frame.name.encode("utf-8")
        _append_u32(output, frame.index)
        _append_u32(output, len(encoded_name))
        output.extend(encoded_name)
        _append_u64(output, frame.source_bytes)
        output.extend(bytes.fromhex(frame.source_sha256))
        _append_u32(output, frame.jpeg.restart_interval)
        _append_u64(output, len(frame.jpeg.header))
        output.extend(frame.jpeg.header)
        _append_u32(output, len(frame.jpeg.components))
        mappings = (
            None
            if frame_position == 0
            else prediction_mappings[frame_position - 1]
        )
        if mappings is not None and len(mappings) != len(frame.jpeg.components):
            raise ValueError("prediction mapping component count mismatch")
        if previous_components is not None and len(previous_components) != len(
            frame.jpeg.components
        ):
            raise ValueError("JPEG component count changed within a group")
        for component_index, component in enumerate(frame.jpeg.components):
            coefficients = component.coefficients
            if previous_components is not None and mappings is not None:
                reference = previous_components[component_index]
                coefficients = apply_block_prediction(
                    coefficients,
                    reference.coefficients,
                    mappings[component_index],
                    target_width_blocks=component.width_blocks,
                    reference_width_blocks=reference.width_blocks,
                )
            encoded_coefficients = encode_coefficient_tokens(coefficients)
            _append_u32(output, component.width_blocks)
            _append_u32(output, component.height_blocks)
            _append_u64(output, len(encoded_coefficients))
            output.extend(encoded_coefficients)
        previous_components = frame.jpeg.components
    output.extend(hashlib.sha256(output).digest())
    return bytes(output)


def decode_group_payload(
    payload: bytes,
    prediction_mappings: Sequence[Sequence[np.ndarray]],
) -> list[ArchiveFrame]:
    if len(payload) < 32:
        raise ValueError("group payload is truncated")
    body, stored_digest = payload[:-32], payload[-32:]
    if hashlib.sha256(body).digest() != stored_digest:
        raise ValueError("group payload digest mismatch")
    reader = _BinaryReader(body)
    if reader.bytes(9) != b"PWCGROUP1":
        raise ValueError("group payload magic mismatch")
    if reader.u32() != 1:
        raise ValueError("unsupported group payload version")
    frame_count = reader.u32()
    if frame_count == 0 or frame_count > 64:
        raise ValueError("invalid group frame count")
    if len(prediction_mappings) != frame_count - 1:
        raise ValueError("prediction mapping count mismatch")
    frames: list[ArchiveFrame] = []
    previous_components: tuple[CoefficientComponent, ...] | None = None
    for frame_position in range(frame_count):
        frame_index = reader.u32()
        name = reader.bytes(reader.u32()).decode("utf-8")
        source_bytes = reader.u64()
        source_sha256 = reader.bytes(32).hex()
        restart_interval = reader.u32()
        header = reader.bytes(reader.u64())
        component_count = reader.u32()
        if not 1 <= component_count <= 10:
            raise ValueError("invalid group component count")
        mappings = (
            None
            if frame_position == 0
            else prediction_mappings[frame_position - 1]
        )
        if mappings is not None and len(mappings) != component_count:
            raise ValueError("prediction mapping component count mismatch")
        if previous_components is not None and len(previous_components) != (
            component_count
        ):
            raise ValueError("JPEG component count changed within a group")
        components: list[CoefficientComponent] = []
        for component_index in range(component_count):
            width_blocks = reader.u32()
            height_blocks = reader.u32()
            encoded_coefficients = reader.bytes(reader.u64())
            block_count = width_blocks * height_blocks
            coefficients = decode_coefficient_tokens(
                encoded_coefficients,
                block_count=block_count,
            )
            if previous_components is not None and mappings is not None:
                reference = previous_components[component_index]
                coefficients = invert_block_prediction(
                    coefficients,
                    reference.coefficients,
                    mappings[component_index],
                    target_width_blocks=width_blocks,
                    reference_width_blocks=reference.width_blocks,
                )
            components.append(
                CoefficientComponent(
                    width_blocks=width_blocks,
                    height_blocks=height_blocks,
                    coefficients=coefficients,
                )
            )
        jpeg = JpegCoefficientData(
            restart_interval=restart_interval,
            header=header,
            components=tuple(components),
        )
        frame = ArchiveFrame(
            index=frame_index,
            name=name,
            source_bytes=source_bytes,
            source_sha256=source_sha256,
            jpeg=jpeg,
        )
        frames.append(frame)
        previous_components = jpeg.components
    reader.require_end()
    return frames


def build_result(
    *,
    source_jpeg_bytes: int,
    archive_bytes: int,
    exactness_failures: int,
    input_hash_failures: int,
    valid_sparse_projections: int,
    random_access_group_overflow: int,
    mapped_block_fraction: float,
    encode_elapsed_ms: float,
    decode_elapsed_ms: float,
    peak_rss_bytes: int,
) -> dict[str, int | float]:
    if archive_bytes <= 0:
        raise ValueError("archive_bytes must be positive")
    result: dict[str, int | float] = {
        "photo_ratio": source_jpeg_bytes / archive_bytes,
        "exactness_failures": exactness_failures,
        "input_hash_failures": input_hash_failures,
        "valid_sparse_projections": valid_sparse_projections,
        "random_access_group_overflow": random_access_group_overflow,
        "source_jpeg_bytes": source_jpeg_bytes,
        "archive_bytes": archive_bytes,
        "mapped_block_fraction": mapped_block_fraction,
        "encode_elapsed_ms": encode_elapsed_ms,
        "decode_elapsed_ms": decode_elapsed_ms,
        "peak_rss_bytes": peak_rss_bytes,
    }
    return result
