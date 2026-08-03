"""Freeze whole-capture training exclusions before model work begins."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path

import yaml


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def _photo_manifest(photos_path: Path, expected_count: int) -> list[dict[str, object]]:
    if not photos_path.is_dir():
        raise ValueError(f"capture photo directory is missing: {photos_path}")
    photos = sorted(
        (
            path
            for path in photos_path.iterdir()
            if path.is_file() and path.suffix == ".jpg"
        ),
        key=lambda path: path.name,
    )
    if len(photos) != expected_count:
        raise ValueError(
            f"expected {expected_count} JPEG files in {photos_path}, "
            f"found {len(photos)}"
        )
    return [
        {
            "filename": photo.name,
            "bytes": photo.stat().st_size,
            "sha256": _sha256_file(photo),
        }
        for photo in photos
    ]


def freeze_training_exclusions(
    config_path: Path,
    output_path: Path,
) -> dict[str, object]:
    config_bytes = config_path.read_bytes()
    config = yaml.safe_load(config_bytes)
    if config.get("schema") != "pw_plr_training_exclusion_sources_v1":
        raise ValueError("unsupported training exclusion source schema")

    canonical_capture_id = str(config["canonical_capture_id"])
    expected_count = int(config["expected_photo_count"])
    if expected_count <= 0:
        raise ValueError("expected photo count must be positive")

    manifests: dict[str, list[dict[str, object]]] = {}
    captures: list[dict[str, object]] = []
    seen_capture_ids: set[str] = set()
    for entry in config["captures"]:
        capture_id = str(entry["capture_id"])
        if capture_id in seen_capture_ids:
            raise ValueError(f"duplicate excluded capture id: {capture_id}")
        seen_capture_ids.add(capture_id)
        photos_path = Path(entry["photos_path"])
        if not photos_path.is_absolute():
            photos_path = config_path.parent / photos_path
        photos = _photo_manifest(photos_path, expected_count)
        manifests[capture_id] = photos

        must_match = entry.get("must_be_byte_identical_to")
        if must_match is not None:
            reference_id = str(must_match)
            reference = manifests.get(reference_id)
            if reference is None:
                raise ValueError(
                    "byte-identical reference capture must appear first: "
                    f"{reference_id}"
                )
            if photos != reference:
                raise ValueError(
                    f"capture {capture_id} is not byte-identical to {reference_id}"
                )

        captures.append(
            {
                "capture_id": capture_id,
                "source_path": str(photos_path),
                "photo_count": len(photos),
                "ordered_content_manifest_sha256": _canonical_sha256(photos),
                "byte_identical_to": str(must_match) if must_match else None,
            }
        )

    if canonical_capture_id not in manifests:
        raise ValueError("canonical capture id is not registered")
    excluded_capture_ids = [capture["capture_id"] for capture in captures]
    exclusion_identity = {
        "excluded_capture_ids": excluded_capture_ids,
        "capture_manifest_sha256": {
            capture["capture_id"]: capture["ordered_content_manifest_sha256"]
            for capture in captures
        },
    }
    result: dict[str, object] = {
        "schema": "pw_plr_training_exclusion_manifest_v1",
        "source_config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "canonical_capture_id": canonical_capture_id,
        "canonical_photo_count": expected_count,
        "counting_rule": "regular_files_with_lowercase_jpg_extension",
        "excluded_capture_ids": excluded_capture_ids,
        "captures": captures,
        "canonical_photos": manifests[canonical_capture_id],
        "exclusion_identity_sha256": _canonical_sha256(exclusion_identity),
        "applies_to": ["training", "validation", "model_selection", "tuning"],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary_path, output_path)
    return result


def validate_split_manifest(
    exclusion_manifest: dict[str, object],
    split_manifest: dict[str, object],
) -> int:
    """Reject capture IDs or exact bytes registered as training exclusions."""
    if exclusion_manifest.get("schema") != "pw_plr_training_exclusion_manifest_v1":
        raise ValueError("unsupported training exclusion manifest schema")
    if split_manifest.get("schema") != "pw_plr_dataset_split_v1":
        raise ValueError("unsupported dataset split schema")

    excluded_capture_ids = {
        str(capture_id)
        for capture_id in exclusion_manifest["excluded_capture_ids"]
    }
    excluded_hashes = {
        str(photo["sha256"]).lower()
        for photo in exclusion_manifest["canonical_photos"]
    }
    samples = split_manifest.get("samples")
    if not isinstance(samples, list):
        raise ValueError("dataset split samples must be a list")

    for sample in samples:
        source_id = str(sample["source_id"])
        capture_id = sample.get("capture_id")
        if capture_id is not None and str(capture_id) in excluded_capture_ids:
            raise ValueError(
                f"sample {source_id} belongs to excluded capture {capture_id}"
            )
        sha256 = str(sample["sha256"]).lower()
        if len(sha256) != 64:
            raise ValueError(f"sample {source_id} has invalid SHA-256")
        if sha256 in excluded_hashes:
            raise ValueError(f"sample {source_id} contains excluded photo bytes")
    return len(samples)
