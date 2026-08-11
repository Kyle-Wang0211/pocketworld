from __future__ import annotations

import itertools
import json
from pathlib import Path


RESULTS = Path(__file__).resolve().parents[1] / "results"


def _assert_direct_grid(result: dict[str, object]) -> None:
    expected = set(
        itertools.product((3, 7), (3, 7), (2, 4), ("gamma", "zeta3"))
    )
    arms = result["arms"]
    assert len(arms) == 16
    assert {
        (
            arm["compression_window"],
            arm["max_ref_count"],
            arm["min_interval_length"],
            arm["code"],
        )
        for arm in arms
    } == expected
    for arm in arms:
        assert arm["representation"] == "direct_unique_edges_v1"
        assert arm["record_nodes"] == 0
        assert arm["duplicate_records"] > 0
        assert arm["byte_equal"] == 1
        assert arm["sha256_equal"] == 1
        assert arm["random_reads_exact"] == 1
        assert arm["complete_persisted_bytes"] == sum(
            arm[key]
            for key in (
                "graph_bytes",
                "properties_bytes",
                "elias_fano_bytes",
                "mapping_zpaq_bytes",
            )
        )


def test_direct_edge_minimum_is_a_strict_structural_improvement() -> None:
    result = json.loads((RESULTS / "webgraph-direct-minimum.json").read_text())
    record = json.loads((RESULTS / "webgraph-minimum.json").read_text())
    assert result["schema"] == "pw_webgraph_direct_minimum_result_v1"
    _assert_direct_grid(result)
    assert result["best_direct_bytes"] < record["best_webgraph_bytes"]
    assert result["expand_to_complete"] is True
    assert result["zpaq_baseline_bytes"] == record["zpaq_baseline_bytes"]


def test_direct_edge_complete_preserves_all_records_and_beats_old_structure() -> None:
    result = json.loads((RESULTS / "webgraph-direct-complete.json").read_text())
    record = json.loads(
        (RESULTS / "webgraph-complete-scale-audit.json").read_text()
    )
    assert result["schema"] == "pw_webgraph_direct_complete_result_v1"
    assert result["records"] == 857_844
    assert result["canonical_input_bytes"] == 27_451_060
    _assert_direct_grid(result)
    assert result["best_direct_bytes"] < record["best_webgraph_bytes"]
    assert result["zpaq_baseline_bytes"] == record["zpaq_baseline_bytes"]
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False

