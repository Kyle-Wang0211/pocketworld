"""Read exact Brunsli coefficient tensors for Phase 2 training."""

from __future__ import annotations

from dataclasses import dataclass
from array import array
import hashlib
from pathlib import Path
import struct
import sys

import torch


MAGIC = b"PWTJ1\0\0\0"
HEADER_BYTES = 8 + 8 + 32 + 8 + 32


@dataclass(frozen=True)
class DctComponent:
    component_id: int
    h_samp_factor: int
    v_samp_factor: int
    quant_idx: int
    width_in_blocks: int
    height_in_blocks: int
    coefficients: array


@dataclass(frozen=True)
class TrainingCoefficients:
    width: int
    height: int
    max_h_samp_factor: int
    max_v_samp_factor: int
    source_bytes: int
    source_sha256: str
    components: tuple[DctComponent, ...]


def _unpack_from(format_string: str, payload: bytes, position: int) -> tuple:
    size = struct.calcsize(format_string)
    if position > len(payload) or len(payload) - position < size:
        raise ValueError("truncated training coefficient payload")
    return struct.unpack_from(format_string, payload, position)


def read_training_coefficients(path: Path) -> TrainingCoefficients:
    return read_training_coefficients_bytes(path.read_bytes())


def read_training_coefficients_bytes(document: bytes) -> TrainingCoefficients:
    """Parse one checksummed coefficient envelope already held in memory."""
    if len(document) < HEADER_BYTES or document[:8] != MAGIC:
        raise ValueError("invalid training coefficient envelope")
    payload_bytes = struct.unpack_from("<Q", document, 8)[0]
    expected_payload_sha = document[16:48]
    source_bytes = struct.unpack_from("<Q", document, 48)[0]
    source_sha = document[56:88]
    payload = document[HEADER_BYTES:]
    if payload_bytes != len(payload):
        raise ValueError("training coefficient payload length mismatch")
    if hashlib.sha256(payload).digest() != expected_payload_sha:
        raise ValueError("training coefficient payload SHA-256 mismatch")

    width, height, max_h, max_v, component_count = _unpack_from(
        "<5I", payload, 0
    )
    position = struct.calcsize("<5I")
    components: list[DctComponent] = []
    for _ in range(component_count):
        (
            component_id,
            h_samp,
            v_samp,
            quant_idx,
            width_blocks,
            height_blocks,
            coefficient_count,
        ) = _unpack_from("<6IQ", payload, position)
        position += struct.calcsize("<6IQ")
        expected_count = width_blocks * height_blocks * 64
        if coefficient_count != expected_count:
            raise ValueError("component coefficient count does not match block shape")
        coefficient_bytes = coefficient_count * 2
        if position > len(payload) or len(payload) - position < coefficient_bytes:
            raise ValueError("truncated component coefficient values")
        coefficients = array("h")
        coefficients.frombytes(payload[position : position + coefficient_bytes])
        if sys.byteorder != "little":
            coefficients.byteswap()
        position += coefficient_bytes
        components.append(
            DctComponent(
                component_id=component_id,
                h_samp_factor=h_samp,
                v_samp_factor=v_samp,
                quant_idx=quant_idx,
                width_in_blocks=width_blocks,
                height_in_blocks=height_blocks,
                coefficients=coefficients,
            )
        )
    if position != len(payload):
        raise ValueError("unexpected trailing training coefficient bytes")
    return TrainingCoefficients(
        width=width,
        height=height,
        max_h_samp_factor=max_h,
        max_v_samp_factor=max_v,
        source_bytes=source_bytes,
        source_sha256=source_sha.hex(),
        components=tuple(components),
    )


def _plr_zigzag_indices() -> torch.Tensor:
    indices: list[tuple[int, int]] = []
    size = 8
    for diagonal in range(2 * size - 1):
        if diagonal % 2 == 0:
            row = min(diagonal, size - 1)
            column = max(0, diagonal - size + 1)
            while row >= 0 and column < size:
                indices.append(
                    (row, column) if diagonal < size else (column, row)
                )
                row -= 1
                column += 1
        else:
            row = max(0, diagonal - size + 1)
            column = min(diagonal, size - 1)
            while row < size and column >= 0:
                indices.append(
                    (row, column) if diagonal < size else (column, row)
                )
                row += 1
                column -= 1
    return torch.tensor([row * size + column for row, column in indices])


PLR_HIGH_TO_LOW_INDICES = _plr_zigzag_indices().flip(0)


