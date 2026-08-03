import pytest

from pw_plr.combined_corpus import combine_verified_corpora


def _image(image_id: str, sha256: str, split: str, source_kind: str) -> dict:
    return {
        "image_id": image_id,
        "sha256": sha256,
        "bytes": 100,
        "split": split,
        "source_kind": source_kind,
        "eligible_plr_420": True,
        "luma_width_in_blocks": 64,
        "luma_height_in_blocks": 64,
    }


def test_combine_verified_corpora_preserves_exact_split_and_source_counts() -> None:
    result = combine_verified_corpora(
        [
            _image("first-train", "1" * 64, "train", "first_party"),
            _image("first-val", "2" * 64, "validation", "first_party"),
        ],
        [
            _image("public-train", "3" * 64, "train", "openimages_v7_cvdf"),
            _image("public-diag", "4" * 64, "diagnostic", "openimages_v7_cvdf"),
        ],
        excluded_sha256={"f" * 64},
    )

    assert result["photo_count"] == 4
    assert result["split_photo_counts"] == {
        "train": 2,
        "validation": 1,
        "diagnostic": 1,
    }
    assert result["source_photo_counts"] == {
        "first_party": 2,
        "openimages_v7_cvdf": 2,
    }
    assert result["exact_exclusion_overlap_count"] == 0
    assert len(result["content_identity_sha256"]) == 64


def test_combine_verified_corpora_rejects_duplicate_or_excluded_bytes() -> None:
    duplicate = _image("duplicate", "1" * 64, "validation", "openimages_v7_cvdf")
    with pytest.raises(ValueError, match="duplicate JPEG SHA-256"):
        combine_verified_corpora(
            [_image("first", "1" * 64, "train", "first_party")],
            [duplicate],
            excluded_sha256=set(),
        )

    with pytest.raises(ValueError, match="frozen exclusion"):
        combine_verified_corpora(
            [_image("first", "2" * 64, "train", "first_party")],
            [],
            excluded_sha256={"2" * 64},
        )
