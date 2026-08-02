from __future__ import annotations

import json
from pathlib import Path


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
RESULT_PATH = EXPERIMENT_ROOT / "results" / "alp-complete.json"


def test_alp_complete_expands_only_minimum_winning_keypoint_columns() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["schema"] == "pw_alp_complete_expansion_result_v1"
    assert result["scope"] == "complete_minimum_winning_keypoint_columns"
    assert result["official_revision"] == (
        "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce"
    )
    expected = {
        "keypoint_float32_2",
        "keypoint_float32_3",
        "keypoint_float32_4",
        "keypoint_float32_5",
    }
    columns = result["columns"]
    assert {column["label"] for column in columns} == expected
    assert all(column["input_bytes"] > 4096 for column in columns)
    assert all(column["byte_equal"] == 1 for column in columns)
    assert all(column["sha256_equal"] == 1 for column in columns)
    assert all(column["corruption_rejected"] == 1 for column in columns)
    assert result["selected_bytes"] == sum(
        min(
            column["alp_complete_persisted_bytes"],
            column["zpaq_complete_persisted_bytes"],
        )
        for column in columns
    )
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
