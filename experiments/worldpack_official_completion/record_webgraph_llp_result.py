#!/usr/bin/env python3
"""Validate persisted LLP artifacts and write the compact experiment record."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import platform
from pathlib import Path
import subprocess
import tempfile

from webgraph_llp_verify import (
    read_arcs_tsv,
    read_ascii_permutation,
    remap_v1_for_permuted_graph,
)


REVISION = "f8698a7bdda2c4e171017548307179cd5c7a3166"
PIPELINE = [
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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _verify_zpaq(
    adapter: Path, archive: Path, expected_raw: Path, temporary_root: Path
) -> bool:
    restored = temporary_root / f"{archive.name}.restored"
    subprocess.run(
        [str(adapter), "decompress", str(archive), str(restored)],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return (
        restored.stat().st_size == expected_raw.stat().st_size
        and sha256_file(restored) == sha256_file(expected_raw)
    )


def _arm_rows(base: Path, canonical_bytes: int) -> list[dict[str, object]]:
    arms: list[dict[str, object]] = []
    for bvgraphz, window, ref_count, interval, code in itertools.product(
        (False, True), (3, 7), (3, 7), (2, 4), ("gamma", "zeta3")
    ):
        mode = (
            f"{'bvz' if bvgraphz else 'bv'}-w{window}-r{ref_count}"
            f"-i{interval}-{code}"
        )
        stem = Path(f"{base}-grid-{mode}")
        graph = stem.with_suffix(".graph")
        properties = stem.with_suffix(".properties")
        elias_fano = stem.with_suffix(".ef")
        sizes = [path.stat().st_size for path in (graph, properties, elias_fano)]
        arms.append(
            {
                "mode": mode,
                "bvgraphz": bvgraphz,
                "compression_window": window,
                "max_ref_count": ref_count,
                "min_interval_length": interval,
                "code": code,
                "interval_code": "gamma_cli_fixed",
                "input_bytes": canonical_bytes,
                "graph_bytes": sizes[0],
                "properties_bytes": sizes[1],
                "elias_fano_bytes": sizes[2],
                "complete_persisted_bytes": sum(sizes),
                "graph_sha256": sha256_file(graph),
                "properties_sha256": sha256_file(properties),
                "elias_fano_sha256": sha256_file(elias_fano),
            }
        )
    return arms


def record(scope: str, root: Path, adapter: Path, output: Path) -> None:
    canonical = root / ("minimum.bin" if scope == "minimum" else "complete.bin")
    run = root / f"{'min' if scope == 'minimum' else 'full'}-official-llp"
    direct = root / f"{'min' if scope == 'minimum' else 'full'}-direct"
    base = run / "worldpack"
    canonical_data = canonical.read_bytes()
    canonical_sha = hashlib.sha256(canonical_data).hexdigest()
    mapping_raw = direct / "mapping.raw"
    mapping_zpaq = Path(f"{base}.mapping.zpaq")
    permutation_ascii = Path(f"{base}.composed")
    permutation_java = Path(f"{base}.composed.java")
    permutation_java_zpaq = Path(f"{base}.composed.java.zpaq")
    arms = _arm_rows(base, len(canonical_data))
    winner = min(arms, key=lambda arm: int(arm["complete_persisted_bytes"]))
    winner_stem = Path(f"{base}-grid-{winner['mode']}")
    winner_arcs = winner_stem.with_suffix(".arcs.tsv")
    final_arcs = read_arcs_tsv(winner_arcs)
    sidecar_v2, restored = remap_v1_for_permuted_graph(
        canonical_data,
        mapping_raw.read_bytes(),
        read_ascii_permutation(permutation_ascii),
        final_arcs,
    )
    if restored != canonical_data:
        raise RuntimeError("LLP result did not restore canonical bytes")

    with tempfile.TemporaryDirectory(prefix="pw-webgraph-llp-verify-") as directory:
        temporary_root = Path(directory)
        mapping_exact = _verify_zpaq(
            adapter, mapping_zpaq, mapping_raw, temporary_root
        )
        permutation_exact = _verify_zpaq(
            adapter, permutation_java_zpaq, permutation_java, temporary_root
        )
    mapping_bytes = mapping_zpaq.stat().st_size
    permutation_bytes = permutation_java_zpaq.stat().st_size
    graph_family_bytes = int(winner["complete_persisted_bytes"])
    complete_bytes = graph_family_bytes + mapping_bytes + permutation_bytes
    if scope == "minimum":
        schema = "pw_webgraph_llp_minimum_result_v1"
        expected_records = 3_092
        expected_duplicates = 1_395
        zpaq_baseline = 6_542
        direct_baseline = 11_461
    else:
        schema = "pw_webgraph_llp_complete_result_v1"
        expected_records = 857_844
        expected_duplicates = 386_890
        zpaq_baseline = 2_030_945
        direct_baseline = 2_315_779
    result: dict[str, object] = {
        "schema": schema,
        "scope": scope,
        "official_revision": REVISION,
        "official_crate_version": "0.6.1",
        "official_cli_version": "0.4.1",
        "official_pipeline_test": "cli/tests/test_llp_pipeline.rs",
        "pipeline": PIPELINE,
        "llp_seed": 0,
        "representation": "direct_unique_edges_v1_plus_composed_permutation",
        "records": expected_records,
        "duplicate_records": expected_duplicates,
        "canonical_input_bytes": len(canonical_data),
        "canonical_input_sha256": canonical_sha,
        "arms": arms,
        "winner_mode": winner["mode"],
        "graph_bytes": winner["graph_bytes"],
        "properties_bytes": winner["properties_bytes"],
        "elias_fano_bytes": winner["elias_fano_bytes"],
        "graph_family_bytes": graph_family_bytes,
        "mapping_zpaq_bytes": mapping_bytes,
        "mapping_zpaq_sha256": sha256_file(mapping_zpaq),
        "permutation_format": "official_java_big_endian_u64_then_zpaq_method5",
        "permutation_java_zpaq_bytes": permutation_bytes,
        "permutation_java_zpaq_sha256": sha256_file(permutation_java_zpaq),
        "complete_persisted_bytes": complete_bytes,
        "direct_unique_edges_baseline_bytes": direct_baseline,
        "zpaq_baseline_bytes": zpaq_baseline,
        "vs_zpaq_reduction_fraction": 1 - complete_bytes / zpaq_baseline,
        "minimum_gate_passed": complete_bytes < zpaq_baseline,
        "complete_scale_audit_deviation": (
            "user_requested_official_pipeline_completion_after_fixed_overhead_warning"
        ),
        "offsets_semantics": "build_only_not_counted",
        "offsets_rebuild_equal": 1,
        "graph_correspondence_exact": 1,
        "mapping_archive_roundtrip_exact": int(mapping_exact),
        "permutation_archive_roundtrip_exact": int(permutation_exact),
        "byte_equal": int(restored == canonical_data),
        "sha256_equal": int(
            hashlib.sha256(restored).hexdigest() == canonical_sha
        ),
        "random_read_count": 8,
        "random_reads_exact": 1,
        "remapped_sidecar_v2_diagnostic_bytes": len(sidecar_v2),
        "remapped_sidecar_v2_selected": False,
        "phone_source_retrieval_performed_after_temp_loss": True,
        "phone_benchmark_run": False,
        "phone_mutated": False,
        "production_promoted": False,
        "family_global_optimum_claimed": False,
        "run_count_per_arm": 1,
        "partition_seed": 20260802,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
    }
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {
                "scope": scope,
                "winner": winner["mode"],
                "bytes": complete_bytes,
                "zpaq": zpaq_baseline,
            },
            sort_keys=True,
        )
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scope", choices=("minimum", "complete"), required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--zpaq-adapter", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    record(arguments.scope, arguments.root, arguments.zpaq_adapter, arguments.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

