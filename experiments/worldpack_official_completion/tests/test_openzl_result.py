from __future__ import annotations

import json
from pathlib import Path
import sqlite3


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
RESULT_PATH = EXPERIMENT_ROOT / "results" / "openzl-minimum.json"


def test_openzl_minimum_result_covers_every_registered_official_mode() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["schema"] == "pw_openzl_complete_minimum_result_v1"
    assert result["scope"] == "minimum_descriptor_bundle"
    assert result["official_revision"] == (
        "3dceb64867840201fb8f57a29d179995f700c9b8"
    )
    assert result["source_tree_clean"] is True
    assert result["typed_parser"] == "pw_exact_frame_bundle_v1"
    assert result["training_time_limit_seconds"] is None
    assert result["official_ace_max_generations"] == 250
    assert result["run_count_per_arm"] == 1

    train_hashes = set(result["train_chunk_sha256"])
    test_hashes = set(result["test_chunk_sha256"])
    assert train_hashes
    assert test_hashes
    assert train_hashes.isdisjoint(test_hashes)

    arms = {arm["mode"]: arm for arm in result["arms"]}
    assert set(arms) == {
        "untrained_parser",
        "ace_complete",
        "clustering_plus_ace_complete",
        "zpaq_method5",
    }
    for arm in arms.values():
        assert arm["input_bytes"] > 0
        assert arm["frame_bytes"] > 0
        assert arm["complete_persisted_bytes"] == (
            arm["frame_bytes"] + arm["decoder_dependency_bytes"]
        )
        assert arm["encoder_model_bytes"] >= 0
        assert arm["byte_equal"] == 1
        assert arm["sha256_equal"] == 1
        assert arm["source_sha256"] == arm["restored_sha256"]
        assert arm["corruption_rejected"] == 1
    assert arms["ace_complete"]["training_completed"] == 1
    assert arms["clustering_plus_ace_complete"]["training_completed"] == 1
    assert arms["ace_complete"]["completion_semantics"] == (
        "official_return_without_max_time"
    )
    assert arms["clustering_plus_ace_complete"]["completion_semantics"] == (
        "official_return_without_max_time"
    )


def test_openzl_result_does_not_overclaim_unregistered_modes() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
    assert result["conclusion_scope"] == "registered_openzl_0_2_0_modes_only"
    assert result["family_global_optimum_claimed"] is False


def test_openzl_result_has_durable_mlflow_identity() -> None:
    result = json.loads(RESULT_PATH.read_text())
    run_id = result["mlflow_run_id"]
    assert len(run_id) == 32
    assert all(character in "0123456789abcdef" for character in run_id)
    tracking_database = EXPERIMENT_ROOT / result["mlflow_tracking_store"]
    assert tracking_database.is_file()
    with sqlite3.connect(tracking_database) as database:
        stored = database.execute(
            "SELECT status FROM runs WHERE run_uuid = ?", (run_id,)
        ).fetchone()
    assert stored == ("FINISHED",)
