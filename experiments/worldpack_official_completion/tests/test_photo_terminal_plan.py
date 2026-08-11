from __future__ import annotations

import hashlib
from pathlib import Path

from photo_terminal_plan import build_terminal_photo_rewrite_plan


def _sha(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def test_terminal_plan_drops_only_selected_incumbent_and_adds_one_model(
    tmp_path: Path,
) -> None:
    archive = tmp_path / "a.pwpa"
    side = tmp_path / "a.pwbs"
    model = tmp_path / "model.pwmst"
    archive.write_bytes(b"learned-photo")
    side.write_bytes(b"exact-side")
    model.write_bytes(b"shared-model")
    logical = {
        "photos": [
            {
                "logical_path": "photos/a.jpg",
                "storage_path": "photos/a.jpg.jxl",
            },
            {
                "logical_path": "photos/b.jpg",
                "storage_path": "photos/b.jpg",
            },
        ]
    }
    progress = {
        "photos/a.jpg": {
            "photo_archive_path": str(archive),
            "photo_archive_bytes": archive.stat().st_size,
            "photo_archive_sha256": _sha(archive.read_bytes()),
            "photo_archive_member_path": "__semantic__/photos/a.pwpa",
            "side_path": str(side),
            "side_bytes": side.stat().st_size,
            "side_sha256": _sha(side.read_bytes()),
            "side_member_path": "__semantic__/photos/a.pwbs",
            "byte_equal": True,
            "sha256_equal": True,
            "integer_cdf_trace_equal": True,
        }
    }

    plan = build_terminal_photo_rewrite_plan(
        logical,
        progress_records=progress,
        selected_logical_paths=("photos/a.jpg",),
        model_storage_path=model,
        model_storage_codec="zstd_1_5_7_level22",
    )

    assert plan.drop_paths == {
        "__semantic__/manifest.json",
        "photos/a.jpg.jxl",
    }
    assert [addition.relative_path for addition in plan.additions] == [
        "__semantic__/photos/model.pwmst",
        "__semantic__/photos/a.pwpa",
        "__semantic__/photos/a.pwbs",
    ]
    assert plan.learned_records["photos/a.jpg"]["photo_archive_path"] == (
        "__semantic__/photos/a.pwpa"
    )
    assert plan.shared_model["bytes"] == model.stat().st_size


def test_terminal_plan_rejects_unverified_or_unknown_selection(tmp_path: Path) -> None:
    model = tmp_path / "model.pwmst"
    model.write_bytes(b"model")
    logical = {"photos": [{"logical_path": "photos/a.jpg", "storage_path": "a"}]}

    try:
        build_terminal_photo_rewrite_plan(
            logical,
            progress_records={},
            selected_logical_paths=("photos/unknown.jpg",),
            model_storage_path=model,
            model_storage_codec="raw",
        )
    except ValueError as error:
        assert "unknown" in str(error)
    else:
        raise AssertionError("unknown selection must fail closed")
