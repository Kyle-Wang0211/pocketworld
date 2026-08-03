import hashlib
import json
from pathlib import Path

import pytest
import yaml

from pw_plr.training_exclusion import (
    freeze_training_exclusions,
    validate_split_manifest,
)


def _write_config(tmp_path: Path, *, mutate_clone: bool = False) -> Path:
    original = tmp_path / "capture"
    clone = tmp_path / "capture_v2"
    original.mkdir()
    clone.mkdir()
    for index, payload in enumerate((b"one", b"two")):
        filename = f"frame_{index}.jpg"
        (original / filename).write_bytes(payload)
        clone_payload = b"changed" if mutate_clone and index == 1 else payload
        (clone / filename).write_bytes(clone_payload)

    config = tmp_path / "sources.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "schema": "pw_plr_training_exclusion_sources_v1",
                "canonical_capture_id": "capture",
                "expected_photo_count": 2,
                "captures": [
                    {"capture_id": "capture", "photos_path": str(original)},
                    {
                        "capture_id": "capture_v2",
                        "photos_path": str(clone),
                        "must_be_byte_identical_to": "capture",
                    },
                ],
            },
            sort_keys=False,
        )
    )
    return config


def test_freeze_training_exclusions_records_complete_capture_and_duplicate(
    tmp_path: Path,
) -> None:
    config = _write_config(tmp_path)
    output = tmp_path / "exclusions.json"

    result = freeze_training_exclusions(config, output)

    assert result["schema"] == "pw_plr_training_exclusion_manifest_v1"
    assert result["excluded_capture_ids"] == ["capture", "capture_v2"]
    assert result["canonical_photo_count"] == 2
    assert result["captures"][1]["byte_identical_to"] == "capture"
    assert result["captures"][0]["ordered_content_manifest_sha256"] == (
        result["captures"][1]["ordered_content_manifest_sha256"]
    )
    assert [photo["filename"] for photo in result["canonical_photos"]] == [
        "frame_0.jpg",
        "frame_1.jpg",
    ]
    assert result["canonical_photos"][0]["sha256"] == hashlib.sha256(
        b"one"
    ).hexdigest()
    assert json.loads(output.read_text()) == result
    assert not output.with_suffix(".json.tmp").exists()


def test_freeze_training_exclusions_rejects_nonidentical_registered_clone(
    tmp_path: Path,
) -> None:
    config = _write_config(tmp_path, mutate_clone=True)

    with pytest.raises(ValueError, match="not byte-identical"):
        freeze_training_exclusions(config, tmp_path / "exclusions.json")


def test_freeze_training_exclusions_rejects_wrong_photo_count(tmp_path: Path) -> None:
    config = _write_config(tmp_path)
    document = yaml.safe_load(config.read_text())
    document["expected_photo_count"] = 3
    config.write_text(yaml.safe_dump(document, sort_keys=False))

    with pytest.raises(ValueError, match="expected 3 JPEG files"):
        freeze_training_exclusions(config, tmp_path / "exclusions.json")


def test_validate_split_rejects_neighbor_from_excluded_capture(tmp_path: Path) -> None:
    exclusion = freeze_training_exclusions(
        _write_config(tmp_path), tmp_path / "exclusions.json"
    )
    split = {
        "schema": "pw_plr_dataset_split_v1",
        "split": "train",
        "samples": [
            {
                "source_id": "neighbor",
                "capture_id": "capture",
                "sha256": "f" * 64,
            }
        ],
    }

    with pytest.raises(ValueError, match="excluded capture"):
        validate_split_manifest(exclusion, split)


def test_validate_split_rejects_excluded_bytes_under_another_capture_id(
    tmp_path: Path,
) -> None:
    exclusion = freeze_training_exclusions(
        _write_config(tmp_path), tmp_path / "exclusions.json"
    )
    split = {
        "schema": "pw_plr_dataset_split_v1",
        "split": "validation",
        "samples": [
            {
                "source_id": "renamed-copy",
                "capture_id": "unrelated-id",
                "sha256": exclusion["canonical_photos"][0]["sha256"],
            }
        ],
    }

    with pytest.raises(ValueError, match="excluded photo bytes"):
        validate_split_manifest(exclusion, split)


def test_validate_split_accepts_unrelated_sample(tmp_path: Path) -> None:
    exclusion = freeze_training_exclusions(
        _write_config(tmp_path), tmp_path / "exclusions.json"
    )
    split = {
        "schema": "pw_plr_dataset_split_v1",
        "split": "tuning",
        "samples": [
            {
                "source_id": "external-natural-image",
                "capture_id": None,
                "sha256": hashlib.sha256(b"unrelated").hexdigest(),
            }
        ],
    }

    assert validate_split_manifest(exclusion, split) == 1
