from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_full_semantic_incumbent_restores_database_and_all_original_jpegs() -> None:
    result_path = ROOT / "results/worldpack-full-semantic-incumbent.json"
    assert result_path.is_file()
    result = json.loads(result_path.read_text())
    assert result["schema"] == "pw_worldpack_full_semantic_incumbent_v1"
    assert result["physical_sqlite_member_present"] is False
    assert result["database_page_history_preserved"] is False
    assert result["database_all_cells_equal"] == 1
    assert result["database_all_rows_and_order_equal"] == 1
    assert result["materialized_sqlite_integrity_ok"] == 1
    assert result["logical_photo_count"] == 155
    assert result["logical_original_jpegs_byte_equal"] == 155
    assert result["logical_original_jpegs_sha256_equal"] == 155
    assert result["logical_photo_identity_sha256"] == (
        "cbb1dc6681a764d5ea51a3effa32fde42728375414f3b0345e690f87412c237b"
    )
    assert result["learned_photo_count"] == 0
    assert result["photo_terminal_decision"] == "pending_plr_phase4"
    assert result["random_reads_exact"] == 1
    assert result["corruption_rejected"] == 1
    assert result["source_unchanged"] == 1
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
