from __future__ import annotations

import itertools
import json
from pathlib import Path


RESULTS = Path(__file__).resolve().parents[1] / "results"


def _result(name: str) -> dict[str, object]:
    return json.loads((RESULTS / name).read_text())


def _assert_exact(result: dict[str, object]) -> None:
    assert result["official_revision"] == (
        "f8698a7bdda2c4e171017548307179cd5c7a3166"
    )
    assert result["pipeline"] == [
        "build_offsets",
        "build_elias_fano",
        "bfs_permutation",
        "symmetrize_no_loops_with_bfs",
        "rebuild_offsets_and_compare",
        "build_elias_fano",
        "build_degree_cumulative_function",
        "layered_label_propagation_seed_0",
        "compose_bfs_and_llp",
        "apply_composed_permutation_to_original_directed_graph",
        "rebuild_offsets_and_compare",
        "build_elias_fano",
    ]
    assert result["byte_equal"] == 1
    assert result["sha256_equal"] == 1
    assert result["random_reads_exact"] == 1
    assert result["graph_correspondence_exact"] == 1
    assert result["offsets_rebuild_equal"] == 1
    assert result["mapping_archive_roundtrip_exact"] == 1
    assert result["permutation_archive_roundtrip_exact"] == 1
    assert result["production_promoted"] is False
    assert result["phone_benchmark_run"] is False


def test_llp_minimum_records_fixed_overhead_loss_before_scale_audit() -> None:
    result = _result("webgraph-llp-minimum.json")
    _assert_exact(result)
    assert result["schema"] == "pw_webgraph_llp_minimum_result_v1"
    assert result["records"] == 3_092
    assert result["canonical_input_bytes"] == 98_996
    assert result["complete_persisted_bytes"] == 9_178
    assert result["zpaq_baseline_bytes"] == 6_542
    assert result["minimum_gate_passed"] is False
    assert result["complete_scale_audit_deviation"] == (
        "user_requested_official_pipeline_completion_after_fixed_overhead_warning"
    )


def test_llp_complete_is_exact_and_strictly_beats_same_input_zpaq() -> None:
    result = _result("webgraph-llp-complete.json")
    _assert_exact(result)
    assert result["schema"] == "pw_webgraph_llp_complete_result_v1"
    assert result["records"] == 857_844
    assert result["duplicate_records"] == 386_890
    assert result["canonical_input_bytes"] == 27_451_060
    assert result["canonical_input_sha256"] == (
        "1bf49e01aae0c1844d934a9a91f3e2a83826fb39d9be09d8561f64e59e492acf"
    )
    expected_grid = set(
        itertools.product(
            (False, True), (3, 7), (3, 7), (2, 4), ("gamma", "zeta3")
        )
    )
    assert len(result["arms"]) == 32
    assert {
        (
            arm["bvgraphz"],
            arm["compression_window"],
            arm["max_ref_count"],
            arm["min_interval_length"],
            arm["code"],
        )
        for arm in result["arms"]
    } == expected_grid
    assert result["winner_mode"] == "bvz-w7-r7-i4-gamma"
    assert result["graph_family_bytes"] == 603_709
    assert result["mapping_zpaq_bytes"] == 518_849
    assert result["permutation_java_zpaq_bytes"] == 573_946
    assert result["complete_persisted_bytes"] == 1_696_504
    assert result["complete_persisted_bytes"] == sum(
        result[key]
        for key in (
            "graph_bytes",
            "properties_bytes",
            "elias_fano_bytes",
            "mapping_zpaq_bytes",
            "permutation_java_zpaq_bytes",
        )
    )
    assert result["direct_unique_edges_baseline_bytes"] == 2_315_779
    assert result["zpaq_baseline_bytes"] == 2_030_945
    assert result["complete_persisted_bytes"] < result["zpaq_baseline_bytes"]
    assert result["vs_zpaq_reduction_fraction"] > 0.16
    assert result["family_global_optimum_claimed"] is False

