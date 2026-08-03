"""Download and verify the frozen Open Images CVDF corpus."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path

from pw_plr.openimages_corpus import (
    assign_final_splits,
    download_and_probe_cvdf_candidate,
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--probe-binary", type=Path, required=True)
    parser.add_argument("--target-count", type=int, required=True)
    parser.add_argument("--workers", type=int, default=32)
    parser.add_argument("--split-seed", required=True)
    parser.add_argument("--train-count", type=int, required=True)
    parser.add_argument("--validation-count", type=int, required=True)
    parser.add_argument("--diagnostic-count", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    candidate_bytes = arguments.candidates.read_bytes()
    candidates = json.loads(candidate_bytes)["candidates"]
    successes: list[dict[str, object]] = []
    ineligible: list[dict[str, object]] = []
    failures: list[dict[str, object]] = []

    batch_size = max(arguments.workers * 4, 128)
    for start in range(0, len(candidates), batch_size):
        batch = candidates[start : start + batch_size]
        with ThreadPoolExecutor(max_workers=arguments.workers) as executor:
            futures = {
                executor.submit(
                    download_and_probe_cvdf_candidate,
                    candidate,
                    arguments.output_directory,
                    arguments.probe_binary,
                ): candidate
                for candidate in batch
            }
            for future in as_completed(futures):
                candidate = futures[future]
                try:
                    probed = future.result()
                    if bool(probed["eligible_plr_420"]):
                        successes.append(probed)
                    else:
                        ineligible.append(probed)
                        Path(str(probed["path"])).unlink(missing_ok=True)
                except Exception as error:
                    failures.append(
                        {
                            "image_id": candidate["image_id"],
                            "selection_rank": candidate["selection_rank"],
                            "error_type": type(error).__name__,
                            "error": str(error),
                        }
                    )
        successes.sort(key=lambda item: int(item["selection_rank"]))
        if len(successes) >= arguments.target_count:
            break

    if len(successes) < arguments.target_count:
        raise RuntimeError(
            f"only {len(successes)} verified CVDF images; "
            f"target is {arguments.target_count}"
        )
    selected = assign_final_splits(
        successes[: arguments.target_count],
        split_seed=arguments.split_seed,
        split_counts={
            "train": arguments.train_count,
            "validation": arguments.validation_count,
            "diagnostic": arguments.diagnostic_count,
        },
    )
    for extra in successes[arguments.target_count :]:
        Path(str(extra["path"])).unlink(missing_ok=True)
    result = {
        "schema": "pw_plr_openimages_v7_cvdf_jpegs_v1",
        "candidate_manifest_sha256": hashlib.sha256(candidate_bytes).hexdigest(),
        "target_count": arguments.target_count,
        "verified_count": len(selected),
        "eligible_plr_420_count": len(successes),
        "ineligible_jpeg_count": len(ineligible),
        "download_policy": {
            "attempts_per_candidate": 5,
            "timeout_seconds_per_attempt": 12,
            "backoff_seconds": [0.25, 0.5, 1.0, 2.0],
        },
        "total_bytes": sum(int(item["bytes"]) for item in selected),
        "split_seed": arguments.split_seed,
        "split_counts": {
            "train": arguments.train_count,
            "validation": arguments.validation_count,
            "diagnostic": arguments.diagnostic_count,
        },
        "content_identity_sha256": hashlib.sha256(
            json.dumps(selected, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "images": selected,
        "failures_before_target": sorted(
            failures,
            key=lambda item: int(item["selection_rank"]),
        ),
        "ineligible_jpegs_removed": sorted(
            (
                {
                    key: item[key]
                    for key in (
                        "image_id",
                        "selection_rank",
                        "bytes",
                        "sha256",
                        "jpeg_width",
                        "jpeg_height",
                        "luma_width_in_blocks",
                        "luma_height_in_blocks",
                        "jpeg_component_count",
                        "jpeg_subsampling",
                    )
                }
                for item in ineligible
            ),
            key=lambda item: int(item["selection_rank"]),
        ),
        "unused_downloads_removed": sorted(
            str(item["image_id"]) for item in successes[arguments.target_count :]
        ),
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
