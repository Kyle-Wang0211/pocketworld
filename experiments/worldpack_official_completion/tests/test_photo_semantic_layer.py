from __future__ import annotations

import pytest

from photo_semantic_layer import build_photo_layer_manifest


def _logical_document() -> dict[str, object]:
    return {
        "schema": "pw_worldpack_logical_photo_manifest_v1",
        "logical_photo_count": 2,
        "logical_photo_identity_sha256": "99" * 32,
        "photos": [
            {
                "logical_path": "photos_highres/a.jpg",
                "logical_bytes": 100,
                "logical_sha256": "11" * 32,
                "storage_path": "photos_highres/a.jpg.jxl",
                "storage_codec": "jxl_0_12_0_exact_jpeg",
                "storage_bytes": 80,
                "storage_sha256": "22" * 32,
            },
            {
                "logical_path": "photos_highres/b.jpg",
                "logical_bytes": 120,
                "logical_sha256": "33" * 32,
                "storage_path": "photos_highres/b.jpg",
                "storage_codec": "jpeg_original",
                "storage_bytes": 120,
                "storage_sha256": "33" * 32,
            },
        ],
    }


def test_incumbent_layer_maps_storage_members_to_original_jpeg_truth() -> None:
    layer = build_photo_layer_manifest(_logical_document())

    assert layer["schema"] == "pw_semantic_photo_layer_v1"
    assert layer["original_jpeg_byte_recovery_required"] is True
    assert layer["learned_photo_count"] == 0
    assert layer["retained_incumbent_photo_count"] == 2
    assert layer["shared_model"] is None
    assert layer["photos"][0]["logical_sha256"] == "11" * 32
    assert layer["photos"][0]["storage_members"] == [
        {
            "path": "photos_highres/a.jpg.jxl",
            "codec": "jxl_0_12_0_exact_jpeg",
            "bytes": 80,
            "sha256": "22" * 32,
        }
    ]


def test_normalized_v2_logical_photo_manifest_is_accepted() -> None:
    document = _logical_document()
    document["schema"] = "pw_worldpack_logical_photo_manifest_v2"

    layer = build_photo_layer_manifest(document)

    assert layer["logical_photo_count"] == 2


def test_learned_layer_replaces_only_selected_photo_and_accounts_one_model() -> None:
    learned = {
        "photos_highres/a.jpg": {
            "photo_archive_path": "__semantic__/photos/a.pwpa",
            "photo_archive_bytes": 55,
            "photo_archive_sha256": "44" * 32,
            "side_path": "__semantic__/photos/a.pwbs",
            "side_bytes": 5,
            "side_sha256": "55" * 32,
        }
    }
    model = {
        "path": "__semantic__/photos/model.pwmst",
        "bytes": 20,
        "sha256": "66" * 32,
        "codec": "zstd_1_5_7_level22",
    }

    layer = build_photo_layer_manifest(
        _logical_document(), learned_records=learned, shared_model=model
    )

    assert layer["learned_photo_count"] == 1
    assert layer["retained_incumbent_photo_count"] == 1
    assert layer["shared_model"] == model
    assert [member["path"] for member in layer["photos"][0]["storage_members"]] == [
        "__semantic__/photos/a.pwpa",
        "__semantic__/photos/a.pwbs",
    ]
    assert layer["photos"][1]["storage_kind"] == "incumbent_exact_jpeg"


def test_learned_layer_fails_closed_on_missing_model_or_unknown_photo() -> None:
    learned = {
        "photos_highres/unknown.jpg": {
            "photo_archive_path": "__semantic__/photos/unknown.pwpa",
            "photo_archive_bytes": 1,
            "photo_archive_sha256": "44" * 32,
            "side_path": "__semantic__/photos/unknown.pwbs",
            "side_bytes": 1,
            "side_sha256": "55" * 32,
        }
    }
    with pytest.raises(ValueError, match="shared model"):
        build_photo_layer_manifest(_logical_document(), learned_records=learned)
    with pytest.raises(ValueError, match="unknown logical photo"):
        build_photo_layer_manifest(
            _logical_document(),
            learned_records=learned,
            shared_model={
                "path": "__semantic__/photos/model.pwmst",
                "bytes": 20,
                "sha256": "66" * 32,
                "codec": "raw",
            },
        )
