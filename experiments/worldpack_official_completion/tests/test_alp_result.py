from __future__ import annotations

import json
from pathlib import Path
import sqlite3


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
RESULT_PATH = EXPERIMENT_ROOT / "results" / "alp-minimum.json"


def test_alp_minimum_result_covers_every_real_registered_column() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["schema"] == "pw_alp_complete_minimum_result_v1"
    assert result["scope"] == "all_registered_real_float_columns_minimum"
    assert result["official_revision"] == (
        "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce"
    )
    assert result["source_tree_clean"] is True
    assert result["run_count_per_arm"] == 1
    arms = result["columns"]
    assert len(arms) == 27
    assert sum(arm["element_type"] == "float32" for arm in arms) == 26
    assert sum(arm["element_type"] == "float64" for arm in arms) == 1
    assert len({arm["label"] for arm in arms}) == len(arms)
    assert all(arm["byte_equal"] == 1 for arm in arms)
    assert all(arm["sha256_equal"] == 1 for arm in arms)
    assert all(arm["corruption_rejected"] == 1 for arm in arms)
    assert all(arm["alp_complete_persisted_bytes"] > 0 for arm in arms)
    assert all(arm["zpaq_complete_persisted_bytes"] > 0 for arm in arms)
    assert all(arm["local_winner"] in {"alp", "zpaq_method5"} for arm in arms)
    assert result["input_bytes"] == sum(arm["input_bytes"] for arm in arms)
    assert result["selected_bytes"] == sum(
        min(
            arm["alp_complete_persisted_bytes"],
            arm["zpaq_complete_persisted_bytes"],
        )
        for arm in arms
    )


def test_alp_result_is_host_only_and_has_mlflow_identity() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
    assert result["family_global_optimum_claimed"] is False
    run_id = result["mlflow_run_id"]
    with sqlite3.connect(EXPERIMENT_ROOT / result["mlflow_tracking_store"]) as database:
        stored = database.execute(
            "SELECT status FROM runs WHERE run_uuid = ?", (run_id,)
        ).fetchone()
    assert stored == ("FINISHED",)
