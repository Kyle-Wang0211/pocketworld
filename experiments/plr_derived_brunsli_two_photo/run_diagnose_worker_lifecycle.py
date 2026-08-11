"""Bounded diagnostic for exact-JPEG DataLoader completion and worker teardown."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

import torch
from torch.utils.data import DataLoader

from pw_plr.exact_dataset import ExactJpegPatchDataset


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--extractor", type=Path, required=True)
    parser.add_argument("--sample-count", type=int, default=512)
    parser.add_argument("--workers", type=int, required=True)
    arguments = parser.parse_args()
    if arguments.sample_count <= 0 or arguments.workers <= 0:
        raise ValueError("sample count and worker count must be positive")

    corpus = json.loads(arguments.corpus.read_bytes())
    images = [
        image for image in corpus["images"] if image["split"] == "train"
    ][: arguments.sample_count]
    if len(images) != arguments.sample_count:
        raise ValueError("combined corpus has fewer train images than requested")
    dataset = ExactJpegPatchDataset(
        images,
        extractor=arguments.extractor,
        seed=20260803,
    )
    dataset.set_epoch(0)
    generator = torch.Generator().manual_seed(20260803)
    digest = hashlib.sha256()
    completed = 0
    started = time.monotonic()
    for batch in DataLoader(
        dataset,
        batch_size=64,
        shuffle=True,
        generator=generator,
        num_workers=arguments.workers,
        prefetch_factor=2,
    ):
        for image_id, source_sha256 in zip(
            batch["image_id"], batch["source_sha256"], strict=True
        ):
            digest.update(str(image_id).encode("utf-8") + b"\0")
            digest.update(bytes.fromhex(str(source_sha256)))
        completed += int(batch["Y"].shape[0])
    elapsed = time.monotonic() - started
    print(
        json.dumps(
            {
                "schema": "pw_plr_worker_lifecycle_diagnostic_v1",
                "diagnostic_only": True,
                "workers": arguments.workers,
                "sample_count": arguments.sample_count,
                "completed_samples": completed,
                "ordered_sample_identity_sha256": digest.hexdigest(),
                "elapsed_seconds": elapsed,
                "images_per_second": completed / elapsed,
                "iterator_completed": True,
                "process_exit_proves_workers_reaped": True,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
