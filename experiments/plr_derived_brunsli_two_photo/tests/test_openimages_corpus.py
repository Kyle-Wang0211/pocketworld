import base64
import csv
import hashlib
import io
import json
from pathlib import Path
import subprocess

import pytest

from pw_plr.openimages_corpus import (
    assign_final_splits,
    download_candidate,
    download_and_probe_cvdf_candidate,
    download_cvdf_candidate,
    enrich_cvdf_candidates,
    parse_cvdf_listing,
    probe_cvdf_jpeg,
    select_metadata_candidates,
    select_cvdf_candidates,
)


FIELDS = [
    "ImageID",
    "Subset",
    "OriginalURL",
    "OriginalLandingURL",
    "License",
    "AuthorProfileURL",
    "Author",
    "Title",
    "OriginalSize",
    "OriginalMD5",
    "Thumbnail300KURL",
    "Rotation",
]


def _csv(rows: list[dict[str, str]]) -> io.StringIO:
    output = io.StringIO()
    writer = csv.DictWriter(output, fieldnames=FIELDS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    output.seek(0)
    return output


def _row(image_id: str, payload: bytes = b"jpeg") -> dict[str, str]:
    return {
        "ImageID": image_id,
        "Subset": "train",
        "OriginalURL": f"https://images.example/{image_id}.jpg",
        "OriginalLandingURL": f"https://landing.example/{image_id}",
        "License": "https://creativecommons.org/licenses/by/2.0/",
        "AuthorProfileURL": "https://author.example/user",
        "Author": "Example Author",
        "Title": "Example Title",
        "OriginalSize": str(len(payload)),
        "OriginalMD5": base64.b64encode(hashlib.md5(payload).digest()).decode(),
        "Thumbnail300KURL": "",
        "Rotation": "0",
    }


def test_select_metadata_candidates_filters_and_is_deterministic() -> None:
    eligible = [_row(f"{index:016x}", b"x" * 200) for index in range(8)]
    wrong_license = _row("f" * 16, b"x" * 200)
    wrong_license["License"] = "https://creativecommons.org/licenses/by-nc/2.0/"
    wrong_split = _row("e" * 16, b"x" * 200)
    wrong_split["Subset"] = "validation"
    too_large = _row("d" * 16, b"x" * 2000)
    rows = eligible + [wrong_license, wrong_split, too_large]

    first = select_metadata_candidates(
        _csv(rows),
        candidate_count=4,
        selection_seed="fixed",
        minimum_original_bytes=100,
        maximum_original_bytes=1000,
    )
    second = select_metadata_candidates(
        _csv(list(reversed(rows))),
        candidate_count=4,
        selection_seed="fixed",
        minimum_original_bytes=100,
        maximum_original_bytes=1000,
    )

    assert first == second
    assert len(first) == 4
    assert all(item["license"] == "https://creativecommons.org/licenses/by/2.0/" for item in first)
    assert all(item["subset"] == "train" for item in first)
    assert [item["selection_rank"] for item in first] == [1, 2, 3, 4]


def test_select_metadata_candidates_rejects_duplicate_image_id() -> None:
    row = _row("0" * 16, b"x" * 200)
    with pytest.raises(ValueError, match="duplicate Open Images ID"):
        select_metadata_candidates(
            _csv([row, row]),
            candidate_count=1,
            selection_seed="fixed",
            minimum_original_bytes=100,
            maximum_original_bytes=1000,
        )


def test_download_candidate_verifies_original_md5_and_sha256(tmp_path: Path) -> None:
    payload = b"\xff\xd8jpeg-payload\xff\xd9"
    candidate = select_metadata_candidates(
        _csv([_row("1" * 16, payload)]),
        candidate_count=1,
        selection_seed="fixed",
        minimum_original_bytes=1,
        maximum_original_bytes=1000,
    )[0]

    result = download_candidate(
        candidate,
        tmp_path,
        fetch=lambda _: payload,
    )

    assert result["status"] == "downloaded_verified"
    assert result["bytes"] == len(payload)
    assert result["sha256"] == hashlib.sha256(payload).hexdigest()
    assert (tmp_path / f"{candidate['image_id']}.jpg").read_bytes() == payload


def test_download_candidate_rejects_md5_mismatch_without_publishing(
    tmp_path: Path,
) -> None:
    candidate = select_metadata_candidates(
        _csv([_row("2" * 16, b"expected")]),
        candidate_count=1,
        selection_seed="fixed",
        minimum_original_bytes=1,
        maximum_original_bytes=1000,
    )[0]

    with pytest.raises(ValueError, match="OriginalMD5 mismatch"):
        download_candidate(
            candidate,
            tmp_path,
            fetch=lambda _: b"diffxxxx",
        )

    assert list(tmp_path.iterdir()) == []


def test_download_candidate_reuses_only_a_verified_existing_file(
    tmp_path: Path,
) -> None:
    payload = b"\xff\xd8existing\xff\xd9"
    candidate = select_metadata_candidates(
        _csv([_row("4" * 16, payload)]),
        candidate_count=1,
        selection_seed="fixed",
        minimum_original_bytes=1,
        maximum_original_bytes=1000,
    )[0]
    (tmp_path / f"{candidate['image_id']}.jpg").write_bytes(payload)

    result = download_candidate(
        candidate,
        tmp_path,
        fetch=lambda _: (_ for _ in ()).throw(AssertionError("network used")),
    )

    assert result["status"] == "reused_verified"
    assert result["sha256"] == hashlib.sha256(payload).hexdigest()


def test_candidate_fields_are_sufficient_for_attribution() -> None:
    candidate = select_metadata_candidates(
        _csv([_row("3" * 16, b"x" * 200)]),
        candidate_count=1,
        selection_seed="fixed",
        minimum_original_bytes=100,
        maximum_original_bytes=1000,
    )[0]

    serialized = json.loads(json.dumps(candidate))
    assert serialized["author"] == "Example Author"
    assert serialized["original_landing_url"].startswith("https://")
    assert serialized["author_profile_url"].startswith("https://")
    assert serialized["original_md5_base64"]


def test_assign_final_splits_is_exact_and_order_independent() -> None:
    images = [
        {"image_id": f"{index:016x}", "sha256": f"sha-{index}"}
        for index in range(10)
    ]

    first = assign_final_splits(
        images,
        split_seed="fixed-split",
        split_counts={"train": 6, "validation": 2, "diagnostic": 2},
    )
    second = assign_final_splits(
        list(reversed(images)),
        split_seed="fixed-split",
        split_counts={"train": 6, "validation": 2, "diagnostic": 2},
    )

    assert first == second
    assert [item["split"] for item in first].count("train") == 6
    assert [item["split"] for item in first].count("validation") == 2
    assert [item["split"] for item in first].count("diagnostic") == 2
    assert all(item["split_score"] for item in first)


def test_assign_final_splits_rejects_duplicate_or_wrong_total() -> None:
    duplicate = [{"image_id": "same"}, {"image_id": "same"}]
    with pytest.raises(ValueError, match="duplicate Open Images ID"):
        assign_final_splits(
            duplicate,
            split_seed="fixed-split",
            split_counts={"train": 1, "validation": 1},
        )

    with pytest.raises(ValueError, match="split counts total"):
        assign_final_splits(
            [{"image_id": "one"}],
            split_seed="fixed-split",
            split_counts={"train": 2},
        )


def test_parse_and_select_cvdf_listing_is_deterministic() -> None:
    first_page = b"""<?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <IsTruncated>true</IsTruncated>
      <NextContinuationToken>next-token</NextContinuationToken>
      <Contents><Key>train/0000000000000001.jpg</Key><ETag>\"11111111111111111111111111111111\"</ETag><Size>10</Size></Contents>
      <Contents><Key>train/0000000000000002.jpg</Key><ETag>\"22222222222222222222222222222222\"</ETag><Size>20</Size></Contents>
    </ListBucketResult>"""
    second_page = b"""<?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <IsTruncated>false</IsTruncated>
      <Contents><Key>train/0000000000000003.jpg</Key><ETag>\"33333333333333333333333333333333\"</ETag><Size>30</Size></Contents>
    </ListBucketResult>"""

    first_items, token = parse_cvdf_listing(first_page)
    second_items, final_token = parse_cvdf_listing(second_page)
    selected = select_cvdf_candidates(
        list(reversed(first_items + second_items)),
        candidate_count=2,
        selection_seed="fixed-cvdf",
    )

    assert token == "next-token"
    assert final_token is None
    assert len(selected) == 2
    assert [item["selection_rank"] for item in selected] == [1, 2]
    assert all(item["cvdf_url"].startswith("https://open-images-dataset.s3.amazonaws.com/train/") for item in selected)


def test_enrich_cvdf_candidates_requires_matching_cc_by_metadata() -> None:
    candidates = [
        {
            "image_id": "0000000000000001",
            "cvdf_url": "https://example/one.jpg",
            "cvdf_bytes": 10,
            "cvdf_etag_md5": "1" * 32,
            "selection_score": "a",
            "selection_rank": 1,
        }
    ]
    enriched = enrich_cvdf_candidates(
        _csv([_row("0000000000000001", b"original")]),
        candidates,
    )

    assert enriched[0]["license"] == "https://creativecommons.org/licenses/by/2.0/"
    assert enriched[0]["author"] == "Example Author"
    assert enriched[0]["cvdf_bytes"] == 10

    wrong_license = _row("0000000000000001", b"original")
    wrong_license["License"] = "https://creativecommons.org/licenses/by-nc/2.0/"
    with pytest.raises(ValueError, match="eligible metadata"):
        enrich_cvdf_candidates(_csv([wrong_license]), candidates)


def test_enrich_cvdf_candidates_can_drop_ineligible_metadata_with_audit() -> None:
    candidates = [
        {
            "image_id": "0000000000000001",
            "selection_score": "a",
            "selection_rank": 1,
        },
        {
            "image_id": "0000000000000002",
            "selection_score": "b",
            "selection_rank": 2,
        },
    ]
    eligible = _row("0000000000000001", b"eligible")
    wrong_license = _row("0000000000000002", b"excluded")
    wrong_license["License"] = "https://creativecommons.org/licenses/by-nc/2.0/"

    enriched = enrich_cvdf_candidates(
        _csv([eligible, wrong_license]),
        candidates,
        require_all=False,
    )

    assert [item["image_id"] for item in enriched] == ["0000000000000001"]


def test_download_cvdf_candidate_verifies_listing_etag_and_jpeg(tmp_path: Path) -> None:
    payload = b"\xff\xd8cvdf-jpeg\xff\xd9"
    candidate = {
        "image_id": "0000000000000001",
        "cvdf_url": "https://example/one.jpg",
        "cvdf_bytes": len(payload),
        "cvdf_etag_md5": hashlib.md5(payload).hexdigest(),
        "selection_rank": 1,
    }

    result = download_cvdf_candidate(
        candidate,
        tmp_path,
        fetch=lambda _: payload,
    )

    assert result["status"] == "downloaded_verified"
    assert result["sha256"] == hashlib.sha256(payload).hexdigest()
    assert (tmp_path / "0000000000000001.jpg").read_bytes() == payload


def test_probe_cvdf_jpeg_requires_exact_source_identity_and_plr_420(
    tmp_path: Path,
) -> None:
    photo = tmp_path / "image.jpg"
    payload = b"\xff\xd8cvdf-jpeg\xff\xd9"
    photo.write_bytes(payload)
    downloaded = {
        "image_id": "0000000000000001",
        "path": str(photo),
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }

    def run_probe(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "width": 4224,
                    "height": 2376,
                    "component_count": 3,
                    "luma_width_in_blocks": 528,
                    "luma_height_in_blocks": 298,
                    "subsampling": "4:2:0",
                    "eligible_plr_420": True,
                    "source_bytes": len(payload),
                    "source_sha256": hashlib.sha256(payload).hexdigest(),
                }
            ),
            stderr="",
        )

    result = probe_cvdf_jpeg(downloaded, Path("probe"), run=run_probe)

    assert result["eligible_plr_420"] is True
    assert result["jpeg_width"] == 4224
    assert result["jpeg_height"] == 2376
    assert result["luma_width_in_blocks"] == 528
    assert result["luma_height_in_blocks"] == 298
    assert result["jpeg_subsampling"] == "4:2:0"


