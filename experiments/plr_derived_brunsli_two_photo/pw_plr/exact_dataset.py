"""Streaming exact-JPEG DCT patches for the frozen Phase 2 training run."""

from __future__ import annotations

from pathlib import Path
import subprocess
from typing import Any

from torch.utils.data import Dataset

from .dct_training import (
    deterministic_patch_origin,
    extract_mlcc_patch,
    read_training_coefficients_bytes,
)


class ExactJpegPatchDataset(Dataset[dict[str, Any]]):
    """Extract one deterministic exact coefficient patch per JPEG and epoch."""

    def __init__(
        self,
        images: list[dict[str, object]],
        *,
        extractor: Path,
        seed: int,
        luma_blocks: int = 32,
    ) -> None:
        if not images:
            raise ValueError("exact JPEG dataset must not be empty")
        if not extractor.is_file():
            raise ValueError(f"exact JPEG extractor is missing: {extractor}")
        self._images = [dict(image) for image in images]
        self._extractor = extractor
        self._seed = seed
        self._luma_blocks = luma_blocks
        self._epoch = 0

    def set_epoch(self, epoch: int) -> None:
        if epoch < 0:
            raise ValueError("epoch must be non-negative")
        self._epoch = epoch

    def __len__(self) -> int:
        return len(self._images)

    def __getitem__(self, index: int) -> dict[str, Any]:
        image = self._images[index]
        top, left = deterministic_patch_origin(
            width_in_luma_blocks=int(image["luma_width_in_blocks"]),
            height_in_luma_blocks=int(image["luma_height_in_blocks"]),
            luma_blocks=self._luma_blocks,
            image_sha256=str(image["sha256"]),
            epoch=self._epoch,
            seed=self._seed,
        )
        completed = subprocess.run(
            [
                str(self._extractor),
                "--extract-patch",
                str(image["path"]),
                "-",
                str(top),
                str(left),
                str(self._luma_blocks),
            ],
            check=True,
            capture_output=True,
        )
        coefficients = read_training_coefficients_bytes(completed.stdout)
        if coefficients.source_bytes != int(image["bytes"]):
            raise ValueError(f"source byte-count drift for {image['image_id']}")
        if coefficients.source_sha256 != str(image["sha256"]):
            raise ValueError(f"source SHA-256 drift for {image['image_id']}")
        patch = extract_mlcc_patch(
            coefficients,
            luma_top=0,
            luma_left=0,
            luma_blocks=self._luma_blocks,
        )
        full_photo_tile_count = (
            (
                int(image["luma_width_in_blocks"])
                + self._luma_blocks
                - 1
            )
            // self._luma_blocks
        ) * (
            (
                int(image["luma_height_in_blocks"])
                + self._luma_blocks
                - 1
            )
            // self._luma_blocks
        )
        return {
            **patch,
            "image_id": str(image["image_id"]),
            "source_sha256": coefficients.source_sha256,
            "luma_top": top,
            "luma_left": left,
            "full_photo_tile_count": full_photo_tile_count,
            "epoch": self._epoch,
        }
