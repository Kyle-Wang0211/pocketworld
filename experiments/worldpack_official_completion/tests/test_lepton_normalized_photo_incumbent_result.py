from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_lepton_normalized_incumbent_is_exact_and_strictly_smaller() -> None:
    result = json.loads(
        (ROOT / "results/worldpack-lepton-normalized-incumbent.json").read_text()
    )
    assert result["schema"] == "pw_worldpack_lepton_normalized_incumbent_v1"
    assert result["jxl_backed_photo_count_tested"] == 111
    assert result["candidate_roundtrip_exact"] == 111
    assert result["selected_lepton_photo_count"] > 0
    assert result["complete_persisted_bytes"] < result["predecessor_archive_bytes"]
    assert result["logical_original_jpegs_byte_equal"] == 155
    assert result["logical_original_jpegs_sha256_equal"] == 155
    assert result["logical_photo_identity_sha256"] == (
        "cbb1dc6681a764d5ea51a3effa32fde42728375414f3b0345e690f87412c237b"
    )
    assert result["physical_sqlite_member_present"] is False
    assert result["database_page_history_preserved"] is False
    assert result["random_reads_exact"] == 1
    assert result["corruption_rejected"] == 1
    assert result["source_unchanged"] == 1
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
