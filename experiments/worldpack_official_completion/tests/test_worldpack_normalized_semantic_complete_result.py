import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_complete_normalized_semantic_archive_has_no_physical_sqlite_truth() -> None:
    result_path = ROOT / "results/worldpack-normalized-semantic-complete.json"
    assert result_path.is_file()
    result = json.loads(result_path.read_text())
    assert result["schema"] == "pw_worldpack_normalized_semantic_complete_v1"
    assert result["physical_sqlite_member_present"] is False
    assert result["database_page_history_preserved"] is False
    assert result["database_all_cells_equal"] == 1
    assert result["database_all_rows_and_order_equal"] == 1
    assert result["materialized_sqlite_integrity_ok"] == 1
    assert result["retained_members_byte_equal"] == 321
    assert result["retained_members_sha256_equal"] == 321
    assert result["logical_output_member_count"] == 322
    assert result["random_reads_exact"] == 1
    assert result["corruption_rejected"] == 1
    assert result["source_unchanged"] == 1
    assert result["production_promoted"] is False

