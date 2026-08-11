from __future__ import annotations

import itertools
import json
from pathlib import Path


RESULT = (
    Path(__file__).resolve().parents[1]
    / "results"
    / "webgraph-complete-scale-audit.json"
)


def test_webgraph_complete_scale_audit_does_not_extrapolate_the_minimum() -> None:
    result = json.loads(RESULT.read_text())
    assert result["schema"] == "pw_webgraph_complete_scale_audit_v1"
    assert result["scope"] == "complete_matches_and_two_view_geometries"
    assert result["official_revision"] == (
        "f8698a7bdda2c4e171017548307179cd5c7a3166"
    )
    assert result["post_hoc_scale_audit"] is True
    assert result["registered_deviation"] == (
        "expanded_after_minimum_loss_to_test_fixed_overhead_extrapolation"
    )
    assert result["records"] == 857_844
    assert result["canonical_input_bytes"] == 27_451_060
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
        assert arm["byte_equal"] == 1
        assert arm["sha256_equal"] == 1
        assert arm["random_reads_exact"] == 1
        assert arm["offsets_persisted_bytes"] == 0
        assert arm["complete_persisted_bytes"] == sum(
            arm[key]
            for key in (
                "graph_bytes",
                "properties_bytes",
                "elias_fano_bytes",
                "mapping_zpaq_bytes",
            )
        )
    assert result["zpaq_baseline_bytes"] > 0
    assert result["best_webgraph_bytes"] == min(
        arm["complete_persisted_bytes"] for arm in arms
    )
    assert result["minimum_result_sha256"]
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False

