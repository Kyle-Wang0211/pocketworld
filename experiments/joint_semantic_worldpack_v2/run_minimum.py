from __future__ import annotations

import argparse
import hashlib
import json
import os
import resource
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import mlflow
import numpy as np
import yaml

from jpeg_collection_model import (
    EncodedChild,
    decode_child_frame,
    encode_child_frames,
    fit_homography_q32,
)
from jpeg_exact import (
    build_coefficient_tool,
    extract_exact_jpeg,
    restore_exact_jpeg,
)
from joint_group import (
    JointGroupBuilder,
    JointGroupCorruption,
    JointGroupReader,
    corrupt_registered_field,
)
from semantic_slice import SemanticSlice, extract_minimum_slice


HERE = Path(__file__).resolve().parent
REPOSITORY = HERE.parents[1]
ZPAQ_CODEC = "zpaq_7_15_method5"
ZPAQ_REVISION = "e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418"


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def verify_frozen_input(contract_path: Path) -> tuple[dict[str, Any], dict[str, Any], SemanticSlice]:
    contract = yaml.safe_load(contract_path.read_text())
    manifest_path = contract_path.parent / contract["input"]["manifest"]
    manifest = yaml.safe_load(manifest_path.read_text())
    capture_root = Path(manifest["capture"]["root"])
    for entry in manifest["context_files"]:
        source = capture_root / entry["path"]
        if source.stat().st_size != entry["bytes"] or _sha256_file(source) != entry["sha256"]:
            raise RuntimeError(f"frozen context identity changed: {entry['path']}")
    value = extract_minimum_slice(capture_root)
    if [value.root.capture_ordinal, value.child.capture_ordinal] != contract["input"][
        "selected_capture_ordinals"
    ]:
        raise RuntimeError("deterministic pair selection changed")
    if value.root.incumbent_bytes + value.child.incumbent_bytes != contract["baseline"][
        "incumbent_two_photo_payload_bytes"
    ]:
        raise RuntimeError("saved two-photo incumbent accounting changed")
    return contract, manifest, value


def _build_zpaq_tool(output: Path) -> Path:
    source = REPOSITORY / "tool/zpaq_file_tool.cpp"
    include = REPOSITORY / "ios/Vendor/Zpaq/include"
    library = REPOSITORY / "ios/Vendor/Zpaq/src/libzpaq.cpp"
    output.parent.mkdir(parents=True, exist_ok=True)
    source_object = output.parent / "zpaq_file_tool.o"
    library_object = output.parent / "libzpaq.o"
    compile_common = ["-std=c++17", "-O2", "-Dunix", "-DNOJIT", f"-I{include}"]
    subprocess.run(
        [
            "xcrun",
            "clang++",
            "-std=c++17",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-parameter",
            "-Wno-null-pointer-subtraction",
            "-Dunix",
            "-DNOJIT",
            f"-I{include}",
            "-c",
            str(source),
            "-o",
            str(source_object),
        ],
        check=True,
    )
    subprocess.run(
        [
            "xcrun",
            "clang++",
            *compile_common,
            "-c",
            str(library),
            "-o",
            str(library_object),
        ],
        check=True,
    )
    subprocess.run(
        [
            "xcrun",
            "clang++",
            str(source_object),
            str(library_object),
            "-framework",
            "Security",
            "-o",
            str(output),
        ],
        check=True,
    )
    version = subprocess.run(
        [str(output), "version"], check=True, capture_output=True, text=True
    ).stdout.strip()
    if version != f"7.15 {ZPAQ_REVISION}":
        raise RuntimeError(f"unexpected ZPAQ identity: {version}")
    return output


def _zpaq_transform(tool: Path, command: str, payload: bytes) -> bytes:
    with tempfile.TemporaryDirectory(prefix="pw-joint-zpaq-", dir="/private/tmp") as text:
        scratch = Path(text)
        source = scratch / "input.bin"
        output = scratch / "output.bin"
        source.write_bytes(payload)
        subprocess.run([str(tool), command, str(source), str(output)], check=True)
        return output.read_bytes()


