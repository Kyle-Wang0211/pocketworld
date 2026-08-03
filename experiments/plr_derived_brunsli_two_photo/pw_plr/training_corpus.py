"""Freeze a leakage-safe first-party natural-JPEG training corpus."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re

import yaml

from pw_plr.training_exclusion import validate_split_manifest


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


def _resolve(base: Path, value: object) -> Path:
    path = Path(str(value))
    return path if path.is_absolute() else base / path


def freeze_training_corpus(
    config_path: Path,
    output_path: Path,
) -> dict[str, object]:
    config_bytes = config_path.read_bytes()
    config = yaml.safe_load(config_bytes)
    if config.get("schema") != "pw_plr_training_corpus_sources_v1":
        raise ValueError("unsupported training corpus source schema")
    if config.get("source_kind") != "first_party_user_capture":
        raise ValueError("Phase 2 corpus must be registered as first-party data")

    photos_path = _resolve(config_path.parent, config["photos_path"])
    if not photos_path.is_dir():
        raise ValueError(f"training photo directory is missing: {photos_path}")
    expected_photo_count = int(config["expected_photo_count"])
    expected_group_count = int(config["expected_group_count"])
    pattern = re.compile(str(config["group_pattern"]))
    capture_id = str(config["capture_id"])

    paths = sorted(
        (
            path
            for path in photos_path.iterdir()
            if path.is_file() and path.suffix == ".jpg"
        ),
        key=lambda path: path.name,
    )
    if len(paths) != expected_photo_count:
        raise ValueError(
            f"expected {expected_photo_count} JPEG files in {photos_path}, "
            f"found {len(paths)}"
        )

    photos: list[dict[str, object]] = []
    groups: dict[str, list[dict[str, object]]] = {}
    for path in paths:
        match = pattern.fullmatch(path.name)
        if match is None:
            raise ValueError(f"photo does not match frozen group pattern: {path.name}")
        group_id = f"cell_{int(match.group(1))}"
        photo = {
            "filename": path.name,
            "bytes": path.stat().st_size,
            "sha256": _sha256_file(path),
            "group_id": group_id,
        }
        photos.append(photo)
        groups.setdefault(group_id, []).append(photo)
    if len(groups) != expected_group_count:
        raise ValueError(
            f"expected {expected_group_count} capture groups, found {len(groups)}"
        )

    split_counts = {
        str(name): int(count)
        for name, count in config["split_group_counts"].items()
    }
    if set(split_counts) != {"train", "validation", "diagnostic"}:
        raise ValueError("split_group_counts must define train/validation/diagnostic")
    if sum(split_counts.values()) != len(groups):
        raise ValueError("split group counts do not cover every capture group")

    seed = str(config["split_seed"])
    ordered_groups = sorted(
        groups,
        key=lambda group_id: (
            hashlib.sha256(f"{seed}:{group_id}".encode()).hexdigest(),
            group_id,
        ),
    )
    assignment: dict[str, str] = {}
    position = 0
    for split_name in ("train", "validation", "diagnostic"):
        count = split_counts[split_name]
        for group_id in ordered_groups[position : position + count]:
            assignment[group_id] = split_name
        position += count

    exclusion_path = _resolve(config_path.parent, config["exclusion_manifest"])
    exclusion_bytes = exclusion_path.read_bytes()
    exclusion_manifest = json.loads(exclusion_bytes)
    split_documents: dict[str, dict[str, object]] = {}
    for split_name in ("train", "validation", "diagnostic"):
        samples = [
            {
                "source_id": f"{capture_id}/{photo['filename']}",
                "capture_id": capture_id,
                "filename": photo["filename"],
                "bytes": photo["bytes"],
                "sha256": photo["sha256"],
                "group_id": photo["group_id"],
            }
            for photo in photos
            if assignment[str(photo["group_id"])] == split_name
        ]
        validation_document = {
            "schema": "pw_plr_dataset_split_v1",
            "split": split_name,
            "samples": samples,
        }
        validate_split_manifest(exclusion_manifest, validation_document)
        split_documents[split_name] = {
            "group_count": split_counts[split_name],
            "photo_count": len(samples),
            "content_manifest_sha256": _canonical_sha256(samples),
            "samples": samples,
        }

    excluded_hashes = {
        str(photo["sha256"]).lower()
        for photo in exclusion_manifest["canonical_photos"]
    }
    exact_overlap = sum(
        str(photo["sha256"]).lower() in excluded_hashes for photo in photos
    )
    result: dict[str, object] = {
        "schema": "pw_plr_training_corpus_manifest_v1",
        "source_config_sha256": hashlib.sha256(config_bytes).hexdigest(),
        "capture_id": capture_id,
        "source_kind": "first_party_user_capture",
        "source_path": str(photos_path),
        "photo_count": len(photos),
        "group_count": len(groups),
        "total_jpeg_bytes": sum(int(photo["bytes"]) for photo in photos),
        "counting_rule": "regular_files_with_lowercase_jpg_extension",
        "group_pattern": str(config["group_pattern"]),
        "split_seed": seed,
        "split_policy": "whole_cell_hash_partition_no_cross_split_cell",
        "split_group_counts": dict(sorted(split_counts.items())),
        "exclusion_manifest_sha256": hashlib.sha256(exclusion_bytes).hexdigest(),
        "exact_exclusion_overlap_count": exact_overlap,
        "ordered_content_manifest_sha256": _canonical_sha256(photos),
        "photos": photos,
        "splits": split_documents,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = output_path.with_suffix(output_path.suffix + ".tmp")
    temporary_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    os.replace(temporary_path, output_path)
    return result
