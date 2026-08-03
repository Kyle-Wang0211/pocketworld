"""Freeze the verified first-party and public exact-JPEG training corpus."""

from __future__ import annotations

from collections import Counter
import hashlib
import json


SPLITS = ("train", "validation", "diagnostic")


def combine_verified_corpora(
    first_party_images: list[dict[str, object]],
    public_images: list[dict[str, object]],
    *,
    excluded_sha256: set[str],
) -> dict[str, object]:
    """Combine only structurally verified, unique, non-excluded JPEGs."""
    images = [dict(item) for item in first_party_images + public_images]
    if not images:
        raise ValueError("combined corpus must not be empty")
    seen_sha256: set[str] = set()
    for image in images:
        image_id = str(image["image_id"])
        sha256 = str(image["sha256"])
        if sha256 in seen_sha256:
            raise ValueError(f"duplicate JPEG SHA-256 in corpus: {image_id}")
        seen_sha256.add(sha256)
        if sha256 in excluded_sha256:
            raise ValueError(f"JPEG overlaps frozen exclusion: {image_id}")
        if image.get("split") not in SPLITS:
            raise ValueError(f"invalid corpus split for {image_id}")
        if image.get("eligible_plr_420") is not True:
            raise ValueError(f"JPEG is not verified PLR 4:2:0: {image_id}")
        if int(image["luma_width_in_blocks"]) < 32 or int(
            image["luma_height_in_blocks"]
        ) < 32:
            raise ValueError(f"JPEG is smaller than one training patch: {image_id}")

    split_order = {name: index for index, name in enumerate(SPLITS)}
    images.sort(
        key=lambda image: (
            split_order[str(image["split"])],
            str(image["source_kind"]),
            str(image["image_id"]),
        )
    )
    split_counts = Counter(str(image["split"]) for image in images)
    source_counts = Counter(str(image["source_kind"]) for image in images)
    identity = hashlib.sha256(
        json.dumps(images, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {
        "schema": "pw_plr_combined_exact_jpeg_corpus_v1",
        "photo_count": len(images),
        "total_jpeg_bytes": sum(int(image["bytes"]) for image in images),
        "split_photo_counts": {name: split_counts[name] for name in SPLITS},
        "source_photo_counts": dict(sorted(source_counts.items())),
        "exact_exclusion_overlap_count": 0,
        "content_identity_sha256": identity,
        "images": images,
    }
