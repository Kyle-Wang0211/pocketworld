import hashlib
import json
from pathlib import Path

import pytest
import yaml

from pw_plr.training_corpus import freeze_training_corpus
from pw_plr.training_exclusion import freeze_training_exclusions


def _write_exclusion(tmp_path: Path) -> tuple[Path, Path]:
    excluded = tmp_path / "excluded"
    excluded.mkdir()
    (excluded / "cell_85_slot_4.jpg").write_bytes(b"frozen")
    config = tmp_path / "exclusion-sources.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "schema": "pw_plr_training_exclusion_sources_v1",
                "canonical_capture_id": "frozen-capture",
                "expected_photo_count": 1,
                "captures": [
                    {
                        "capture_id": "frozen-capture",
                        "photos_path": str(excluded),
                    }
                ],
            },
            sort_keys=False,
        )
    )
    output = tmp_path / "exclusions.json"
    freeze_training_exclusions(config, output)
    return excluded, output


def _write_corpus_config(
    tmp_path: Path,
    exclusion_path: Path,
    *,
    leak_excluded_bytes: bool = False,
) -> Path:
    photos = tmp_path / "training"
    photos.mkdir()
    payloads = {
        "cell_1_slot_0.jpg": b"one-a",
        "cell_1_slot_1.jpg": b"one-b",
        "cell_2_slot_0.jpg": b"two-a",
        "cell_2_slot_1.jpg": b"two-b",
        "cell_3_slot_0.jpg": b"three-a",
        "cell_4_slot_0.jpg": b"frozen" if leak_excluded_bytes else b"four-a",
    }
    for filename, payload in payloads.items():
        (photos / filename).write_bytes(payload)

    config = tmp_path / "corpus.yaml"
    config.write_text(
        yaml.safe_dump(
            {
                "schema": "pw_plr_training_corpus_sources_v1",
                "capture_id": "training-capture",
                "source_kind": "first_party_user_capture",
                "photos_path": str(photos),
                "expected_photo_count": 6,
                "expected_group_count": 4,
                "group_pattern": r"^cell_(\d+)_slot_\d+\.jpg$",
                "split_seed": "unit-test-seed",
                "split_group_counts": {
                    "train": 2,
                    "validation": 1,
                    "diagnostic": 1,
                },
                "exclusion_manifest": str(exclusion_path),
            },
            sort_keys=False,
        )
    )
    return config


def test_freeze_training_corpus_keeps_cells_in_one_split(tmp_path: Path) -> None:
    _, exclusions = _write_exclusion(tmp_path)
    config = _write_corpus_config(tmp_path, exclusions)
    output = tmp_path / "corpus.json"

    result = freeze_training_corpus(config, output)

    assert result["schema"] == "pw_plr_training_corpus_manifest_v1"
    assert result["photo_count"] == 6
    assert result["group_count"] == 4
    assert result["exact_exclusion_overlap_count"] == 0
    assert result["split_group_counts"] == {
        "diagnostic": 1,
        "train": 2,
        "validation": 1,
    }
    sample_groups: dict[str, set[str]] = {}
    for split_name, split in result["splits"].items():
        for sample in split["samples"]:
            sample_groups.setdefault(sample["group_id"], set()).add(split_name)
    assert all(len(split_names) == 1 for split_names in sample_groups.values())
    assert result["ordered_content_manifest_sha256"] == hashlib.sha256(
        json.dumps(
            result["photos"],
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
    ).hexdigest()
    assert json.loads(output.read_text()) == result


def test_freeze_training_corpus_is_deterministic(tmp_path: Path) -> None:
    _, exclusions = _write_exclusion(tmp_path)
    config = _write_corpus_config(tmp_path, exclusions)

    first = freeze_training_corpus(config, tmp_path / "first.json")
    second = freeze_training_corpus(config, tmp_path / "second.json")

    assert first == second


def test_freeze_training_corpus_rejects_exact_excluded_bytes(
    tmp_path: Path,
) -> None:
    _, exclusions = _write_exclusion(tmp_path)
    config = _write_corpus_config(
        tmp_path,
        exclusions,
        leak_excluded_bytes=True,
    )

    with pytest.raises(ValueError, match="excluded photo bytes"):
        freeze_training_corpus(config, tmp_path / "corpus.json")


def test_freeze_training_corpus_rejects_group_count_drift(tmp_path: Path) -> None:
    _, exclusions = _write_exclusion(tmp_path)
    config = _write_corpus_config(tmp_path, exclusions)
    document = yaml.safe_load(config.read_text())
    document["expected_group_count"] = 5
    config.write_text(yaml.safe_dump(document, sort_keys=False))

    with pytest.raises(ValueError, match="expected 5 capture groups"):
        freeze_training_corpus(config, tmp_path / "corpus.json")
