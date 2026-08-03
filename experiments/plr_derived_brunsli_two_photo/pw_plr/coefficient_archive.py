"""Exact 32-block tiling and PWCF reconstruction for full JPEG coefficients."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import struct

import numpy as np
import torch

from .dct_training import PLR_HIGH_TO_LOW_INDICES, DctComponent, TrainingCoefficients


PWCF_MAGIC = b"PWCF1\0\0\0"


@dataclass(frozen=True)
class MlccTile:
    luma_top: int
    luma_left: int
    valid_luma_height: int
    valid_luma_width: int
    Y: torch.Tensor
    Cb: torch.Tensor
    Cr: torch.Tensor


def _components_420(
    coefficients: TrainingCoefficients,
) -> tuple[DctComponent, DctComponent, DctComponent]:
    components = tuple(
        sorted(coefficients.components, key=lambda component: component.component_id)
    )
    if (
        len(components) != 3
        or [component.component_id for component in components] != [1, 2, 3]
        or coefficients.max_h_samp_factor != 2
        or coefficients.max_v_samp_factor != 2
        or (components[0].h_samp_factor, components[0].v_samp_factor) != (2, 2)
        or any(
            (component.h_samp_factor, component.v_samp_factor) != (1, 1)
            for component in components[1:]
        )
        or components[0].width_in_blocks != components[1].width_in_blocks * 2
        or components[0].height_in_blocks != components[1].height_in_blocks * 2
        or components[1].width_in_blocks != components[2].width_in_blocks
        or components[1].height_in_blocks != components[2].height_in_blocks
    ):
        raise ValueError("full coefficient tiling requires exact JPEG 4:2:0")
    return components


def _natural_blocks(component: DctComponent) -> torch.Tensor:
    return torch.frombuffer(component.coefficients, dtype=torch.int16).clone().reshape(
        component.height_in_blocks,
        component.width_in_blocks,
        64,
    )


def _natural_blocks_to_plane(blocks: torch.Tensor) -> torch.Tensor:
    height, width, _ = blocks.shape
    return (
        blocks.reshape(height, width, 8, 8)
        .permute(0, 2, 1, 3)
        .reshape(1, height * 8, width * 8)
    )


def _plane_to_natural_blocks(
    plane: torch.Tensor,
    *,
    block_height: int,
    block_width: int,
) -> torch.Tensor:
    return (
        plane.reshape(block_height, 8, block_width, 8)
        .permute(0, 2, 1, 3)
        .reshape(block_height, block_width, 64)
    )


def extract_all_mlcc_tiles(
    coefficients: TrainingCoefficients,
    *,
    luma_blocks: int = 32,
) -> list[MlccTile]:
    """Tile every coefficient with exact zero padding at right/bottom edges."""
    if luma_blocks <= 0 or luma_blocks % 2:
        raise ValueError("luma_blocks must be a positive even number")
    y_component, cb_component, cr_component = _components_420(coefficients)
    y_natural = _natural_blocks(y_component)
    y_high_to_low = y_natural.index_select(2, PLR_HIGH_TO_LOW_INDICES)
    cb_plane = _natural_blocks_to_plane(_natural_blocks(cb_component))
    cr_plane = _natural_blocks_to_plane(_natural_blocks(cr_component))
    chroma_blocks = luma_blocks // 2
    tiles: list[MlccTile] = []
    for top in range(0, y_component.height_in_blocks, luma_blocks):
        valid_height = min(luma_blocks, y_component.height_in_blocks - top)
        for left in range(0, y_component.width_in_blocks, luma_blocks):
            valid_width = min(luma_blocks, y_component.width_in_blocks - left)
            if valid_height % 2 or valid_width % 2:
                raise ValueError("4:2:0 edge tile has an odd luma block extent")
            y_tile = torch.zeros(luma_blocks, luma_blocks, 64, dtype=torch.float32)
            y_tile[:valid_height, :valid_width] = y_high_to_low[
                top : top + valid_height,
                left : left + valid_width,
            ]
            cb_tile = torch.zeros(
                1,
                chroma_blocks * 8,
                chroma_blocks * 8,
                dtype=torch.float32,
            )
            cr_tile = torch.zeros_like(cb_tile)
            chroma_top = top // 2 * 8
            chroma_left = left // 2 * 8
            chroma_height = valid_height // 2 * 8
            chroma_width = valid_width // 2 * 8
            cb_tile[:, :chroma_height, :chroma_width] = cb_plane[
                :,
                chroma_top : chroma_top + chroma_height,
                chroma_left : chroma_left + chroma_width,
            ]
            cr_tile[:, :chroma_height, :chroma_width] = cr_plane[
                :,
                chroma_top : chroma_top + chroma_height,
                chroma_left : chroma_left + chroma_width,
            ]
            tiles.append(
                MlccTile(
                    luma_top=top,
                    luma_left=left,
                    valid_luma_height=valid_height,
                    valid_luma_width=valid_width,
                    Y=y_tile,
                    Cb=cb_tile,
                    Cr=cr_tile,
                )
            )
    return tiles


def build_pwcf_from_mlcc_tiles(
    coefficients: TrainingCoefficients,
    tiles: list[MlccTile],
) -> bytes:
    """Reassemble decoded MLCC tiles into the Phase 1 exact PWCF envelope."""
    y_component, cb_component, cr_component = _components_420(coefficients)
    y_natural = torch.zeros(
        y_component.height_in_blocks,
        y_component.width_in_blocks,
        64,
        dtype=torch.int16,
    )
    cb_natural = torch.zeros(
        cb_component.height_in_blocks,
        cb_component.width_in_blocks,
        64,
        dtype=torch.int16,
    )
    cr_natural = torch.zeros_like(cb_natural)
    coverage = torch.zeros(
        y_component.height_in_blocks,
        y_component.width_in_blocks,
        dtype=torch.bool,
    )
    for tile in tiles:
        top = tile.luma_top
        left = tile.luma_left
        height = tile.valid_luma_height
        width = tile.valid_luma_width
        if (
            top < 0
            or left < 0
            or height <= 0
            or width <= 0
            or top + height > y_component.height_in_blocks
            or left + width > y_component.width_in_blocks
            or coverage[top : top + height, left : left + width].any()
        ):
            raise ValueError("invalid or overlapping decoded coefficient tile")
        y_high_to_low = tile.Y[:height, :width].to(torch.int16)
        y_tile_natural = torch.empty_like(y_high_to_low)
        y_tile_natural[..., PLR_HIGH_TO_LOW_INDICES] = y_high_to_low
        y_natural[top : top + height, left : left + width] = y_tile_natural
        coverage[top : top + height, left : left + width] = True

        chroma_height = height // 2
        chroma_width = width // 2
        chroma_top = top // 2
        chroma_left = left // 2
        cb_natural[
            chroma_top : chroma_top + chroma_height,
            chroma_left : chroma_left + chroma_width,
        ] = _plane_to_natural_blocks(
            tile.Cb[:, : chroma_height * 8, : chroma_width * 8].to(torch.int16),
            block_height=chroma_height,
            block_width=chroma_width,
        )
        cr_natural[
            chroma_top : chroma_top + chroma_height,
            chroma_left : chroma_left + chroma_width,
        ] = _plane_to_natural_blocks(
            tile.Cr[:, : chroma_height * 8, : chroma_width * 8].to(torch.int16),
            block_height=chroma_height,
            block_width=chroma_width,
        )
    if not coverage.all():
        raise ValueError("decoded coefficient tiles do not cover the full image")

    payload = bytearray(struct.pack("<I", 3))
    for blocks in (y_natural, cb_natural, cr_natural):
        values = blocks.contiguous().numpy().astype(np.dtype("<i2"), copy=False)
        payload.extend(struct.pack("<Q", values.size))
        payload.extend(values.tobytes(order="C"))
    payload_bytes = bytes(payload)
    return (
        PWCF_MAGIC
        + struct.pack("<QQ", len(payload_bytes), coefficients.source_bytes)
        + hashlib.sha256(payload_bytes).digest()
        + bytes.fromhex(coefficients.source_sha256)
        + payload_bytes
    )
