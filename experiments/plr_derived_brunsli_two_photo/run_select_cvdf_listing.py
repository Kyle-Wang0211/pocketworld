"""Enumerate the official Open Images CVDF mirror and freeze candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import time
from typing import Iterator
import urllib.parse
import urllib.request

from pw_plr.openimages_corpus import parse_cvdf_listing, select_cvdf_candidates


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate-count", type=int, required=True)
    parser.add_argument("--selection-seed", required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    endpoint = "https://open-images-dataset.s3.amazonaws.com/"
    stats = {"page_count": 0, "listed_image_count": 0, "listed_bytes": 0}

    def listing_items() -> Iterator[dict[str, object]]:
        continuation_token: str | None = None
        while True:
            parameters = {"list-type": "2", "prefix": "train/", "max-keys": "1000"}
            if continuation_token is not None:
                parameters["continuation-token"] = continuation_token
            url = endpoint + "?" + urllib.parse.urlencode(parameters)
            last_error: Exception | None = None
            for attempt in range(5):
                try:
                    request = urllib.request.Request(
                        url,
                        headers={"User-Agent": "PocketWorld-PLR-Research/1.0"},
                    )
                    with urllib.request.urlopen(request, timeout=30) as response:
                        payload = response.read()
                    break
                except Exception as error:
                    last_error = error
                    if attempt == 4:
                        raise
                    time.sleep(2**attempt)
            else:
                raise RuntimeError("unreachable listing retry state") from last_error
            page, continuation_token = parse_cvdf_listing(payload)
            stats["page_count"] += 1
            stats["listed_image_count"] += len(page)
            stats["listed_bytes"] += sum(int(item["cvdf_bytes"]) for item in page)
            yield from page
            if continuation_token is None:
                break

    candidates = select_cvdf_candidates(
        listing_items(),
        candidate_count=arguments.candidate_count,
        selection_seed=arguments.selection_seed,
    )
    selection_identity = hashlib.sha256(
        json.dumps(candidates, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    result = {
        "schema": "pw_plr_openimages_v7_cvdf_candidates_v1",
        "official_download_page": (
            "https://storage.googleapis.com/openimages/web/download_v7.html"
        ),
        "cvdf_bucket_endpoint": endpoint,
        "listing": stats,
        "selection": {
            "candidate_count": arguments.candidate_count,
            "seed": arguments.selection_seed,
            "policy": "lowest_sha256_seed_colon_image_id_over_complete_train_listing",
        },
        "selection_identity_sha256": selection_identity,
        "candidates": candidates,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
