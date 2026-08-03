"""One-shot diagnostic for exact JPEG patch extraction throughput."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

import torch
from torch.utils.data import DataLoader

from pw_plr.exact_dataset import ExactJpegPatchDataset
from pw_plr.trainer import build_optimizers, train_batch


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--image-root", type=Path, required=True)
    parser.add_argument("--extractor", type=Path, required=True)
    parser.add_argument("--sample-count", type=int, default=128)
    parser.add_argument("--workers", type=int, default=16)
    parser.add_argument("--upstream", type=Path)
    parser.add_argument("--model-n", type=int)
    parser.add_argument("--model-m", type=int)
    arguments = parser.parse_args()

    manifest = json.loads(arguments.manifest.read_bytes())
    samples = manifest["splits"]["train"]["samples"][: arguments.sample_count]
    images: list[dict[str, object]] = []
    probe_started = time.monotonic()
    for sample in samples:
        path = arguments.image_root / sample["filename"]
        probe = json.loads(
            subprocess.run(
                [str(arguments.extractor), "--probe", str(path)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout
        )
        images.append(
            {
                **sample,
                "image_id": sample["source_id"],
                "path": str(path),
                "luma_width_in_blocks": probe["luma_width_in_blocks"],
                "luma_height_in_blocks": probe["luma_height_in_blocks"],
            }
        )
    probe_seconds = time.monotonic() - probe_started

    dataset = ExactJpegPatchDataset(
        images,
        extractor=arguments.extractor,
        seed=20260803,
    )
    dataset.set_epoch(0)
    extract_started = time.monotonic()
    extracted = 0
    first_batch = None
    for batch in DataLoader(
        dataset,
        batch_size=64,
        num_workers=arguments.workers,
        prefetch_factor=2,
    ):
        extracted += int(batch["Y"].shape[0])
        if first_batch is None:
            first_batch = batch
    extract_seconds = time.monotonic() - extract_started
    result = {
        "schema": "pw_plr_dataset_throughput_diagnostic_v1",
        "diagnostic_only": True,
        "images": extracted,
        "workers": arguments.workers,
        "probe_seconds": probe_seconds,
        "extract_seconds": extract_seconds,
        "extract_images_per_second": extracted / extract_seconds,
    }
    model_arguments = (arguments.upstream, arguments.model_n, arguments.model_m)
    if any(value is not None for value in model_arguments):
        if not all(value is not None for value in model_arguments):
            raise ValueError("upstream, model-n, and model-m must be supplied together")
        if not torch.backends.mps.is_available():
            raise RuntimeError("MPS is unavailable")
        sys.path.insert(0, str(arguments.upstream))
        from compressai.models.base_eff import EfficientJPEGRecompression

        model = EfficientJPEGRecompression(
            N=arguments.model_n,
            M=arguments.model_m,
            chunk=("scales", "means"),
        ).to("mps")
        main_optimizer, auxiliary_optimizer = build_optimizers(
            model,
            main_learning_rate=0.0001,
            auxiliary_learning_rate=0.001,
        )
        train_started = time.monotonic()
        metrics = train_batch(
            model,
            first_batch,
            main_optimizer,
            auxiliary_optimizer,
            gradient_clip_max_norm=1.0,
        )
        torch.mps.synchronize()
        result.update(
            {
                "model_n": arguments.model_n,
                "model_m": arguments.model_m,
                "train_batch_size": int(first_batch["Y"].shape[0]),
                "train_batch_seconds": time.monotonic() - train_started,
                "train_loss_bits_per_pixel": metrics.loss_bits_per_pixel,
            }
        )
    print(
        json.dumps(
            result,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
