#!/usr/bin/env python3
"""Strict-lossless benchmark orchestrator; Task 1 freezes input identity only."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path, PurePosixPath
import subprocess
import tempfile
import time

import mlflow
import yaml

from prepare_inputs import build_descriptor_pair_chunks


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


def _zpaq_arm(test_path: Path, scratch: Path) -> dict[str, object]:
    archive = scratch / "zpaq_method5.zpaq"
    restored = scratch / "zpaq_method5.restored"
    corrupt = scratch / "zpaq_method5.corrupt"
    corrupt_output = scratch / "zpaq_method5.corrupt.restored"
    checkpoint = scratch / "zpaq_method5.checkpoint.json"
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
                f"zpaq_method5 bytes={arm['complete_persisted_bytes']}",
                flush=True,
            )
            return arm
    for generated in (archive, restored, corrupt, corrupt_output, checkpoint):
        generated.unlink(missing_ok=True)
    print("ZPAQ_ARM_START zpaq_method5", flush=True)
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
    corrupt_bytes[len(corrupt_bytes) // 2] ^= 0x80
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
    print(f"ZPAQ_ARM_DONE zpaq_method5 bytes={frame_bytes}", flush=True)
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-manifest", action="store_true")
    parser.add_argument("--stage", choices=["openzl-minimum"])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.write_manifest:
        write_manifest()
    elif args.stage == "openzl-minimum":
        run_openzl_minimum()
    else:
        raise SystemExit("select --write-manifest or a registered --stage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
