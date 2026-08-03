from pathlib import Path

import torch

from pw_plr.exact_dataset import ExactJpegPatchDataset


def test_exact_dataset_streams_a_deterministic_verified_dct_patch() -> None:
    experiment = Path(__file__).resolve().parent.parent
    source = experiment / "data/frozen_pair/cell_85_slot_4.jpg"
    entry = {
        "image_id": "frozen-A",
        "path": str(source),
        "bytes": 2_995_750,
        "sha256": (
            "ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6"
        ),
        "jpeg_width": 4224,
        "jpeg_height": 2376,
        "luma_width_in_blocks": 528,
        "luma_height_in_blocks": 298,
    }
    dataset = ExactJpegPatchDataset(
        [entry],
        extractor=experiment / "build/v0.1/pw_brunsli_training_extract",
        seed=20260803,
    )

    first = dataset[0]
    repeated = dataset[0]
    dataset.set_epoch(1)
    later = dataset[0]

    assert first["image_id"] == "frozen-A"
    assert first["source_sha256"] == entry["sha256"]
    assert first["luma_top"] % 2 == 0
    assert first["luma_left"] % 2 == 0
    assert first["full_photo_tile_count"] == 170
    assert (first["luma_top"], first["luma_left"]) == (
        repeated["luma_top"],
        repeated["luma_left"],
    )
    assert (first["luma_top"], first["luma_left"]) != (
        later["luma_top"],
        later["luma_left"],
    )
    assert torch.equal(first["Y"], repeated["Y"])
    assert tuple(first["Y"].shape) == (32, 32, 64)
    assert tuple(first["Cb"].shape) == (1, 128, 128)
    assert tuple(first["Cr"].shape) == (1, 128, 128)
    assert first["Y"].dtype == torch.float32
