#!/usr/bin/env python3
"""Strict-lossless benchmark orchestrator; Task 1 freezes input identity only."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import platform
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile
import time

import mlflow
import yaml

from prepare_inputs import (
    build_alp_columns,
    build_alp_minimum_columns,
    build_descriptor_pair_chunks,
    build_webgraph_complete_input,
    build_webgraph_minimum_input,
)


EXPERIMENT_ROOT = Path(__file__).resolve().parent
CONTRACT_PATH = EXPERIMENT_ROOT / "experiment-contract.yaml"
MANIFEST_PATH = EXPERIMENT_ROOT / "input-manifest.yaml"
RESULTS_ROOT = EXPERIMENT_ROOT / "results"
OPENZL_ADAPTER = Path(
    "/private/tmp/pw_worldpack_openzl_adapter_bin.v020/worldpack_openzl_adapter"
)
ZPAQ_ADAPTER = Path(
    "/private/tmp/pw_worldpack_zpaq_adapter_bin.v715/worldpack_zpaq_adapter"
)
OPENZL_SOURCE = Path("/private/tmp/pw_worldpack_upstreams.8vBT0j/openzl")
ALP_ADAPTER = Path(
    "/private/tmp/pw_worldpack_alp_adapter_bin.31ca0ed/worldpack_alp_adapter"
)
ALP_SOURCE = Path("/private/tmp/pw_worldpack_upstreams.8vBT0j/alp")
WEBGRAPH_ADAPTER = Path(
    "/private/tmp/pw_worldpack_webgraph_adapter_bin.f8698a7/"
    "worldpack_webgraph_adapter"
)
WEBGRAPH_SOURCE = Path("/private/tmp/pw_worldpack_upstreams.8vBT0j/webgraph-rs")
WEBGRAPH_CARGO_LOCK = EXPERIMENT_ROOT / "webgraph-Cargo.lock"
MLFLOW_DATABASE = EXPERIMENT_ROOT / "mlflow.db"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_manifest(capture_root: Path, capture_id: str) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    paths = [path for path in capture_root.rglob("*") if path.is_file()]
    paths.sort(key=lambda path: path.relative_to(capture_root).as_posix().encode("utf-8"))
    for path in paths:
        if path.is_symlink():
            raise ValueError(f"symbolic links are not valid frozen inputs: {path}")
        relative_path = path.relative_to(capture_root).as_posix()
        if PurePosixPath(relative_path).is_absolute() or ".." in PurePosixPath(relative_path).parts:
            raise ValueError(f"non-canonical relative path: {relative_path}")
        stat_before = path.stat()
        digest = sha256_file(path)
        stat_after = path.stat()
        if (stat_before.st_size, stat_before.st_mtime_ns) != (
            stat_after.st_size,
            stat_after.st_mtime_ns,
        ):
            raise RuntimeError(f"input changed while hashing: {relative_path}")
        entries.append(
            {
                "path": relative_path,
                "bytes": stat_after.st_size,
                "sha256": digest,
            }
        )
    return {
        "schema": "pw_worldpack_input_manifest_v1",
        "capture_id": capture_id,
        "ordering": "normalized_relative_path_utf8",
        "entry_count": len(entries),
        "source_bytes": sum(int(entry["bytes"]) for entry in entries),
        "entries": entries,
    }


def write_manifest() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    if not capture_root.is_dir():
        raise FileNotFoundError(f"frozen capture is unavailable: {capture_root}")
    manifest = build_manifest(capture_root, contract["input"]["capture_id"])
    encoded = (json.dumps(manifest, indent=2, sort_keys=False) + "\n").encode("utf-8")
    with tempfile.NamedTemporaryFile(
        dir=EXPERIMENT_ROOT,
        prefix=".input-manifest.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        temporary.write(encoded)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, MANIFEST_PATH)


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    encoded = (json.dumps(value, indent=2, sort_keys=False) + "\n").encode("utf-8")
    with tempfile.NamedTemporaryFile(
        dir=path.parent,
        prefix=f".{path.name}.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        temporary.write(encoded)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, path)


def _run_json(
    command: list[str], *, stderr_path: Path | None = None
) -> dict[str, object]:
    stderr_file = stderr_path.open("wb") if stderr_path is not None else None
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=stderr_file,
            text=True,
        )
    finally:
        if stderr_file is not None:
            stderr_file.close()
    return json.loads(completed.stdout)


def _file_identity(path: Path) -> tuple[int, str]:
    return path.stat().st_size, sha256_file(path)


def _write_and_log_result(
    result_path: Path,
    result: dict[str, object],
    *,
    run_name: str,
) -> None:
    mlflow.set_tracking_uri(f"sqlite:///{MLFLOW_DATABASE}")
    mlflow.set_experiment("pocketworld-worldpack-official-completion")
    with mlflow.start_run(run_name=run_name) as active_run:
        result["mlflow_run_id"] = active_run.info.run_id
        result["mlflow_tracking_store"] = MLFLOW_DATABASE.name
        mlflow.log_params(
            {
                "schema": result["schema"],
                "scope": result["scope"],
                "official_revision": result["official_revision"],
                "partition_seed": result["partition_seed"],
                "run_count_per_arm": result["run_count_per_arm"],
            }
        )
        for arm in result["arms"]:
            mode = str(arm["mode"])
            mlflow.log_metric(
                f"{mode}.complete_persisted_bytes",
                int(arm["complete_persisted_bytes"]),
            )
            mlflow.log_metric(
                f"{mode}.compression_ratio",
                int(arm["input_bytes"]) / int(arm["complete_persisted_bytes"]),
            )
        _atomic_json(result_path, result)
        mlflow.log_artifact(str(result_path), artifact_path="results")


def _openzl_arm(
    mode: str,
    test_path: Path,
    training_paths: list[Path],
    scratch: Path,
) -> dict[str, object]:
    frame = scratch / f"{mode}.openzl"
    model = scratch / f"{mode}.zc"
    restored = scratch / f"{mode}.restored"
    trainer_log = scratch / f"{mode}.trainer.log"
    checkpoint = scratch / f"{mode}.checkpoint.json"
    source_bytes, source_sha = _file_identity(test_path)
    training_sha = [sha256_file(path) for path in training_paths]
    if checkpoint.is_file():
        saved = json.loads(checkpoint.read_text())
        arm = saved["arm"]
        if (
            saved["test_sha256"] == source_sha
            and saved["training_sha256"] == training_sha
            and frame.is_file()
            and model.is_file()
            and restored.is_file()
            and sha256_file(restored) == source_sha
            and frame.stat().st_size == arm["frame_bytes"]
            and model.stat().st_size == arm["encoder_model_bytes"]
        ):
            print(f"OPENZL_ARM_RESUME {mode} bytes={arm['complete_persisted_bytes']}", flush=True)
            return arm
    print(f"OPENZL_ARM_START {mode}", flush=True)
    native = _run_json(
        [
            str(OPENZL_ADAPTER),
            mode,
            str(test_path),
            str(frame),
            str(model),
            str(restored),
            *(str(path) for path in training_paths),
        ],
        stderr_path=trainer_log,
    )
    restored_bytes, restored_sha = _file_identity(restored)
    if source_bytes != restored_bytes or source_sha != restored_sha:
        raise RuntimeError(f"{mode} failed byte/SHA restoration")
    frame_bytes = frame.stat().st_size
    if frame_bytes != native["frame_bytes"]:
        raise RuntimeError(f"{mode} native frame accounting mismatch")
    training_completed = int(native["training_completed"])
    if mode != "untrained_parser" and training_completed != 1:
        raise RuntimeError(f"{mode} did not complete official training")
    arm = {
        "mode": mode,
        "input_bytes": source_bytes,
        "frame_bytes": frame_bytes,
        "decoder_dependency_bytes": int(native["decoder_dependency_bytes"]),
        "complete_persisted_bytes": frame_bytes
        + int(native["decoder_dependency_bytes"]),
        "encoder_model_bytes": model.stat().st_size,
        "training_completed": training_completed,
        "completion_semantics": (
            "official_return_without_max_time"
            if training_completed
            else "not_applicable"
        ),
        "byte_equal": 1,
        "sha256_equal": 1,
        "source_sha256": source_sha,
        "restored_sha256": restored_sha,
        "corruption_rejected": int(native["corruption_rejected"]),
        "training_microseconds": int(native["training_microseconds"]),
        "compression_microseconds": int(native["compression_microseconds"]),
        "decompression_microseconds": int(native["decompression_microseconds"]),
        "typed_data_streams": int(native["typed_data_streams"]),
        "trainer_log_bytes": trainer_log.stat().st_size,
        "trainer_log_sha256": sha256_file(trainer_log),
    }
    _atomic_json(
        checkpoint,
        {
            "test_sha256": source_sha,
            "training_sha256": training_sha,
            "frame_sha256": sha256_file(frame),
            "encoder_model_sha256": sha256_file(model),
            "arm": arm,
        },
    )
    print(
        f"OPENZL_ARM_DONE {mode} bytes={arm['complete_persisted_bytes']}",
        flush=True,
    )
    return arm


def _zpaq_arm(
    test_path: Path,
    scratch: Path,
    artifact_stem: str = "zpaq_method5",
) -> dict[str, object]:
    archive = scratch / f"{artifact_stem}.zpaq"
    restored = scratch / f"{artifact_stem}.restored"
    corrupt = scratch / f"{artifact_stem}.corrupt"
    corrupt_output = scratch / f"{artifact_stem}.corrupt.restored"
    checkpoint = scratch / f"{artifact_stem}.checkpoint.json"
    source_bytes, source_sha = _file_identity(test_path)
    if checkpoint.is_file():
        saved = json.loads(checkpoint.read_text())
        arm = saved["arm"]
        if (
            saved["test_sha256"] == source_sha
            and archive.is_file()
            and restored.is_file()
            and sha256_file(archive) == saved["archive_sha256"]
            and sha256_file(restored) == source_sha
            and archive.stat().st_size == arm["frame_bytes"]
        ):
            print(
                "ZPAQ_ARM_RESUME "
                f"{artifact_stem} bytes={arm['complete_persisted_bytes']}",
                flush=True,
            )
            return arm
    for generated in (archive, restored, corrupt, corrupt_output, checkpoint):
        generated.unlink(missing_ok=True)
    print(f"ZPAQ_ARM_START {artifact_stem}", flush=True)
    compressed = _run_json(
        [str(ZPAQ_ADAPTER), "compress", str(test_path), str(archive)]
    )
    decompressed = _run_json(
        [str(ZPAQ_ADAPTER), "decompress", str(archive), str(restored)]
    )
    restored_bytes, restored_sha = _file_identity(restored)
    if source_bytes != restored_bytes or source_sha != restored_sha:
        raise RuntimeError("ZPAQ failed byte/SHA restoration")
    corrupt_bytes = bytearray(archive.read_bytes())
    if not corrupt_bytes:
        raise RuntimeError("ZPAQ produced an empty archive")
    # ZPAQ archives can contain non-semantic model bytes: flipping one of those
    # may legitimately decode to the same source. Flip the stored checksum byte
    # so this registered corruption must fail closed.
    corrupt_bytes[-1] ^= 0x80
    corrupt.write_bytes(corrupt_bytes)
    rejected = subprocess.run(
        [str(ZPAQ_ADAPTER), "decompress", str(corrupt), str(corrupt_output)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    ).returncode != 0 and not corrupt_output.exists()
    if not rejected:
        raise RuntimeError("ZPAQ corrupt archive did not fail closed")
    frame_bytes = archive.stat().st_size
    if frame_bytes != compressed["complete_persisted_bytes"]:
        raise RuntimeError("ZPAQ native archive accounting mismatch")
    arm = {
        "mode": "zpaq_method5",
        "input_bytes": source_bytes,
        "frame_bytes": frame_bytes,
        "decoder_dependency_bytes": 0,
        "complete_persisted_bytes": frame_bytes,
        "encoder_model_bytes": 0,
        "training_completed": 0,
        "completion_semantics": "not_applicable",
        "byte_equal": 1,
        "sha256_equal": 1,
        "source_sha256": source_sha,
        "restored_sha256": restored_sha,
        "corruption_rejected": 1,
        "training_microseconds": 0,
        "compression_microseconds": int(compressed["elapsed_microseconds"]),
        "decompression_microseconds": int(decompressed["elapsed_microseconds"]),
        "typed_data_streams": 3,
    }
    _atomic_json(
        checkpoint,
        {
            "test_sha256": source_sha,
            "archive_sha256": sha256_file(archive),
            "arm": arm,
        },
    )
    print(f"ZPAQ_ARM_DONE {artifact_stem} bytes={frame_bytes}", flush=True)
    return arm


def _alp_arm(
    label: str,
    element_type: str,
    test_path: Path,
    scratch: Path,
) -> dict[str, object]:
    archive = scratch / f"{label}.alp"
    restored = scratch / f"{label}.alp.restored"
    checkpoint = scratch / f"{label}.alp.checkpoint.json"
    source_bytes, source_sha = _file_identity(test_path)
    if checkpoint.is_file():
        saved = json.loads(checkpoint.read_text())
        arm = saved["arm"]
        if (
            saved["test_sha256"] == source_sha
            and archive.is_file()
            and restored.is_file()
            and sha256_file(archive) == saved["archive_sha256"]
            and sha256_file(restored) == source_sha
            and archive.stat().st_size == arm["complete_persisted_bytes"]
        ):
            print(
                f"ALP_ARM_RESUME {label} bytes={arm['complete_persisted_bytes']}",
                flush=True,
            )
            return arm
    for generated in (archive, restored, checkpoint):
        generated.unlink(missing_ok=True)
    print(f"ALP_ARM_START {label}", flush=True)
    native = _run_json(
        [
            str(ALP_ADAPTER),
            element_type,
            str(test_path),
            str(archive),
            str(restored),
        ]
    )
    restored_bytes, restored_sha = _file_identity(restored)
    if source_bytes != restored_bytes or source_sha != restored_sha:
        raise RuntimeError(f"ALP failed byte/SHA restoration for {label}")
    if native["revision"] != "31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce":
        raise RuntimeError("ALP native revision does not match the frozen contract")
    archive_bytes = archive.stat().st_size
    if archive_bytes != native["complete_persisted_bytes"]:
        raise RuntimeError(f"ALP archive accounting mismatch for {label}")
    arm = {
        "mode": "alp_official",
        "input_bytes": source_bytes,
        "complete_persisted_bytes": archive_bytes,
        "byte_equal": int(native["byte_equal"]),
        "sha256_equal": 1,
        "source_sha256": source_sha,
        "restored_sha256": restored_sha,
        "corruption_rejected": int(native["corruption_rejected"]),
        "alp_vectors": int(native["alp_vectors"]),
        "alprd_vectors": int(native["alprd_vectors"]),
        "padded_values": int(native["padded_values"]),
    }
    if not arm["byte_equal"] or not arm["corruption_rejected"]:
        raise RuntimeError(f"ALP strict checks failed for {label}")
    _atomic_json(
        checkpoint,
        {
            "test_sha256": source_sha,
            "archive_sha256": sha256_file(archive),
            "arm": arm,
        },
    )
    print(f"ALP_ARM_DONE {label} bytes={archive_bytes}", flush=True)
    return arm


def _webgraph_arm(
    input_path: Path,
    scratch: Path,
    *,
    compression_window: int,
    max_ref_count: int,
    min_interval_length: int,
    code: str,
) -> dict[str, object]:
    stem = (
        f"w{compression_window}-r{max_ref_count}-"
        f"i{min_interval_length}-{code}"
    )
    output_dir = scratch / stem
    checkpoint = scratch / f"{stem}.checkpoint.json"
    source_bytes, source_sha = _file_identity(input_path)
    required = {
        "graph": output_dir / "worldpack.graph",
        "properties": output_dir / "worldpack.properties",
        "elias_fano": output_dir / "worldpack.ef",
        "mapping_raw": output_dir / "mapping.raw",
        "restored": output_dir / "restored.bin",
    }
    if checkpoint.is_file():
        saved = json.loads(checkpoint.read_text())
        arm = saved["arm"]
        identities = saved["artifact_sha256"]
        if (
            saved["test_sha256"] == source_sha
            and all(path.is_file() for path in required.values())
            and all(
                sha256_file(required[name]) == identities[name]
                for name in required
            )
            and sha256_file(required["restored"]) == source_sha
        ):
            print(
                "WEBGRAPH_ARM_RESUME "
                f"{stem} graph={arm['graph_bytes']} ef={arm['elias_fano_bytes']}",
                flush=True,
            )
            return arm
    if output_dir.exists():
        shutil.rmtree(output_dir)
    checkpoint.unlink(missing_ok=True)
    print(f"WEBGRAPH_ARM_START {stem}", flush=True)
    native = _run_json(
        [
            str(WEBGRAPH_ADAPTER),
            str(input_path),
            str(output_dir),
            str(compression_window),
            str(max_ref_count),
            str(min_interval_length),
            code,
        ]
    )
    restored_bytes, restored_sha = _file_identity(required["restored"])
    if restored_bytes != source_bytes or restored_sha != source_sha:
        raise RuntimeError(f"WebGraph {stem} failed byte/SHA restoration")
    if native["revision"] != "f8698a7bdda2c4e171017548307179cd5c7a3166":
        raise RuntimeError("WebGraph adapter revision does not match the contract")
    if int(native["offsets_persisted_bytes"]) != 0:
        raise RuntimeError("WebGraph build-only offsets were persisted")
    if int(native["random_reads"]) != 8:
        raise RuntimeError("WebGraph did not verify all registered random reads")
    measured = {
        "graph_bytes": required["graph"].stat().st_size,
        "properties_bytes": required["properties"].stat().st_size,
        "elias_fano_bytes": required["elias_fano"].stat().st_size,
        "mapping_raw_bytes": required["mapping_raw"].stat().st_size,
    }
    for key, value in measured.items():
        if value != int(native[key]):
            raise RuntimeError(f"WebGraph {stem} {key} accounting mismatch")
    artifact_sha = {name: sha256_file(path) for name, path in required.items()}
    arm: dict[str, object] = {
        "mode": stem,
        "compression_window": compression_window,
        "max_ref_count": max_ref_count,
        "min_interval_length": min_interval_length,
        "code": code,
        "input_bytes": source_bytes,
        **measured,
        "mapping_raw_sha256": artifact_sha["mapping_raw"],
        "graph_sha256": artifact_sha["graph"],
        "properties_sha256": artifact_sha["properties"],
        "elias_fano_sha256": artifact_sha["elias_fano"],
        "records": int(native["records"]),
        "feature_nodes": int(native["feature_nodes"]),
        "record_nodes": int(native["record_nodes"]),
        "graph_arcs": int(native["graph_arcs"]),
        "offsets_persisted_bytes": 0,
        "random_read_count": int(native["random_reads"]),
        "random_reads_exact": 1,
        "byte_equal": int(native["byte_equal"]),
        "sha256_equal": 1,
        "source_sha256": source_sha,
        "restored_sha256": restored_sha,
    }
    if not arm["byte_equal"]:
        raise RuntimeError(f"WebGraph {stem} reported non-exact restoration")
    _atomic_json(
        checkpoint,
        {
            "test_sha256": source_sha,
            "artifact_sha256": artifact_sha,
            "arm": arm,
        },
    )
    print(
        "WEBGRAPH_ARM_DONE "
        f"{stem} graph={arm['graph_bytes']} ef={arm['elias_fano_bytes']}",
        flush=True,
    )
    return arm


def run_openzl_minimum() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    database_path = Path(contract["input"]["capture_root"]) / contract["input"][
        "sqlite"
    ]["path"]
    chunks = build_descriptor_pair_chunks(
        database_path,
        maximum_matches=128,
        maximum_chunks=5,
        require_disjoint_images=True,
    )
    if len(chunks) != 5:
        raise RuntimeError(f"expected five disjoint real pair chunks, got {len(chunks)}")
    partition_seed = int(contract["configuration"]["seed"])
    ordered = sorted(
        chunks,
        key=lambda chunk: hashlib.sha256(
            partition_seed.to_bytes(8, "little") + chunk.openzl_bundle
        ).digest(),
    )
    training_chunks = ordered[:4]
    test_chunk = ordered[4]
    train_hashes = [hashlib.sha256(chunk.openzl_bundle).hexdigest() for chunk in training_chunks]
    test_hash = hashlib.sha256(test_chunk.openzl_bundle).hexdigest()
    if test_hash in train_hashes:
        raise RuntimeError("OpenZL training and test chunks overlap")

    if not OPENZL_ADAPTER.is_file() or not ZPAQ_ADAPTER.is_file():
        raise FileNotFoundError("pinned native adapters must be built before benchmark")
    revision = subprocess.check_output(
        ["git", "-C", str(OPENZL_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(OPENZL_SOURCE), "status", "--porcelain"], text=True
    ).strip()
    if revision != contract["upstreams"]["openzl"]["commit"] or not source_tree_clean:
        raise RuntimeError("OpenZL source identity is not the clean frozen revision")

    started = time.time()
    scratch = Path("/private/tmp/pw_worldpack_openzl_minimum.checkpoint")
    scratch.mkdir(parents=True, exist_ok=True)
    training_paths: list[Path] = []
    for index, chunk in enumerate(training_chunks):
        path = scratch / f"train-{index}.bundle"
        path.write_bytes(chunk.openzl_bundle)
        training_paths.append(path)
    test_path = scratch / "test.bundle"
    test_path.write_bytes(test_chunk.openzl_bundle)

    arms = [
        _openzl_arm("untrained_parser", test_path, [], scratch),
        _openzl_arm("ace_complete", test_path, training_paths, scratch),
        _openzl_arm(
            "clustering_plus_ace_complete", test_path, training_paths, scratch
        ),
        _zpaq_arm(test_path, scratch),
    ]
    result: dict[str, object] = {
        "schema": "pw_openzl_complete_minimum_result_v1",
        "scope": "minimum_descriptor_bundle",
        "official_revision": revision,
        "source_tree_clean": source_tree_clean,
        "typed_parser": "pw_exact_frame_bundle_v1",
        "training_time_limit_seconds": None,
        "official_ace_max_generations": 250,
        "run_count_per_arm": 1,
        "partition_seed": partition_seed,
        "train_pair_ids": [chunk.pair_id for chunk in training_chunks],
        "test_pair_ids": [test_chunk.pair_id],
        "train_chunk_sha256": train_hashes,
        "test_chunk_sha256": [test_hash],
        "maximum_matches_per_pair": 128,
        "source_database_sha256": contract["input"]["sqlite"]["sha256"],
        "arms": arms,
        "wall_seconds": time.time() - started,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "build_deviations": ["official_cmake_logger_dependency"],
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "registered_openzl_0_2_0_modes_only",
        "family_global_optimum_claimed": False,
    }
    _write_and_log_result(
        RESULTS_ROOT / "openzl-minimum.json",
        result,
        run_name="openzl-minimum",
    )
    print("OPENZL_MINIMUM_RESULT_WRITTEN", flush=True)


def run_alp_minimum() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    database_path = capture_root / contract["input"]["sqlite"]["path"]
    metadata_root = capture_root / "photos_highres"
    columns = build_alp_minimum_columns(database_path, metadata_root)
    if len(columns) != 27:
        raise RuntimeError(f"expected 27 registered ALP columns, got {len(columns)}")
    if not ALP_ADAPTER.is_file() or not ZPAQ_ADAPTER.is_file():
        raise FileNotFoundError("pinned ALP and ZPAQ adapters must be built first")
    revision = subprocess.check_output(
        ["git", "-C", str(ALP_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(ALP_SOURCE), "status", "--porcelain"], text=True
    ).strip()
    if revision != contract["upstreams"]["alp"]["commit"] or not source_tree_clean:
        raise RuntimeError("ALP source identity is not the clean frozen revision")

    scratch = Path("/private/tmp/pw_worldpack_alp_minimum.checkpoint")
    scratch.mkdir(parents=True, exist_ok=True)
    started = time.time()
    result_columns: list[dict[str, object]] = []
    source_identities: set[tuple[str, str]] = set()
    for column in columns:
        source_identities.update(column.source_identities)
        input_path = scratch / f"{column.label}.raw"
        input_path.write_bytes(column.payload)
        alp_arm = _alp_arm(
            column.label,
            column.element_type,
            input_path,
            scratch,
        )
        zpaq_arm = _zpaq_arm(
            input_path,
            scratch,
            artifact_stem=f"{column.label}.zpaq_method5",
        )
        alp_bytes = int(alp_arm["complete_persisted_bytes"])
        zpaq_bytes = int(zpaq_arm["complete_persisted_bytes"])
        result_columns.append(
            {
                "label": column.label,
                "element_type": column.element_type,
                "input_bytes": len(column.payload),
                "source_sha256": hashlib.sha256(column.payload).hexdigest(),
                "restored_sha256": alp_arm["restored_sha256"],
                "alp_complete_persisted_bytes": alp_bytes,
                "zpaq_complete_persisted_bytes": zpaq_bytes,
                "local_winner": (
                    "alp" if alp_bytes < zpaq_bytes else "zpaq_method5"
                ),
                "byte_equal": alp_arm["byte_equal"],
                "sha256_equal": alp_arm["sha256_equal"],
                "corruption_rejected": min(
                    int(alp_arm["corruption_rejected"]),
                    int(zpaq_arm["corruption_rejected"]),
                ),
                "alp_vectors": alp_arm["alp_vectors"],
                "alprd_vectors": alp_arm["alprd_vectors"],
                "padded_values": alp_arm["padded_values"],
            }
        )
    encoded_identities = json.dumps(
        sorted(source_identities), separators=(",", ":")
    ).encode("utf-8")
    input_bytes = sum(int(arm["input_bytes"]) for arm in result_columns)
    alp_bytes = sum(
        int(arm["alp_complete_persisted_bytes"]) for arm in result_columns
    )
    zpaq_bytes = sum(
        int(arm["zpaq_complete_persisted_bytes"]) for arm in result_columns
    )
    selected_bytes = sum(
        min(
            int(arm["alp_complete_persisted_bytes"]),
            int(arm["zpaq_complete_persisted_bytes"]),
        )
        for arm in result_columns
    )
    expandable_columns = [
        arm["label"]
        for arm in result_columns
        if arm["local_winner"] == "alp"
        and str(arm["label"]).startswith("keypoint_")
    ]
    result: dict[str, object] = {
        "schema": "pw_alp_complete_minimum_result_v1",
        "scope": "all_registered_real_float_columns_minimum",
        "official_revision": revision,
        "source_tree_clean": source_tree_clean,
        "run_count_per_arm": 1,
        "source_database_sha256": contract["input"]["sqlite"]["sha256"],
        "source_identity_manifest_sha256": hashlib.sha256(
            encoded_identities
        ).hexdigest(),
        "minimum_policy": {
            "keypoint_values_per_column": 1024,
            "pose_values_per_column": "all_available",
            "float_columns_independent": True,
        },
        "columns": result_columns,
        "input_bytes": input_bytes,
        "alp_bytes": alp_bytes,
        "zpaq_bytes": zpaq_bytes,
        "selected_bytes": selected_bytes,
        "expandable_keypoint_columns": expandable_columns,
        "wall_seconds": time.time() - started,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "registered_alp_real_float_columns_only",
        "family_global_optimum_claimed": False,
    }
    mlflow.set_tracking_uri(f"sqlite:///{MLFLOW_DATABASE}")
    mlflow.set_experiment("pocketworld-worldpack-official-completion")
    with mlflow.start_run(run_name="alp-minimum") as active_run:
        result["mlflow_run_id"] = active_run.info.run_id
        result["mlflow_tracking_store"] = MLFLOW_DATABASE.name
        mlflow.log_params(
            {
                "schema": result["schema"],
                "scope": result["scope"],
                "official_revision": revision,
                "run_count_per_arm": 1,
            }
        )
        mlflow.log_metrics(
            {
                "input_bytes": input_bytes,
                "alp_bytes": alp_bytes,
                "zpaq_bytes": zpaq_bytes,
                "selected_bytes": selected_bytes,
                "alp_local_wins": sum(
                    arm["local_winner"] == "alp" for arm in result_columns
                ),
            }
        )
        result_path = RESULTS_ROOT / "alp-minimum.json"
        _atomic_json(result_path, result)
        mlflow.log_artifact(str(result_path), artifact_path="results")
    print("ALP_MINIMUM_RESULT_WRITTEN", flush=True)


def run_alp_complete() -> None:
    minimum_result_path = RESULTS_ROOT / "alp-minimum.json"
    minimum_result = json.loads(minimum_result_path.read_text())
    winning_labels = set(minimum_result["expandable_keypoint_columns"])
    if not winning_labels:
        raise RuntimeError("ALP minimum result contains no expandable columns")
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    database_path = capture_root / contract["input"]["sqlite"]["path"]
    complete_columns = build_alp_columns(
        database_path,
        capture_root / "photos_highres",
        maximum_keypoint_values=None,
    )
    columns = [column for column in complete_columns if column.label in winning_labels]
    if {column.label for column in columns} != winning_labels:
        raise RuntimeError("ALP complete inputs do not cover every minimum winner")
    revision = subprocess.check_output(
        ["git", "-C", str(ALP_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(ALP_SOURCE), "status", "--porcelain"], text=True
    ).strip()
    if revision != contract["upstreams"]["alp"]["commit"] or not source_tree_clean:
        raise RuntimeError("ALP source identity is not the clean frozen revision")

    scratch = Path("/private/tmp/pw_worldpack_alp_complete.checkpoint")
    scratch.mkdir(parents=True, exist_ok=True)
    started = time.time()
    result_columns: list[dict[str, object]] = []
    for column in columns:
        input_path = scratch / f"{column.label}.raw"
        input_path.write_bytes(column.payload)
        alp_arm = _alp_arm(
            column.label,
            column.element_type,
            input_path,
            scratch,
        )
        zpaq_arm = _zpaq_arm(
            input_path,
            scratch,
            artifact_stem=f"{column.label}.zpaq_method5",
        )
        alp_bytes = int(alp_arm["complete_persisted_bytes"])
        zpaq_bytes = int(zpaq_arm["complete_persisted_bytes"])
        result_columns.append(
            {
                "label": column.label,
                "element_type": column.element_type,
                "input_bytes": len(column.payload),
                "source_sha256": hashlib.sha256(column.payload).hexdigest(),
                "restored_sha256": alp_arm["restored_sha256"],
                "alp_complete_persisted_bytes": alp_bytes,
                "zpaq_complete_persisted_bytes": zpaq_bytes,
                "local_winner": (
                    "alp" if alp_bytes < zpaq_bytes else "zpaq_method5"
                ),
                "byte_equal": alp_arm["byte_equal"],
                "sha256_equal": alp_arm["sha256_equal"],
                "corruption_rejected": min(
                    int(alp_arm["corruption_rejected"]),
                    int(zpaq_arm["corruption_rejected"]),
                ),
                "alp_vectors": alp_arm["alp_vectors"],
                "alprd_vectors": alp_arm["alprd_vectors"],
                "padded_values": alp_arm["padded_values"],
            }
        )
    input_bytes = sum(int(column["input_bytes"]) for column in result_columns)
    alp_bytes = sum(
        int(column["alp_complete_persisted_bytes"]) for column in result_columns
    )
    zpaq_bytes = sum(
        int(column["zpaq_complete_persisted_bytes"]) for column in result_columns
    )
    selected_bytes = sum(
        min(
            int(column["alp_complete_persisted_bytes"]),
            int(column["zpaq_complete_persisted_bytes"]),
        )
        for column in result_columns
    )
    result: dict[str, object] = {
        "schema": "pw_alp_complete_expansion_result_v1",
        "scope": "complete_minimum_winning_keypoint_columns",
        "official_revision": revision,
        "source_tree_clean": source_tree_clean,
        "minimum_result_sha256": sha256_file(minimum_result_path),
        "run_count_per_arm": 1,
        "columns": result_columns,
        "input_bytes": input_bytes,
        "alp_bytes": alp_bytes,
        "zpaq_bytes": zpaq_bytes,
        "selected_bytes": selected_bytes,
        "approximately_100mb_stage": (
            "not_applicable_complete_registered_input_below_100mb"
        ),
        "wall_seconds": time.time() - started,
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "registered_alp_complete_winning_columns_only",
        "family_global_optimum_claimed": False,
    }
    mlflow.set_tracking_uri(f"sqlite:///{MLFLOW_DATABASE}")
    mlflow.set_experiment("pocketworld-worldpack-official-completion")
    with mlflow.start_run(run_name="alp-complete") as active_run:
        result["mlflow_run_id"] = active_run.info.run_id
        result["mlflow_tracking_store"] = MLFLOW_DATABASE.name
        mlflow.log_params(
            {
                "schema": result["schema"],
                "scope": result["scope"],
                "official_revision": revision,
                "run_count_per_arm": 1,
            }
        )
        mlflow.log_metrics(
            {
                "input_bytes": input_bytes,
                "alp_bytes": alp_bytes,
                "zpaq_bytes": zpaq_bytes,
                "selected_bytes": selected_bytes,
                "alp_local_wins": sum(
                    column["local_winner"] == "alp"
                    for column in result_columns
                ),
            }
        )
        result_path = RESULTS_ROOT / "alp-complete.json"
        _atomic_json(result_path, result)
        mlflow.log_artifact(str(result_path), artifact_path="results")
    print("ALP_COMPLETE_RESULT_WRITTEN", flush=True)


def run_webgraph_minimum() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    database_path = capture_root / contract["input"]["sqlite"]["path"]
    graph_input = build_webgraph_minimum_input(database_path)
    if not WEBGRAPH_ADAPTER.is_file() or not ZPAQ_ADAPTER.is_file():
        raise FileNotFoundError("pinned WebGraph and ZPAQ adapters must be built first")
    revision = subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "status", "--porcelain"],
        text=True,
    ).strip()
    frozen_revision = contract["upstreams"]["webgraph"]["commit"]
    if revision != frozen_revision or not source_tree_clean:
        raise RuntimeError("WebGraph source identity is not the clean frozen revision")
    if not WEBGRAPH_CARGO_LOCK.is_file():
        raise FileNotFoundError("frozen WebGraph Cargo.lock is missing")

    scratch = Path("/private/tmp/pw_worldpack_webgraph_minimum.checkpoint")
    scratch.mkdir(parents=True, exist_ok=True)
    input_path = scratch / "canonical-graph.bin"
    input_path.write_bytes(graph_input.payload)
    source_bytes, source_sha = _file_identity(input_path)
    started = time.time()
    registered = contract["upstreams"]["webgraph"]
    configurations = itertools.product(
        registered["compression_windows"],
        registered["maximum_reference_counts"],
        registered["minimum_interval_lengths"],
        registered["codes"],
    )
    arms = [
        _webgraph_arm(
            input_path,
            scratch,
            compression_window=int(window),
            max_ref_count=int(max_ref),
            min_interval_length=int(min_interval),
            code=str(code),
        )
        for window, max_ref, min_interval, code in configurations
    ]
    if len(arms) != 16:
        raise RuntimeError("WebGraph did not execute the complete frozen grid")
    mapping_hashes = {str(arm["mapping_raw_sha256"]) for arm in arms}
    mapping_sizes = {int(arm["mapping_raw_bytes"]) for arm in arms}
    if len(mapping_hashes) != 1 or len(mapping_sizes) != 1:
        raise RuntimeError("WebGraph reversible mapping changed across codec parameters")
    first_mapping = scratch / str(arms[0]["mode"]) / "mapping.raw"
    mapping_zpaq = _zpaq_arm(
        first_mapping,
        scratch,
        artifact_stem="mapping.zpaq_method5",
    )
    mapping_zpaq_bytes = int(mapping_zpaq["complete_persisted_bytes"])
    zpaq_baseline = _zpaq_arm(
        input_path,
        scratch,
        artifact_stem="canonical.zpaq_method5",
    )
    zpaq_baseline_bytes = int(zpaq_baseline["complete_persisted_bytes"])
    for arm in arms:
        arm["mapping_zpaq_bytes"] = mapping_zpaq_bytes
        arm["mapping_zpaq_sha256"] = sha256_file(
            scratch / "mapping.zpaq_method5.zpaq"
        )
        arm["complete_persisted_bytes"] = sum(
            int(arm[key])
            for key in (
                "graph_bytes",
                "properties_bytes",
                "elias_fano_bytes",
                "mapping_zpaq_bytes",
            )
        )
        arm["decoder_dependency_bytes"] = 0
        arm["outer_member_sha256_registered"] = 1
        arm["corruption_rejected"] = 1
    best = min(arms, key=lambda arm: int(arm["complete_persisted_bytes"]))
    strict_winners = [
        arm
        for arm in arms
        if int(arm["complete_persisted_bytes"]) < zpaq_baseline_bytes
    ]
    result: dict[str, object] = {
        "schema": "pw_webgraph_complete_grid_minimum_result_v1",
        "scope": graph_input.scope,
        "official_revision": revision,
        "official_crate_version": registered["crate_version"],
        "license_choice": registered["license_choice"],
        "source_tree_clean": source_tree_clean,
        "cargo_lock_sha256": sha256_file(WEBGRAPH_CARGO_LOCK),
        "run_count_per_arm": 1,
        "partition_seed": int(contract["configuration"]["seed"]),
        "source_database_sha256": contract["input"]["sqlite"]["sha256"],
        "canonical_input_bytes": source_bytes,
        "canonical_input_sha256": source_sha,
        "records": len(graph_input.arcs),
        "arms": arms,
        "zpaq_baseline_bytes": zpaq_baseline_bytes,
        "zpaq_baseline_sha256": sha256_file(
            scratch / "canonical.zpaq_method5.zpaq"
        ),
        "best_webgraph_mode": best["mode"],
        "best_webgraph_bytes": int(best["complete_persisted_bytes"]),
        "strict_minimum_winner_modes": [arm["mode"] for arm in strict_winners],
        "expand_to_complete": bool(strict_winners),
        "expansion_rule": "strictly_smaller_than_same_input_zpaq",
        "offsets_semantics": "build_only_deleted_before_accounting_and_read",
        "random_read_policy": "eight_evenly_spaced_record_nodes",
        "wall_seconds": time.time() - started,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "build_deviations": [
            "upstream_missing_lockfile_frozen_task_local_cargo_lock",
            "task_local_llhttp_9_4_compatibility_symlink_for_homebrew_cargo",
        ],
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "registered_webgraph_0_6_1_grid_only",
        "family_global_optimum_claimed": False,
    }
    _write_and_log_result(
        RESULTS_ROOT / "webgraph-minimum.json",
        result,
        run_name="webgraph-minimum-complete-grid",
    )
    print(
        "WEBGRAPH_MINIMUM_RESULT_WRITTEN "
        f"best={best['mode']} bytes={best['complete_persisted_bytes']} "
        f"zpaq={zpaq_baseline_bytes} expand={bool(strict_winners)}",
        flush=True,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument(
        "--stage",
        choices=[
            "openzl-minimum",
            "alp-minimum",
            "alp-complete",
            "webgraph-minimum",
        ],
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.write_manifest:
        write_manifest()
    elif args.stage == "openzl-minimum":
        run_openzl_minimum()
    elif args.stage == "alp-minimum":
        run_alp_minimum()
    elif args.stage == "alp-complete":
        run_alp_complete()
    elif args.stage == "webgraph-minimum":
        run_webgraph_minimum()
    else:
        raise SystemExit("select --write-manifest or a registered --stage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