def deterministic_patch_origin(
    *,
    width_in_luma_blocks: int,
    height_in_luma_blocks: int,
    luma_blocks: int,
    image_sha256: str,
    epoch: int,
    seed: int,
) -> tuple[int, int]:
    """Select an even 4:2:0 crop origin from immutable sample identity."""
    if luma_blocks <= 0 or luma_blocks % 2:
        raise ValueError("luma_blocks must be a positive even number")
    if width_in_luma_blocks < luma_blocks or height_in_luma_blocks < luma_blocks:
        raise ValueError("JPEG block grid is smaller than the requested patch")
    if epoch < 0:
        raise ValueError("epoch must be non-negative")
    try:
        source_identity = bytes.fromhex(image_sha256)
    except ValueError as error:
        raise ValueError("image_sha256 must be hexadecimal") from error
    if len(source_identity) != 32:
        raise ValueError("image_sha256 must contain exactly 32 bytes")
    digest = hashlib.sha256(
        struct.pack("<qQ", seed, epoch) + source_identity
    ).digest()
    top_positions = (height_in_luma_blocks - luma_blocks) // 2 + 1
    left_positions = (width_in_luma_blocks - luma_blocks) // 2 + 1
    top = int.from_bytes(digest[:8], "little") % top_positions * 2
    left = int.from_bytes(digest[8:16], "little") % left_positions * 2
    return top, left


def _component_tensor(component: DctComponent) -> torch.Tensor:
    values = torch.frombuffer(component.coefficients, dtype=torch.int16)
    blocks = values.reshape(
        component.height_in_blocks,
        component.width_in_blocks,
        64,
    )
    return blocks.index_select(2, PLR_HIGH_TO_LOW_INDICES).to(torch.float32)


def extract_plr_patch(
    coefficients: TrainingCoefficients,
    *,
    luma_top: int,
    luma_left: int,
    luma_blocks: int = 32,
) -> dict[str, torch.Tensor]:
    """Return an exact-valued PLR-order patch from a 4:2:0 JPEG tensor."""
    components = sorted(coefficients.components, key=lambda item: item.component_id)
    if (
        coefficients.max_h_samp_factor != 2
        or coefficients.max_v_samp_factor != 2
        or [item.component_id for item in components] != [1, 2, 3]
        or (components[0].h_samp_factor, components[0].v_samp_factor) != (2, 2)
        or any(
            (item.h_samp_factor, item.v_samp_factor) != (1, 1)
            for item in components[1:]
        )
    ):
        raise ValueError("PLR training patch requires three-component JPEG 4:2:0")
    if luma_top % 2 or luma_left % 2:
        raise ValueError("PLR 4:2:0 patch requires an even luma block origin")
    if luma_blocks <= 0 or luma_blocks % 2:
        raise ValueError("luma_blocks must be a positive even number")
    y_component, cb_component, cr_component = components
    if (
        y_component.width_in_blocks != cb_component.width_in_blocks * 2
        or y_component.height_in_blocks != cb_component.height_in_blocks * 2
        or cb_component.width_in_blocks != cr_component.width_in_blocks
        or cb_component.height_in_blocks != cr_component.height_in_blocks
    ):
        raise ValueError("JPEG component block geometry is not exact 4:2:0")
    luma_bottom = luma_top + luma_blocks
    luma_right = luma_left + luma_blocks
    if (
        luma_top < 0
        or luma_left < 0
        or luma_bottom > y_component.height_in_blocks
        or luma_right > y_component.width_in_blocks
    ):
        raise ValueError("PLR patch lies outside the luma block grid")
    chroma_top = luma_top // 2
    chroma_left = luma_left // 2
    chroma_blocks = luma_blocks // 2
    return {
        "Y": _component_tensor(y_component)[
            luma_top:luma_bottom,
            luma_left:luma_right,
        ],
        "Cb": _component_tensor(cb_component)[
            chroma_top : chroma_top + chroma_blocks,
            chroma_left : chroma_left + chroma_blocks,
        ],
        "Cr": _component_tensor(cr_component)[
            chroma_top : chroma_top + chroma_blocks,
            chroma_left : chroma_left + chroma_blocks,
        ],
    }


def _blocks_to_coefficient_plane(blocks: torch.Tensor) -> torch.Tensor:
    natural = torch.empty_like(blocks)
    natural[..., PLR_HIGH_TO_LOW_INDICES] = blocks
    height, width, _ = natural.shape
    return (
        natural.reshape(height, width, 8, 8)
        .permute(0, 2, 1, 3)
        .reshape(1, height * 8, width * 8)
    )


def extract_mlcc_patch(
    coefficients: TrainingCoefficients,
    *,
    luma_top: int,
    luma_left: int,
    luma_blocks: int = 32,
) -> dict[str, torch.Tensor]:
    """Return the exact tensor layout used by the official 22-stage sibling."""
    patch = extract_plr_patch(
        coefficients,
        luma_top=luma_top,
        luma_left=luma_left,
        luma_blocks=luma_blocks,
    )
    return {
        "Y": patch["Y"],
        "Cb": _blocks_to_coefficient_plane(patch["Cb"]),
        "Cr": _blocks_to_coefficient_plane(patch["Cr"]),
    }
