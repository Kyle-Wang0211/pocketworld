from __future__ import annotations

import json
from pathlib import Path
import sys


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
RESULTS = EXPERIMENT_ROOT / "results"
MANIFEST_SHA256 = "46d0621460ffd99dbb6c9da5bd7340a177f8242d86b1bc83b4be70edbd9c2a92"


def test_similarity_result_path_is_independent_of_working_directory(
    tmp_path: Path, monkeypatch,
) -> None:
    sys.path.insert(0, str(EXPERIMENT_ROOT))
    import run_benchmark

    monkeypatch.chdir(tmp_path)
    expected = (
        EXPERIMENT_ROOT.parent
        / "descriptor_similarity_forest_zpaq"
        / "results"
        / "2026-08-02-descriptor-similarity-forest-zpaq.json"
    )
    assert run_benchmark.similarity_forest_result_path() == expected
    assert run_benchmark.similarity_forest_result_path().is_file()


def _result(name: str) -> dict[str, object]:
    return json.loads((RESULTS / name).read_text())


def _assert_common(result: dict[str, object], expected_schema: str) -> None:
    assert result["schema"] == expected_schema
    assert result["input_manifest_sha256"] == MANIFEST_SHA256
    assert result["source_unchanged"] == 1
    assert result["all_members_byte_equal"] == 1
    assert result["all_members_sha256_equal"] == 1
    assert result["corruption_rejected"] == 1
    assert result["complete_persisted_bytes"] == sum(
        result[key]
        for key in (
            "header_bytes",
            "chunk_header_bytes",
            "payload_bytes",
            "index_bytes",
            "footer_bytes",
        )
    )
    assert result["archive_sha256"]
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False


def test_worldpack_minimum_mixed_result_is_exact() -> None:
    result = _result("worldpack-minimum.json")
    _assert_common(result, "pw_worldpack_minimum_result_v1")
    assert result["member_count"] >= 5
    assert set(result["selected_codec_counts"]) >= {
        "raw",
        "lepton_jpeg_0_5_8",
        "zpaq_7_15_method5",
    }
    assert result["random_reads_exact"] == 1


def test_worldpack_approximately_100mb_result_uses_actual_ordered_bytes() -> None:
    result = _result("worldpack-approximately-100mb.json")
    _assert_common(result, "pw_worldpack_approximately_100mb_result_v1")
    assert 100_000_000 <= result["source_bytes"] <= 110_000_000
    assert result["selection_policy"] == "ordered_photo_prefix_at_least_100000000"
    assert result["member_count"] >= 30
    assert result["random_reads_exact"] == 1
    assert result["sqlite_integrity_check"] == "not_in_scope"


def test_worldpack_complete_result_restores_every_frozen_file() -> None:
    result = _result("worldpack-complete-project.json")
    _assert_common(result, "pw_worldpack_complete_project_result_v1")
    assert result["source_bytes"] == 580_406_089
    assert result["member_count"] == 322
    assert result["restored_member_count"] == 322
    assert result["sqlite_integrity_check"] == "ok"
    assert result["random_read_count"] == 8
    assert result["random_reads_exact"] == 1
    assert result["selected_codec_counts"]["similarity_forest_v1_zpaq_7_15"] == 1
    assert result["database_archive_bytes"] == 116_739_319
    assert result["source_manifest_reverified"] == 1