def test_probe_cvdf_jpeg_rejects_probe_identity_mismatch(tmp_path: Path) -> None:
    photo = tmp_path / "image.jpg"
    photo.write_bytes(b"jpeg")
    downloaded = {
        "image_id": "0000000000000002",
        "path": str(photo),
        "bytes": 4,
        "sha256": hashlib.sha256(b"jpeg").hexdigest(),
    }

    def run_probe(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "width": 100,
                    "height": 100,
                    "component_count": 3,
                    "luma_width_in_blocks": 14,
                    "luma_height_in_blocks": 14,
                    "subsampling": "4:2:0",
                    "eligible_plr_420": True,
                    "source_bytes": 4,
                    "source_sha256": "wrong",
                }
            ),
            stderr="",
        )

    with pytest.raises(ValueError, match="probe SHA-256 mismatch"):
        probe_cvdf_jpeg(downloaded, Path("probe"), run=run_probe)


def test_download_and_probe_cvdf_candidate_is_one_verified_worker_unit(
    tmp_path: Path,
) -> None:
    payload = b"\xff\xd8combined-worker\xff\xd9"
    candidate = {
        "image_id": "0000000000000003",
        "cvdf_url": "https://example/three.jpg",
        "cvdf_bytes": len(payload),
        "cvdf_etag_md5": hashlib.md5(payload).hexdigest(),
        "selection_rank": 3,
    }

    def run_probe(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "width": 1024,
                    "height": 768,
                    "component_count": 3,
                    "luma_width_in_blocks": 128,
                    "luma_height_in_blocks": 96,
                    "subsampling": "4:2:0",
                    "eligible_plr_420": True,
                    "source_bytes": len(payload),
                    "source_sha256": hashlib.sha256(payload).hexdigest(),
                }
            ),
            stderr="",
        )

    result = download_and_probe_cvdf_candidate(
        candidate,
        tmp_path,
        Path("probe"),
        fetch=lambda _: payload,
        run=run_probe,
    )

    assert result["sha256"] == hashlib.sha256(payload).hexdigest()
    assert result["eligible_plr_420"] is True
    assert result["luma_width_in_blocks"] == 128
