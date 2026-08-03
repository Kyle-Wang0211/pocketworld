import json
import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESULT = ROOT / "results/minimum.json"
ARCHIVE = ROOT / "results/minimum.pwjg"


def test_result_is_exact_complete_and_does_not_execute_baseline():
    result = json.loads(RESULT.read_text())
    assert result["baseline_execution"] == "reference_only"
    assert result["source_jpeg_count"] == 2
    assert result["jpeg_byte_equal"] is True
    assert result["jpeg_sha256_equal"] is True
    assert result["semantic_bits_and_order_equal"] is True
    assert result["corruption_rejected"] is True
    assert result["candidate_complete_bytes"] > 0
    assert result["incumbent_complete_bytes"] == 4_664_520
    assert result["winner"] in {"incumbent", "joint_semantic_v2"}
    assert result["candidate_run_count"] == 1
    assert result["faithful_2016_reproduction_claimed"] is False


def test_persisted_candidate_identity_and_stop_decision_are_exact():
    result = json.loads(RESULT.read_text())
    assert ARCHIVE.stat().st_size == result["candidate_complete_bytes"]
    assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == result[
        "candidate_archive_sha256"
    ]
    assert result["winner"] == "incumbent"
    assert result["candidate_reduction_vs_incumbent_fraction"] < 0
