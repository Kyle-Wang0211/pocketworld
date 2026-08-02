from __future__ import annotations

import itertools
import json
from pathlib import Path


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
RESULT_PATH = EXPERIMENT_ROOT / "results" / "webgraph-minimum.json"


def test_webgraph_minimum_result_covers_the_frozen_complete_grid() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["schema"] == "pw_webgraph_complete_grid_minimum_result_v1"
    assert result["official_revision"] == (
        "f8698a7bdda2c4e171017548307179cd5c7a3166"
    )
    assert result["source_tree_clean"] is True
    expected = set(
        itertools.product(
            (3, 7),
            (3, 7),
            (2, 4),
            ("gamma", "zeta3"),
        )
    )
    arms = result["arms"]
    actual = {
        (
            arm["compression_window"],
            arm["max_ref_count"],
            arm["min_interval_length"],
            arm["code"],
        )
        for arm in arms
    }
    assert actual == expected
    assert len(arms) == 16
    for arm in arms:
        assert arm["byte_equal"] == 1
        assert arm["sha256_equal"] == 1
        assert arm["random_reads_exact"] == 1
        assert arm["graph_bytes"] > 0
        assert arm["properties_bytes"] > 0
        assert arm["elias_fano_bytes"] > 0
        assert arm["mapping_zpaq_bytes"] > 0
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
    assert result["best_webgraph_bytes"] > result["zpaq_baseline_bytes"]
    assert result["strict_minimum_winner_modes"] == []
    assert result["expand_to_complete"] is False
    assert len({arm["mapping_raw_sha256"] for arm in arms}) == 1
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
