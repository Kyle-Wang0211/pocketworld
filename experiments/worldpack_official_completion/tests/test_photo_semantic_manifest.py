import pytest

from photo_semantic_manifest import build_logical_photo_plan


def test_logical_photo_plan_unifies_raw_jpeg_and_exact_jxl_storage() -> None:
    entries = [
        {"path": "photos_highres/a.jpg.jxl", "bytes": 7, "sha256": "a" * 64},
        {"path": "photos_highres/b.jpg", "bytes": 9, "sha256": "b" * 64},
        {"path": "photos_highres/a.json", "bytes": 3, "sha256": "c" * 64},
    ]
    plan = build_logical_photo_plan(entries)

    assert [(item.logical_path, item.storage_codec) for item in plan] == [
        ("photos_highres/a.jpg", "jxl_0_12_0_exact_jpeg"),
        ("photos_highres/b.jpg", "jpeg_original"),
    ]


def test_logical_photo_plan_rejects_two_storage_truths_for_one_photo() -> None:
    with pytest.raises(ValueError, match="duplicate logical photo"):
        build_logical_photo_plan(
            [
                {"path": "photos_highres/a.jpg", "bytes": 9, "sha256": "a" * 64},
                {
                    "path": "photos_highres/a.jpg.jxl",
                    "bytes": 7,
                    "sha256": "b" * 64,
                },
            ]
        )

