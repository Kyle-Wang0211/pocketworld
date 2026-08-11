"""Measure the registered per-frequency scale prior from the training split.

The prior becomes part of the decoder model artifact, so it may only ever see
``split == "train"`` images. The frozen pair and its whole capture are already
absent from the combined corpus; this script additionally refuses to run if any
sampled image carries an excluded capture id, so a corpus regression cannot
silently leak the test scene into the model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

import torch

from pw_plr.dct_training import extract_mlcc_patch, read_training_coefficients_bytes
from pw_plr.frequency_prior import measure_frequency_prior


def _excluded_capture_ids(manifest: Path) -> set[str]:
    if not manifest.is_file():
        raise SystemExit(f"training exclusion manifest is missing: {manifest}")
    payload = json.loads(manifest.read_text())
    ids: set[str] = set()
    for key in ("excluded_capture_ids", "capture_ids"):
        for value in payload.get(key, []) or []:
            ids.add(str(value))
    for entry in payload.get("captures", []) or []:
        if isinstance(entry, dict) and "capture_id" in entry:
            ids.add(str(entry["capture_id"]))
    return ids


def _deterministic_sample(images: list[dict], count: int, seed: int) -> list[dict]:
    """Rank by a seeded hash of the immutable image identity, then take the top."""

    def rank(image: dict) -> str:
        material = f"{seed}:{image['image_id']}:{image['sha256']}".encode()
        return hashlib.sha256(material).hexdigest()

    return sorted(images, key=rank)[:count]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=Path("phase2-combined-corpus.json"))
    parser.add_argument("--extractor", type=Path, default=Path("build/v0.1/pw_brunsli_training_extract"))
    parser.add_argument(
        "--exclusion-manifest", type=Path, default=Path("training-exclusion-manifest.json")
    )
    parser.add_argument("--output", type=Path, default=Path("frequency-prior.json"))
    parser.add_argument("--sample-count", type=int, default=64)
    parser.add_argument("--luma-blocks", type=int, default=32)
    parser.add_argument("--seed", type=int, default=20260803)
    arguments = parser.parse_args()

    corpus = json.loads(arguments.corpus.read_text())
    excluded = _excluded_capture_ids(arguments.exclusion_manifest)
    train = [image for image in corpus["images"] if image.get("split") == "train"]
    if not train:
        raise SystemExit("combined corpus exposes no training split")

    sample = _deterministic_sample(train, arguments.sample_count, arguments.seed)
    leaked = sorted({str(image.get("capture_id")) for image in sample} & excluded)
    if leaked:
        raise SystemExit(f"refusing to measure a prior over excluded captures: {leaked}")

    luma_patches: list[torch.Tensor] = []
    chroma_patches: list[torch.Tensor] = []
    for index, image in enumerate(sample, start=1):
        completed = subprocess.run(
            [
                str(arguments.extractor),
                "--extract-patch",
                str(image["path"]),
                "-",
                "0",
                "0",
                str(arguments.luma_blocks),
            ],
            check=True,
            capture_output=True,
        )
        coefficients = read_training_coefficients_bytes(completed.stdout)
        if coefficients.source_sha256 != str(image["sha256"]):
            raise SystemExit(f"source SHA-256 drift for {image['image_id']}")
        patch = extract_mlcc_patch(
            coefficients, luma_top=0, luma_left=0, luma_blocks=arguments.luma_blocks
        )
        luma_patches.append(patch["Y"])
        chroma_patches.append(patch["Cb"])
        chroma_patches.append(patch["Cr"])
        print(f"  [{index}/{len(sample)}] {image['image_id']}", file=sys.stderr)

    prior = measure_frequency_prior(
        luma_patches,
        chroma_patches,
        corpus_content_identity_sha256=str(corpus["content_identity_sha256"]),
    )
    prior.write(arguments.output)
    print(json.dumps({
        "output": str(arguments.output),
        "sample_count": prior.sample_count,
        "luma_dc_sigma": prior.luma[-1],
        "luma_highest_frequency_sigma": prior.luma[0],
        "chroma_sigma": prior.chroma,
        "excluded_capture_ids": sorted(excluded),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
