import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_complete_pwa2_full_forest_result_is_exact() -> None:
    result_path = ROOT / "results/pwa2-full-forest-complete.json"
    assert result_path.is_file()
    result = json.loads(result_path.read_text())
    assert result["schema"] == "pw_pwa2_full_forest_complete_result_v1"
    assert result["descriptor_nodes"] == 1_251_246
    assert result["predicted_descriptor_nodes"] == 1_243_054
    assert result["unmatched_descriptor_nodes"] == 0
    assert result["all_cells_equal"] == 1
    assert result["all_rows_and_order_equal"] == 1
    assert result["materialized_sqlite_integrity_ok"] == 1
    assert result["random_reads_exact"] == 1
    assert result["corruption_rejected"] == 1
    assert result["source_unchanged"] == 1
    assert result["production_promoted"] is False
