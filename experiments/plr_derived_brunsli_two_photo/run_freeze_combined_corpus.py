"""Probe first-party JPEGs and freeze the complete exact Phase 2 corpus."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path

from pw_plr.combined_corpus import combine_verified_corpora
from pw_plr.openimages_corpus import probe_cvdf_jpeg


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--first-party", type=Path, required=True)
    parser.add_argument("--first-party-root", type=Path, required=True)
    parser.add_argument("--public", type=Path, required=True)
    parser.add_argument("--exclusions", type=Path, required=True)
    parser.add_argument("--probe-binary", type=Path, required=True)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    first_party_bytes = arguments.first_party.read_bytes()
    public_bytes = arguments.public.read_bytes()
    exclusion_bytes = arguments.exclusions.read_bytes()
    first_party = json.loads(first_party_bytes)
    public = json.loads(public_bytes)
    exclusions = json.loads(exclusion_bytes)
    source_root = arguments.first_party_root

    local_inputs: list[dict[str, object]] = []
    for split in ("train", "validation", "diagnostic"):
        for sample in first_party["splits"][split]["samples"]:
            local_inputs.append(
                {
                    **sample,
                    "image_id": sample["source_id"],
                    "path": str(source_root / sample["filename"]),
                    "split": split,
                    "source_kind": "first_party",
                }
            )
    with ThreadPoolExecutor(max_workers=arguments.workers) as executor:
        first_party_images = list(
            executor.map(
                lambda item: probe_cvdf_jpeg(
                    item,
                    arguments.probe_binary,
                ),
                local_inputs,
            )
        )

    public_images = [
        {**image, "source_kind": "openimages_v7_cvdf"}
        for image in public["images"]
    ]
    combined = combine_verified_corpora(
        first_party_images,
        public_images,
        excluded_sha256={
            str(photo["sha256"]) for photo in exclusions["canonical_photos"]
        },
    )
    result = {
        **combined,
        "source_manifests": {
            "first_party_sha256": hashlib.sha256(first_party_bytes).hexdigest(),
            "public_sha256": hashlib.sha256(public_bytes).hexdigest(),
            "exclusions_sha256": hashlib.sha256(exclusion_bytes).hexdigest(),
        },
        "probe_binary_sha256": hashlib.sha256(
            arguments.probe_binary.read_bytes()
        ).hexdigest(),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
