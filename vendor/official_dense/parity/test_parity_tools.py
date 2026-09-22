#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import math
import struct
import tempfile
import unittest

from compare_colmap_maps import (
    compare_float_matrix_files,
    inspect_float_matrix_range,
)
from compare_colmap_workspaces import (
    compare_colmap_workspaces,
    read_frozen_scene_manifest,
    read_frozen_scene_image_names,
)
from inspect_colmap_workspace import inspect_colmap_workspace
from probe_plan_budget import calculate_probe_plan_budget
from compare_runs import compare
from contract import (
    ARTIFACT_CONTRACT_PATH,
    ContractError,
    sha256_file,
    validate_run_structure,
    write_json_atomic,
)
from measure_noise_floor import measure


class ParityToolsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="pw_cuda_parity_test_")
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _write_run(self, name: str, offset: float = 0.0) -> pathlib.Path:
        run = self.root / name
        run.mkdir()
        reference = "frame_000001.jpg"
        artifacts = []

        def add(
            kind: str,
            suffix: str,
            *,
            iteration: int | None = None,
            sweep: int | None = None,
            global_artifact: bool = False,
        ) -> None:
            path = run / "artifacts" / f"{suffix}.bin"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(struct.pack("<f", offset))
            artifacts.append(
                {
                    "kind": kind,
                    "reference_id": None if global_artifact else reference,
                    "iteration": iteration,
                    "sweep": sweep,
                    "path": str(path.relative_to(run)),
                    "dtype": "float32",
                    "shape": [1],
                    "size_bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )

        add("ref_filter", "ref_filter")
        add("initial_cost", "initial_cost")
        add("final_consistency_graph", "graph")
        for iteration in range(5):
            for sweep in range(4):
                for kind in (
                    "sweep_depth",
                    "sweep_normal",
                    "sweep_cost",
                    "sweep_sel",
                    "sweep_mask",
                ):
                    add(
                        kind,
                        f"{kind}_{iteration}_{sweep}",
                        iteration=iteration,
                        sweep=sweep,
                    )
        add("fused_ply", "fused", global_artifact=True)
        write_json_atomic(
            run / "artifact_manifest.json",
            {
                "schema_version": 1,
                "reference_ids": [reference],
                "default_num_iterations": 5,
                "sweeps_per_iteration": 4,
                "artifacts": artifacts,
            },
        )
        write_json_atomic(
            run / "run_manifest.json",
            {
                "schema_version": 1,
                "artifact_contract_sha256": sha256_file(ARTIFACT_CONTRACT_PATH),
                "input_manifest_sha256": "1" * 64,
                "baseline_identity_sha256": "2" * 64,
            },
        )
        return run

    def _write_colmap_matrix(
        self,
        name: str,
        values: list[float],
        *,
        width: int = 2,
        height: int = 1,
        depth: int = 1,
    ) -> pathlib.Path:
        path = self.root / name
        path.write_bytes(
            f"{width}&{height}&{depth}&".encode("ascii")
            + struct.pack(f"<{len(values)}f", *values)
        )
        return path

    def _write_consistency_graph(
        self, path: pathlib.Path, values: list[int]
    ) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            b"2&1&1&" + struct.pack(f"<{len(values)}i", *values)
        )

    def _write_workspace(
        self, name: str, image_name: str, *, depth_offset: float = 0.0
    ) -> pathlib.Path:
        root = self.root / name / "stereo"
        for output_type in ("photometric", "geometric"):
            suffix = f"{image_name}.{output_type}.bin"
            for directory, depth in (("depth_maps", 1), ("normal_maps", 3)):
                path = root / directory / suffix
                path.parent.mkdir(parents=True, exist_ok=True)
                value_count = 2 * depth
                values = [float(index) + depth_offset for index in range(value_count)]
                path.write_bytes(
                    f"2&1&{depth}&".encode("ascii")
                    + struct.pack(f"<{value_count}f", *values)
                )
        self._write_consistency_graph(
            root / "consistency_graphs" / f"{image_name}.geometric.bin",
            [0, 0, 1, 7],
        )
        return root.parent

    def _write_scene_packet(self, image_names: list[str]) -> pathlib.Path:
        path = self.root / "scene.packet"
        payload = bytearray(b"PWSCENE1")
        payload.extend(struct.pack("<II", 1, len(image_names)))
        for index, image_name in enumerate(image_names):
            encoded = image_name.encode("utf-8")
            source = (index + 1) % len(image_names)
            payload.extend(struct.pack("<IIIII", index, 2, 1, len(encoded), 1))
            payload.extend(encoded)
            payload.extend(struct.pack("<21f", *([0.0] * 21)))
            payload.extend(struct.pack("<2f", 0.1, 10.0))
            payload.extend(struct.pack("<i", source))
        path.write_bytes(payload)
        return path

    def test_colmap_matrix_comparator_reports_bitwise_identity(self) -> None:
        first = self._write_colmap_matrix("first.bin", [1.0, 2.0])
        second = self._write_colmap_matrix("second.bin", [1.0, 2.0])

        result = compare_float_matrix_files(first, second)

        self.assertTrue(result["bitwise_identical"])
        self.assertEqual(result["shape"], [2, 1, 1])
        self.assertEqual(result["mismatched_values"], 0)
        self.assertEqual(result["max_abs"], 0.0)
        self.assertEqual(result["rms"], 0.0)
        self.assertEqual(result["reference_sha256"], result["candidate_sha256"])

    def test_colmap_matrix_comparator_measures_float_delta(self) -> None:
        first = self._write_colmap_matrix("first.bin", [1.0, 2.0])
        second = self._write_colmap_matrix("second.bin", [1.25, 1.5])

        result = compare_float_matrix_files(first, second)

        self.assertFalse(result["bitwise_identical"])
        self.assertEqual(result["mismatched_values"], 2)
        self.assertEqual(result["max_abs"], 0.5)
        self.assertAlmostEqual(result["rms"], (0.15625) ** 0.5)

    def test_colmap_matrix_comparator_rejects_shape_mismatch(self) -> None:
        first = self._write_colmap_matrix("first.bin", [1.0, 2.0])
        second = self._write_colmap_matrix(
            "second.bin", [1.0, 2.0], width=1, height=2
        )

        with self.assertRaises(ContractError):
            compare_float_matrix_files(first, second)

    def test_colmap_matrix_comparator_marks_nonfinite_delta(self) -> None:
        first = self._write_colmap_matrix("first.bin", [1.0, 2.0])
        second = self._write_colmap_matrix("second.bin", [math.nan, 2.0])

        result = compare_float_matrix_files(first, second)

        self.assertEqual(result["nonfinite_mismatches"], 1)
        self.assertIsNone(result["max_abs"])
        self.assertIsNone(result["rms"])

    def test_colmap_depth_range_inspector_counts_escaped_depths(self) -> None:
        depth = self._write_colmap_matrix(
            "depth.bin", [0.0, 0.5, 1.0, 2.0, math.nan], width=5
        )
        result = inspect_float_matrix_range(depth, 0.5, 1.0)

        self.assertEqual(
            result,
            {
                "shape": [5, 1, 1],
                "value_count": 5,
                "finite_count": 4,
                "nonfinite_count": 1,
                "within_range_count": 2,
                "below_min_count": 1,
                "positive_below_min_count": 0,
                "above_max_count": 1,
                "zero_or_negative_count": 1,
                "min_finite": 0.0,
                "max_finite": 2.0,
            },
        )

    def test_frozen_scene_packet_supplies_ordered_workspace_identities(self) -> None:
        packet = self._write_scene_packet(["a.jpg", "b.jpg"])

        self.assertEqual(
            read_frozen_scene_image_names(packet), ["a.jpg", "b.jpg"]
        )
        self.assertEqual(
            read_frozen_scene_manifest(packet),
            [
                {
                    "index": 0,
                    "name": "a.jpg",
                    "width": 2,
                    "height": 1,
                    "depth_range": [0.10000000149011612, 10.0],
                    "source_indices": [1],
                },
                {
                    "index": 1,
                    "name": "b.jpg",
                    "width": 2,
                    "height": 1,
                    "depth_range": [0.10000000149011612, 10.0],
                    "source_indices": [0],
                },
            ],
        )

    def test_probe_plan_budget_counts_full_frozen_scene_without_guessing(self) -> None:
        images = [
            {
                "index": index,
                "name": f"frame_{index:06d}.jpg",
                "width": 768,
                "height": 576,
                "source_indices": [0] * 10,
            }
            for index in range(132)
        ]

        result = calculate_probe_plan_budget(images)

        self.assertEqual(result["image_count"], 132)
        self.assertEqual(result["queue_submits_per_split_phase"], 309)
        self.assertEqual(result["full_scene_queue_submits"], 81576)
        self.assertEqual(result["float_map_payload_bytes"], 1868562432)
        self.assertEqual(result["consistency_graph_bytes"], "excluded_variable")

    def test_workspace_comparator_checks_every_official_output(self) -> None:
        reference = self._write_workspace("reference", "a.jpg")
        candidate = self._write_workspace("candidate", "a.jpg")

        result = compare_colmap_workspaces(reference, candidate, ["a.jpg"])

        self.assertEqual(result["image_count"], 1)
        self.assertEqual(result["float_map_count"], 4)
        self.assertEqual(result["consistency_graph_count"], 1)
        self.assertTrue(result["bitwise_identical"])

    def test_workspace_comparator_reports_map_and_graph_deltas(self) -> None:
        reference = self._write_workspace("reference", "a.jpg")
        candidate = self._write_workspace(
            "candidate", "a.jpg", depth_offset=0.25
        )
        self._write_consistency_graph(
            candidate
            / "stereo"
            / "consistency_graphs"
            / "a.jpg.geometric.bin",
            [0, 0, 1, 8],
        )

        result = compare_colmap_workspaces(reference, candidate, ["a.jpg"])

        self.assertFalse(result["bitwise_identical"])
        self.assertGreater(result["mismatched_float_values"], 0)
        self.assertEqual(result["max_abs"], 0.25)
        self.assertEqual(result["rms"], 0.25)
        self.assertEqual(result["float_mismatch_fraction"], 1.0)
        self.assertEqual(result["mismatched_consistency_values"], 1)
        self.assertEqual(result["consistency_mismatch_fraction"], 0.25)

    def test_workspace_comparator_fails_closed_on_missing_output(self) -> None:
        reference = self._write_workspace("reference", "a.jpg")
        candidate = self._write_workspace("candidate", "a.jpg")
        (
            candidate
            / "stereo"
            / "normal_maps"
            / "a.jpg.geometric.bin"
        ).unlink()

        with self.assertRaises(ContractError):
            compare_colmap_workspaces(reference, candidate, ["a.jpg"])

    def test_workspace_comparator_accepts_two_empty_consistency_graphs(self) -> None:
        reference = self._write_workspace("reference", "a.jpg")
        candidate = self._write_workspace("candidate", "a.jpg")
        for workspace in (reference, candidate):
            self._write_consistency_graph(
                workspace
                / "stereo"
                / "consistency_graphs"
                / "a.jpg.geometric.bin",
                [],
            )

        result = compare_colmap_workspaces(reference, candidate, ["a.jpg"])

        self.assertEqual(result["consistency_value_count"], 0)
        self.assertEqual(result["consistency_mismatch_fraction"], 0.0)

    def test_workspace_inspector_reports_resumable_phase_progress(self) -> None:
        workspace = self._write_workspace("workspace", "a.jpg")

        result = inspect_colmap_workspace(workspace, ["a.jpg", "b.jpg"])

        self.assertEqual(result["image_count"], 2)
        self.assertEqual(result["photometric_complete"], 1)
        self.assertEqual(result["geometric_complete"], 1)
        self.assertEqual(result["next_photometric_image"], "b.jpg")
        self.assertEqual(result["next_geometric_image"], "b.jpg")
        self.assertEqual(result["corrupt_outputs"], [])

    def test_workspace_inspector_does_not_count_corrupt_atomic_output(self) -> None:
        workspace = self._write_workspace("workspace", "a.jpg")
        corrupt = workspace / "stereo" / "depth_maps" / "a.jpg.photometric.bin"
        corrupt.write_bytes(b"truncated")

        result = inspect_colmap_workspace(workspace, ["a.jpg"])

        self.assertEqual(result["photometric_complete"], 0)
        self.assertEqual(result["geometric_complete"], 1)
        self.assertEqual(len(result["corrupt_outputs"]), 1)

    def test_repeated_baseline_drives_candidate_limits(self) -> None:
        first = self._write_run("first")
        second = self._write_run("second")
        candidate = self._write_run("candidate")
        noise_floor_path = self.root / "noise_floor.json"
        write_json_atomic(noise_floor_path, measure([first, second]))

        result = compare(first, candidate, noise_floor_path)

        self.assertEqual(result["verdict"], "pass")

    def test_missing_sweep_artifact_is_rejected(self) -> None:
        run = self._write_run("incomplete")
        manifest_path = run / "artifact_manifest.json"
        import json

        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["artifacts"] = [
            entry
            for entry in manifest["artifacts"]
            if not (
                entry["kind"] == "sweep_mask"
                and entry["iteration"] == 4
                and entry["sweep"] == 3
            )
        ]
        write_json_atomic(manifest_path, manifest)

        with self.assertRaises(ContractError):
            validate_run_structure(run)


if __name__ == "__main__":
    unittest.main()