def _encoded_streams(encoded: EncodedChild) -> tuple[bytes, bytes]:
    graph = _canonical_json(
        {
            "schema": "pw_prediction_graph_v1",
            "parent_ordinal": encoded.parent_ordinal,
            "child_ordinal": encoded.child_ordinal,
            "child_to_root_homography_q32": encoded.child_to_root_homography_q32,
            "homography_inlier_count": encoded.homography_inlier_count,
            "root_component_shapes": encoded.root_component_shapes,
            "child_component_shapes": encoded.child_component_shapes,
        }
    )
    metadata = _canonical_json(
        {
            "schema": "pw_exact_jpeg_side_information_v1",
            "child_restart_interval": encoded.child_restart_interval,
            "child_source_bytes": encoded.child_source_bytes,
            "child_source_sha256": encoded.child_source_sha256,
            "jpeg_tool_sha256": encoded.jpeg_tool_sha256,
            "expected_frame_sha256": encoded.expected_frame_sha256,
        }
    )
    side = struct.pack("<Q", len(metadata)) + metadata + encoded.child_header
    return graph, side


def _rebuild_encoded_child(reader: JointGroupReader) -> EncodedChild:
    graph = json.loads(reader.read_member(1))
    compensation = reader.read_member(2)
    frequency = reader.read_member(3)
    residual = reader.read_member(4)
    side = reader.read_member(5)
    if len(side) < 8:
        raise RuntimeError("JPEG side information is truncated")
    (metadata_bytes,) = struct.unpack_from("<Q", side)
    metadata_end = 8 + metadata_bytes
    metadata = json.loads(side[8:metadata_end])
    return EncodedChild(
        parent_ordinal=int(graph["parent_ordinal"]),
        child_ordinal=int(graph["child_ordinal"]),
        child_to_root_homography_q32=tuple(
            int(value) for value in graph["child_to_root_homography_q32"]
        ),
        homography_inlier_count=int(graph["homography_inlier_count"]),
        root_component_shapes=tuple(
            tuple(int(value) for value in shape)
            for shape in graph["root_component_shapes"]
        ),
        child_component_shapes=tuple(
            tuple(int(value) for value in shape)
            for shape in graph["child_component_shapes"]
        ),
        local_block_selectors=compensation,
        frequency_selectors=frequency,
        residual_int32_le=residual,
        child_restart_interval=int(metadata["child_restart_interval"]),
        child_header=side[metadata_end:],
        child_source_bytes=int(metadata["child_source_bytes"]),
        child_source_sha256=str(metadata["child_source_sha256"]),
        jpeg_tool_sha256=str(metadata["jpeg_tool_sha256"]),
        expected_frame_sha256=str(metadata["expected_frame_sha256"]),
    )


def _verified_correspondences(value: SemanticSlice) -> tuple[np.ndarray, np.ndarray]:
    keypoints = []
    for blob, (rows, cols) in zip(
        value.keypoint_blobs, value.keypoint_shape, strict=True
    ):
        keypoints.append(np.frombuffer(blob, dtype="<f4").reshape(rows, cols)[:, :2])
    pairs = np.frombuffer(value.verified_match_blob, dtype="<u4").reshape(
        value.verified_match_count, 2
    )
    if (
        (pairs[:, 0] >= len(keypoints[0])).any()
        or (pairs[:, 1] >= len(keypoints[1])).any()
    ):
        raise RuntimeError("verified correspondence index is out of range")
    root_points = keypoints[0][pairs[:, 0]].astype(np.float64)
    child_points = keypoints[1][pairs[:, 1]].astype(np.float64)
    return child_points, root_points


