"""Join frozen CVDF candidates to official Open Images attribution metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

from pw_plr.openimages_corpus import enrich_cvdf_candidates


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--metadata-url", required=True)
    parser.add_argument("--metadata-etag", required=True)
    parser.add_argument("--metadata-content-length", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    candidate_bytes = arguments.candidates.read_bytes()
    candidate_document = json.loads(candidate_bytes)
    enriched = enrich_cvdf_candidates(
        sys.stdin,
        candidate_document["candidates"],
        require_all=False,
    )
    enriched_ids = {str(item["image_id"]) for item in enriched}
    excluded_ids = sorted(
        str(item["image_id"])
        for item in candidate_document["candidates"]
        if str(item["image_id"]) not in enriched_ids
    )
    result = {
        "schema": "pw_plr_openimages_v7_cvdf_attributed_candidates_v1",
        "candidate_manifest_sha256": hashlib.sha256(candidate_bytes).hexdigest(),
        "metadata_source": {
            "url": arguments.metadata_url,
            "etag": arguments.metadata_etag,
            "content_length": arguments.metadata_content_length,
        },
        "license_status": "metadata_asserted_requires_per_image_product_review",
        "license": "https://creativecommons.org/licenses/by/2.0/",
        "candidate_count": len(enriched),
        "excluded_candidate_count": len(excluded_ids),
        "excluded_candidate_ids": excluded_ids,
        "content_identity_sha256": hashlib.sha256(
            json.dumps(enriched, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "candidates": enriched,
    }
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = arguments.output.with_suffix(arguments.output.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, arguments.output)


if __name__ == "__main__":
    main()