def _add_compressed_member(
    builder: JointGroupBuilder,
    *,
    kind: str,
    original: bytes,
    dependencies: tuple[int, ...],
    zpaq_tool: Path,
) -> tuple[int, dict[str, Any]]:
    started = time.monotonic()
    compressed = _zpaq_transform(zpaq_tool, "compress", original)
    elapsed = time.monotonic() - started
    if len(compressed) < len(original):
        index = builder.add_member(
            kind,
            original,
            dependencies=dependencies,
            codec=ZPAQ_CODEC,
            encoded_payload=compressed,
        )
        codec = ZPAQ_CODEC
        persisted = len(compressed)
    else:
        index = builder.add_member(kind, original, dependencies=dependencies)
        codec = "raw"
        persisted = len(original)
    return index, {
        "kind": kind,
        "codec": codec,
        "original_bytes": len(original),
        "persisted_payload_bytes": persisted,
        "zpaq_candidate_bytes": len(compressed),
        "compression_elapsed_seconds": elapsed,
    }


def _write_atomic(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_bytes(payload)
    os.replace(temporary, path)


def run_candidate(contract_path: Path, output: Path) -> dict[str, Any]:
    archive_path = output.with_suffix(".pwjg")
    if output.exists() or archive_path.exists():
        raise RuntimeError("registered result already exists; automatic rerun is forbidden")
    contract, manifest, value = verify_frozen_input(contract_path)
    input_identity_before = value.identity_sha256
    started = time.monotonic()
    stage_times: dict[str, float] = {}

    tracking_database = HERE / "mlflow.db"
    mlflow.set_tracking_uri(f"sqlite:///{tracking_database}")
    experiment = mlflow.set_experiment("joint-semantic-worldpack-v2")
    with mlflow.start_run(experiment_id=experiment.experiment_id, run_name="minimum-once") as active_run:
        with tempfile.TemporaryDirectory(prefix="pw-joint-minimum-", dir="/private/tmp") as text:
            scratch = Path(text)
            tools_started = time.monotonic()
            jpeg_tool = build_coefficient_tool(
                REPOSITORY
                / "experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp",
                scratch / "jpeg_coeff_tool",
            )
            zpaq_tool = _build_zpaq_tool(scratch / "zpaq_file_tool")
            stage_times["tool_build"] = time.monotonic() - tools_started

            exact_started = time.monotonic()
            source_paths = value.restore_original_jpegs(scratch / "sources")
            root_frame = extract_exact_jpeg(source_paths[0], jpeg_tool)
            child_frame = extract_exact_jpeg(source_paths[1], jpeg_tool)
            stage_times["exact_extract"] = time.monotonic() - exact_started

            fit_started = time.monotonic()
            child_points, root_points = _verified_correspondences(value)
            homography_q32, homography_inliers = fit_homography_q32(
                child_points, root_points
            )
            stage_times["homography_fit"] = time.monotonic() - fit_started

            prediction_started = time.monotonic()
            encoded = encode_child_frames(
                parent_ordinal=value.root.capture_ordinal,
                child_ordinal=value.child.capture_ordinal,
                root=root_frame,
                child=child_frame,
                child_to_root_homography_q32=homography_q32,
                homography_inlier_count=homography_inliers,
            )
            decoded_frame = decode_child_frame(root_frame, encoded)
            if decoded_frame.serialized != child_frame.serialized:
                raise RuntimeError("exact child coefficient frame mismatch")
            decoded_child_jpeg = restore_exact_jpeg(decoded_frame, jpeg_tool)
            if decoded_child_jpeg != source_paths[1].read_bytes():
                raise RuntimeError("exact child JPEG mismatch before framing")
            stage_times["prediction"] = time.monotonic() - prediction_started

            graph, side = _encoded_streams(encoded)
            builder = JointGroupBuilder()
            member_stats = []
            root_jxl = value.root.incumbent_path.read_bytes()
            root_index = builder.add_member("root_jpeg", root_jxl, dependencies=())
            member_stats.append(
                {
                    "kind": "root_jpeg",
                    "codec": "raw",
                    "original_bytes": len(root_jxl),
                    "persisted_payload_bytes": len(root_jxl),
                    "zpaq_candidate_bytes": None,
                    "compression_elapsed_seconds": 0.0,
                }
            )
            graph_index, stats = _add_compressed_member(
                builder,
                kind="prediction_graph",
                original=graph,
                dependencies=(root_index,),
                zpaq_tool=zpaq_tool,
            )
            member_stats.append(stats)
            compensation_index, stats = _add_compressed_member(
                builder,
                kind="compensation_state",
                original=encoded.local_block_selectors,
                dependencies=(graph_index,),
                zpaq_tool=zpaq_tool,
            )
            member_stats.append(stats)
            frequency_index, stats = _add_compressed_member(
                builder,
                kind="frequency_selectors",
                original=encoded.frequency_selectors,
                dependencies=(graph_index,),
                zpaq_tool=zpaq_tool,
            )
            member_stats.append(stats)
            residual_index, stats = _add_compressed_member(
                builder,
                kind="coefficient_residuals",
                original=encoded.residual_int32_le,
                dependencies=(graph_index, compensation_index, frequency_index),
                zpaq_tool=zpaq_tool,
            )
            member_stats.append(stats)
            side_index, stats = _add_compressed_member(
                builder,
                kind="jpeg_side_information",
                original=side,
                dependencies=(graph_index,),
                zpaq_tool=zpaq_tool,
            )
            member_stats.append(stats)
            group = builder.build()
            stage_times["prediction_and_entropy"] = time.monotonic() - prediction_started

            def zpaq_decoder(payload: bytes) -> bytes:
                return _zpaq_transform(zpaq_tool, "decompress", payload)

            reader = JointGroupReader(group.data, decoders={ZPAQ_CODEC: zpaq_decoder})
            if reader.read_member(root_index) != root_jxl:
                raise RuntimeError("root JXL member mismatch")
            rebuilt = _rebuild_encoded_child(reader)
            if residual_index != 4 or side_index != 5:
                raise RuntimeError("registered member layout changed")

            group_root_jxl = scratch / "group-root.jpg.jxl"
            group_root_jpeg = scratch / "group-root.jpg"
            group_root_jxl.write_bytes(reader.read_member(root_index))
            subprocess.run(
                ["djxl", str(group_root_jxl), str(group_root_jpeg), "--quiet"],
                check=True,
            )
            group_root_frame = extract_exact_jpeg(group_root_jpeg, jpeg_tool)
            if group_root_frame.serialized != root_frame.serialized:
                raise RuntimeError("group root coefficient frame mismatch")
            group_child_frame = decode_child_frame(group_root_frame, rebuilt)
            group_child_jpeg = restore_exact_jpeg(group_child_frame, jpeg_tool)
            jpeg_byte_equal = (
                group_root_jpeg.read_bytes() == source_paths[0].read_bytes()
                and group_child_jpeg == source_paths[1].read_bytes()
            )
            jpeg_sha_equal = (
                hashlib.sha256(group_root_jpeg.read_bytes()).hexdigest()
                == value.root.jpeg_sha256
                and hashlib.sha256(group_child_jpeg).hexdigest()
                == value.child.jpeg_sha256
            )
            if not jpeg_byte_equal or not jpeg_sha_equal:
                raise RuntimeError("group JPEG exactness gate failed")

            corruption_results = {}
            for field in ("payload", "index", "dependency", "hash"):
                try:
                    JointGroupReader(
                        corrupt_registered_field(group.data, field),
                        decoders={ZPAQ_CODEC: zpaq_decoder},
                    ).read_member(residual_index)
                except JointGroupCorruption:
                    corruption_results[field] = True
                else:
                    corruption_results[field] = False
            corruption_rejected = all(corruption_results.values())
            if not corruption_rejected:
                raise RuntimeError("registered corruption was not rejected")

            _, _, value_after = verify_frozen_input(contract_path)
            semantic_equal = value_after.identity_sha256 == input_identity_before
            if not semantic_equal:
                raise RuntimeError("semantic source identity changed during the run")

            candidate_bytes = group.complete_persisted_bytes
            incumbent_bytes = int(contract["baseline"]["incumbent_two_photo_payload_bytes"])
            result = {
                "schema": "pw_joint_semantic_worldpack_v2_minimum_result_v1",
                "implementation_identity": contract["implementation_identity"],
                "baseline_execution": "reference_only",
                "candidate_run_count": 1,
                "source_jpeg_count": 2,
                "source_jpeg_bytes": value.root.jpeg_bytes + value.child.jpeg_bytes,
                "source_jpeg_sha256": [value.root.jpeg_sha256, value.child.jpeg_sha256],
                "incumbent_complete_bytes": incumbent_bytes,
                "candidate_complete_bytes": candidate_bytes,
                "winner": (
                    "joint_semantic_v2" if candidate_bytes < incumbent_bytes else "incumbent"
                ),
                "candidate_reduction_vs_incumbent_fraction": 1.0
                - candidate_bytes / incumbent_bytes,
                "candidate_archive_sha256": hashlib.sha256(group.data).hexdigest(),
                "candidate_header_bytes": group.header_bytes,
                "candidate_index_bytes": group.index_bytes,
                "candidate_footer_bytes": group.footer_bytes,
                "members": member_stats,
                "jpeg_byte_equal": jpeg_byte_equal,
                "jpeg_sha256_equal": jpeg_sha_equal,
                "semantic_bits_and_order_equal": semantic_equal,
                "semantic_stream_accounting": "shared_verified_streams_cancel_from_both_photo_arms",
                "corruption_rejected": corruption_rejected,
                "corruption_results": corruption_results,
                "random_read_dependency_bounded": True,
                "source_unchanged": True,
                "selected_capture_ordinals": [
                    value.root.capture_ordinal,
                    value.child.capture_ordinal,
                ],
                "verified_match_count": value.verified_match_count,
                "shared_arkit_anchor_count": len(value.shared_anchor_ids),
                "homography_inlier_count": homography_inliers,
                "prediction_residual_count": encoded.residual_count,
                "faithful_2016_reproduction_claimed": False,
                "paper_31_percent_used_as_acceptance_target": False,
                "commercial_use_verdict": "independent_host_experiment_only_pending_production_audit",
                "input_manifest_sha256": hashlib.sha256(
                    (contract_path.parent / contract["input"]["manifest"]).read_bytes()
                ).hexdigest(),
                "semantic_slice_identity_sha256": input_identity_before,
                "repository_head_at_execution": subprocess.run(
                    ["git", "rev-parse", "HEAD"],
                    cwd=REPOSITORY,
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.strip(),
                "jpeg_coefficient_tool_sha256": hashlib.sha256(
                    jpeg_tool.read_bytes()
                ).hexdigest(),
                "zpaq_revision": ZPAQ_REVISION,
                "stage_elapsed_seconds": stage_times,
                "total_elapsed_seconds": time.monotonic() - started,
                "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                "mlflow_run_id": active_run.info.run_id,
                "phone_access": False,
                "production_changes": False,
            }

            mlflow.log_params(
                {
                    "implementation_identity": result["implementation_identity"],
                    "capture_id": manifest["capture"]["id"],
                    "candidate_run_count": 1,
                    "baseline_execution": "reference_only",
                    "zpaq_revision": ZPAQ_REVISION,
                }
            )
            mlflow.log_metrics(
                {
                    "candidate_complete_bytes": candidate_bytes,
                    "incumbent_complete_bytes": incumbent_bytes,
                    "reduction_vs_incumbent_fraction": result[
                        "candidate_reduction_vs_incumbent_fraction"
                    ],
                    "homography_inlier_count": homography_inliers,
                    "peak_rss_bytes": result["peak_rss_bytes"],
                }
            )
            mlflow.log_dict(result, "minimum.json")
            _write_atomic(archive_path, group.data)
            _write_atomic(output, json.dumps(result, indent=2, sort_keys=True).encode("utf-8") + b"\n")
    print("JOINT_MINIMUM_COMPLETE", flush=True)
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-input-only", action="store_true")
    arguments = parser.parse_args()
    if arguments.verify_input_only:
        _, _, value = verify_frozen_input(arguments.contract)
        print(f"JOINT_INPUT_VERIFIED {value.identity_sha256}")
        return
    if arguments.output is None:
        parser.error("--output is required unless --verify-input-only is used")
    run_candidate(arguments.contract, arguments.output)


if __name__ == "__main__":
    main()

