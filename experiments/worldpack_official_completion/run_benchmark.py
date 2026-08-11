#!/usr/bin/env python3
"""Strict-lossless benchmark orchestrator; Task 1 freezes input identity only."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
import platform
from pathlib import Path, PurePosixPath
import resource
import shutil
import subprocess
import tempfile
import time
from typing import Callable

import mlflow
import yaml

from prepare_inputs import (
    build_alp_columns,
    build_alp_minimum_columns,
    build_descriptor_pair_chunks,
    build_webgraph_complete_input,
    build_webgraph_minimum_input,
)
from worldpack import (
    FileCodec,
    MemberSpec,
    WorldPackCorruption,
    WorldPackReader,
    WorldPackWriteResult,
    WorldPackWriter,
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
LEPTON_HOST_BINARY = Path(
    "/private/tmp/pw_worldpack_lepton_host_target.0.5.8/release/"
    "lepton_jpeg_util"
)
SIMILARITY_ARCHIVE = Path(
    "/private/tmp/pw_worldpack_similarity_export.run.v1/"
    "similarity_forest_v1.zpaq"
)
SIMILARITY_DECODER = Path(
    "/private/tmp/pw_worldpack_similarity_decoder.build.v1/"
    "worldpack_similarity_forest_decoder"
)
CODEC_CACHE_ROOT = Path("/private/tmp/pw_worldpack_codec_cache.v1")
MLFLOW_DATABASE = EXPERIMENT_ROOT / "mlflow.db"


def similarity_forest_result_path() -> Path:
    return (
        EXPERIMENT_ROOT.parent
        / "descriptor_similarity_forest_zpaq"
        / "results"
        / "2026-08-02-descriptor-similarity-forest-zpaq.json"
    )


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
    representation: str = "record_nodes_v1",
) -> dict[str, object]:
    base_stem = (
        f"w{compression_window}-r{max_ref_count}-"
        f"i{min_interval_length}-{code}"
    )
    stem = (
        base_stem
        if representation == "record_nodes_v1"
        else f"direct-{base_stem}"
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
            and saved.get("representation", "record_nodes_v1") == representation
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
            representation,
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
        "representation": representation,
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
        "duplicate_records": int(native.get("duplicate_records", 0)),
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
            "representation": representation,
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


def _cached_file_codec(
    codec_id: str,
    suffix: str,
    encode_uncached: Callable[[Path, Path], None],
    decode: Callable[[Path, Path], None],
) -> FileCodec:
    cache_root = CODEC_CACHE_ROOT / codec_id

    def encode_file(source: Path, destination: Path) -> None:
        source_sha = sha256_file(source)
        cache_root.mkdir(parents=True, exist_ok=True)
        cached = cache_root / f"{source_sha}{suffix}"
        if not cached.is_file():
            temporary = cache_root / f".{cached.name}.tmp-{os.getpid()}"
            temporary.unlink(missing_ok=True)
            try:
                encode_uncached(source, temporary)
                if not temporary.is_file():
                    raise RuntimeError(f"{codec_id} did not produce an archive")
                os.replace(temporary, cached)
            finally:
                temporary.unlink(missing_ok=True)
        shutil.copyfile(cached, destination)

    return FileCodec(codec_id, encode_file, decode)


def _worldpack_codecs(*, require_similarity: bool) -> list[FileCodec]:
    if not LEPTON_HOST_BINARY.is_file() or not ZPAQ_ADAPTER.is_file():
        raise FileNotFoundError("pinned Lepton and ZPAQ host tools must be built")

    def lepton_encode(source: Path, destination: Path) -> None:
        subprocess.run(
            [
                str(LEPTON_HOST_BINARY),
                "--quiet",
                "--overwrite",
                str(source),
                str(destination),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

    def lepton_decode(source: Path, destination: Path) -> None:
        destination.unlink(missing_ok=True)
        subprocess.run(
            [
                str(LEPTON_HOST_BINARY),
                "--quiet",
                "--overwrite",
                str(source),
                str(destination),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )

    def zpaq_encode(source: Path, destination: Path) -> None:
        destination.unlink(missing_ok=True)
        _run_json(
            [str(ZPAQ_ADAPTER), "compress", str(source), str(destination)]
        )

    def zpaq_decode(source: Path, destination: Path) -> None:
        destination.unlink(missing_ok=True)
        _run_json(
            [str(ZPAQ_ADAPTER), "decompress", str(source), str(destination)]
        )

    codecs = [
        _cached_file_codec(
            "lepton_jpeg_0_5_8",
            ".lep",
            lepton_encode,
            lepton_decode,
        ),
        _cached_file_codec(
            "zpaq_7_15_method5",
            ".zpaq",
            zpaq_encode,
            zpaq_decode,
        ),
    ]
    if require_similarity:
        if not SIMILARITY_ARCHIVE.is_file() or not SIMILARITY_DECODER.is_file():
            raise FileNotFoundError(
                "verified similarity-forest archive and decoder are required"
            )
        expected_archive_sha = (
            "9b425ddb6751398593c0beba8a387a4f69693c8d5dc4737b16911ce3d3f9b3e1"
        )
        if (
            SIMILARITY_ARCHIVE.stat().st_size != 116_739_319
            or sha256_file(SIMILARITY_ARCHIVE) != expected_archive_sha
        ):
            raise RuntimeError("similarity-forest artifact identity changed")

        def similarity_encode(source: Path, destination: Path) -> None:
            if (
                source.stat().st_size != 198_983_680
                or sha256_file(source)
                != "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
            ):
                raise ValueError("similarity-forest input identity mismatch")
            shutil.copyfile(SIMILARITY_ARCHIVE, destination)

        def similarity_decode(source: Path, destination: Path) -> None:
            destination.unlink(missing_ok=True)
            completed = subprocess.run(
                [
                    str(SIMILARITY_DECODER),
                    str(source),
                    str(destination),
                    "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0",
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            decoded = json.loads(completed.stdout)
            if decoded["sqlite_integrity_ok"] != 1:
                raise RuntimeError("similarity-forest decoder integrity gate failed")

        codecs.append(
            FileCodec(
                "similarity_forest_v1_zpaq_7_15",
                similarity_encode,
                similarity_decode,
            )
        )
    return codecs


def _load_frozen_manifest() -> dict[str, object]:
    manifest = json.loads(MANIFEST_PATH.read_text())
    if (
        manifest["schema"] != "pw_worldpack_input_manifest_v1"
        or manifest["entry_count"] != 322
        or manifest["source_bytes"] != 580_406_089
        or sha256_file(MANIFEST_PATH)
        != "46d0621460ffd99dbb6c9da5bd7340a177f8242d86b1bc83b4be70edbd9c2a92"
    ):
        raise RuntimeError("frozen WorldPack manifest identity changed")
    return manifest


def _candidate_codecs(relative_path: str) -> tuple[str, ...]:
    if relative_path == "official_sfm_live.db":
        return ("similarity_forest_v1_zpaq_7_15", "raw")
    suffix = PurePosixPath(relative_path).suffix.lower()
    if suffix == ".jpg":
        return ("lepton_jpeg_0_5_8", "raw")
    if suffix in {".json", ".jsonl", ".ply", ".db-shm"}:
        return ("zpaq_7_15_method5", "raw")
    return ("raw",)


def _worldpack_stage_entries(
    stage: str,
    manifest: dict[str, object],
) -> tuple[list[dict[str, object]], str]:
    entries = list(manifest["entries"])
    if stage == "minimum":
        selected = [
            next(entry for entry in entries if str(entry["path"]).endswith(".jpg")),
            next(entry for entry in entries if str(entry["path"]).endswith(".jxl")),
            next(entry for entry in entries if str(entry["path"]).endswith(".ply")),
            next(entry for entry in entries if str(entry["path"]).endswith(".json")),
            next(entry for entry in entries if str(entry["path"]).endswith(".jsonl")),
        ]
        return selected, "minimum_mixed_real_members"
    if stage == "approximately-100mb":
        selected = []
        selected_bytes = 0
        for entry in entries:
            if not str(entry["path"]).startswith("photos_highres/"):
                continue
            selected.append(entry)
            selected_bytes += int(entry["bytes"])
            if selected_bytes >= 100_000_000:
                break
        if not 100_000_000 <= selected_bytes <= 110_000_000:
            raise RuntimeError(
                f"actual ordered photo prefix is {selected_bytes}, outside frozen bound"
            )
        return selected, "ordered_photo_prefix_at_least_100000000"
    if stage == "complete":
        return entries, "complete_frozen_manifest_order"
    raise ValueError(f"unknown WorldPack stage: {stage}")


def _verify_selected_sources(
    capture_root: Path,
    entries: Sequence[dict[str, object]],
) -> bool:
    return all(
        (capture_root / str(entry["path"])).is_file()
        and (capture_root / str(entry["path"])).stat().st_size
        == int(entry["bytes"])
        and sha256_file(capture_root / str(entry["path"])) == entry["sha256"]
        for entry in entries
    )


def _worldpack_corruption_probe(
    archive: Path,
    writer_result: WorldPackWriteResult,
    codecs: Sequence[FileCodec],
    scratch: Path,
) -> bool:
    entry = next(entry for entry in writer_result.entries if entry.payload_bytes > 0)
    corrupt = scratch / "corruption-probe.worldpack"
    corrupt.unlink(missing_ok=True)
    subprocess.run(["cp", "-c", str(archive), str(corrupt)], check=True)
    try:
        with corrupt.open("r+b") as output:
            output.seek(entry.payload_offset + min(7, entry.payload_bytes - 1))
            original = output.read(1)
            output.seek(-1, os.SEEK_CUR)
            output.write(bytes([original[0] ^ 0x80]))
            output.flush()
            os.fsync(output.fileno())
        try:
            WorldPackReader(corrupt, codecs=codecs).read_member(entry.path)
        except WorldPackCorruption:
            return True
        return False
    finally:
        corrupt.unlink(missing_ok=True)


def _write_worldpack_result(
    path: Path,
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
                "selection_policy": result["selection_policy"],
                "member_count": result["member_count"],
            }
        )
        mlflow.log_metrics(
            {
                "source_bytes": int(result["source_bytes"]),
                "complete_persisted_bytes": int(
                    result["complete_persisted_bytes"]
                ),
                "compression_ratio": int(result["source_bytes"])
                / int(result["complete_persisted_bytes"]),
                "peak_rss_bytes": int(result["peak_rss_bytes"]),
                "peak_temp_bytes": int(result["peak_temp_bytes"]),
            }
        )
        _atomic_json(path, result)
        mlflow.log_artifact(str(path), artifact_path="results")


def run_worldpack(stage: str) -> None:
    manifest = _load_frozen_manifest()
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    selected, selection_policy = _worldpack_stage_entries(stage, manifest)
    require_similarity = stage == "complete"
    codecs = _worldpack_codecs(require_similarity=require_similarity)
    scratch = Path(f"/private/tmp/pw_worldpack_{stage}.checkpoint.v1")
    scratch.mkdir(parents=True, exist_ok=True)
    archive = scratch / "capture.worldpack"
    restored_root = scratch / "restored"
    result_names = {
        "minimum": "worldpack-minimum.json",
        "approximately-100mb": "worldpack-approximately-100mb.json",
        "complete": "worldpack-complete-project.json",
    }
    result_path = RESULTS_ROOT / result_names[stage]
    implementation_sha = sha256_file(EXPERIMENT_ROOT / "worldpack.py")
    if result_path.is_file() and archive.is_file():
        saved = json.loads(result_path.read_text())
        if (
            saved.get("archive_sha256") == sha256_file(archive)
            and saved.get("worldpack_implementation_sha256") == implementation_sha
            and saved.get("input_manifest_sha256") == sha256_file(MANIFEST_PATH)
        ):
            print(
                f"WORLDPACK_STAGE_RESUME {stage} "
                f"bytes={saved['complete_persisted_bytes']}",
                flush=True,
            )
            return
    if not _verify_selected_sources(capture_root, selected):
        raise RuntimeError("one or more selected source members changed")
    specs = [
        MemberSpec(
            str(entry["path"]),
            capture_root / str(entry["path"]),
            _candidate_codecs(str(entry["path"])),
        )
        for entry in selected
    ]
    started = time.time()
    print(
        f"WORLDPACK_STAGE_START {stage} members={len(specs)} "
        f"source_bytes={sum(int(entry['bytes']) for entry in selected)}",
        flush=True,
    )
    manifest_sha256 = sha256_file(MANIFEST_PATH)
    reader: WorldPackReader | None = None
    if archive.is_file():
        candidate_reader = WorldPackReader(archive, codecs=codecs)
        if (
            candidate_reader.manifest_sha256 == manifest_sha256
            and candidate_reader.paths
            == tuple(str(entry["path"]) for entry in selected)
        ):
            reader = candidate_reader
            writer_result = reader.reconstructed_write_result()
            print(
                f"WORLDPACK_ARCHIVE_CHECKPOINT_REUSED {stage} "
                f"bytes={writer_result.complete_persisted_bytes}",
                flush=True,
            )
    if reader is None:
        writer_result = WorldPackWriter(
            archive,
            manifest_sha256=manifest_sha256,
            scratch_root=scratch / "writer-scratch",
            codecs=codecs,
        ).write(specs)
        reader = WorldPackReader(archive, codecs=codecs)
    restored_exact = restored_root.is_dir() and all(
        (restored_root / str(entry["path"])).stat().st_size == int(entry["bytes"])
        and sha256_file(restored_root / str(entry["path"])) == entry["sha256"]
        for entry in selected
    )
    if not restored_exact:
        if restored_root.exists():
            shutil.rmtree(restored_root)
        reader.extract_all(restored_root)
        restored_exact = all(
            (restored_root / str(entry["path"])).stat().st_size
            == int(entry["bytes"])
            and sha256_file(restored_root / str(entry["path"])) == entry["sha256"]
            for entry in selected
        )
    if not restored_exact:
        raise RuntimeError("WorldPack complete extraction differs from frozen members")
    random_indices = sorted(
        {
            numerator * (len(selected) - 1) // 7
            for numerator in range(min(8, len(selected)))
        }
    )
    random_exact = True
    for index in random_indices:
        entry = selected[index]
        random_output = scratch / "random-read" / f"member-{index}.bin"
        random_output.parent.mkdir(parents=True, exist_ok=True)
        reader.extract_member(str(entry["path"]), random_output)
        random_exact = random_exact and (
            random_output.stat().st_size == int(entry["bytes"])
            and sha256_file(random_output) == entry["sha256"]
        )
        random_output.unlink(missing_ok=True)
    corruption_rejected = _worldpack_corruption_probe(
        archive, writer_result, codecs, scratch
    )
    if not random_exact or not corruption_rejected:
        raise RuntimeError("WorldPack random read or corruption gate failed")
    sqlite_integrity = "not_in_scope"
    if stage == "complete":
        sqlite_integrity = subprocess.check_output(
            [
                "sqlite3",
                str(restored_root / "official_sfm_live.db"),
                "PRAGMA query_only=ON; PRAGMA integrity_check;",
            ],
            text=True,
        ).strip()
        if sqlite_integrity != "ok":
            raise RuntimeError("restored SQLite integrity_check failed")
    source_bytes = sum(int(entry["bytes"]) for entry in selected)
    codec_counts = Counter(entry.codec_id for entry in writer_result.entries)
    database_entries = [
        entry
        for entry in writer_result.entries
        if entry.path == "official_sfm_live.db"
    ]
    peak_temp_bytes = (
        archive.stat().st_size
        + sum(path.stat().st_size for path in restored_root.rglob("*") if path.is_file())
        + sum(path.stat().st_size for path in CODEC_CACHE_ROOT.rglob("*") if path.is_file())
    )
    schema = {
        "minimum": "pw_worldpack_minimum_result_v1",
        "approximately-100mb": "pw_worldpack_approximately_100mb_result_v1",
        "complete": "pw_worldpack_complete_project_result_v1",
    }[stage]
    result: dict[str, object] = {
        "schema": schema,
        "scope": stage,
        "selection_policy": selection_policy,
        "input_manifest_sha256": sha256_file(MANIFEST_PATH),
        "source_bytes": source_bytes,
        "member_count": len(selected),
        "restored_member_count": len(selected),
        "complete_persisted_bytes": writer_result.complete_persisted_bytes,
        "archive_sha256": writer_result.archive_sha256,
        "header_bytes": writer_result.header_bytes,
        "chunk_header_bytes": writer_result.chunk_header_bytes,
        "payload_bytes": writer_result.payload_bytes,
        "index_bytes": writer_result.index_bytes,
        "footer_bytes": writer_result.footer_bytes,
        "container_overhead_bytes": writer_result.header_bytes
        + writer_result.chunk_header_bytes
        + writer_result.index_bytes
        + writer_result.footer_bytes,
        "compression_ratio": source_bytes / writer_result.complete_persisted_bytes,
        "reduction_fraction": 1
        - writer_result.complete_persisted_bytes / source_bytes,
        "selected_codec_counts": dict(sorted(codec_counts.items())),
        "database_archive_bytes": (
            database_entries[0].payload_bytes if database_entries else 0
        ),
        "source_unchanged": int(_verify_selected_sources(capture_root, selected)),
        "source_manifest_reverified": int(
            stage != "complete"
            or build_manifest(capture_root, str(manifest["capture_id"])) == manifest
        ),
        "all_members_byte_equal": int(restored_exact),
        "all_members_sha256_equal": int(restored_exact),
        "sqlite_integrity_check": sqlite_integrity,
        "random_read_count": len(random_indices),
        "random_reads_exact": int(random_exact),
        "corruption_rejected": int(corruption_rejected),
        "worldpack_implementation_sha256": implementation_sha,
        "lepton_revision": "90fdc27828676892fbb41777cfcc6bad1e470516",
        "zpaq_revision": contract["baselines"]["zpaq"]["source_sha256"],
        "similarity_forest_result_sha256": (
            sha256_file(similarity_forest_result_path())
            if stage == "complete"
            else None
        ),
        "members": [
            {
                "path": entry.path,
                "source_bytes": entry.original_bytes,
                "source_sha256": entry.original_sha256,
                "selected_codec": entry.codec_id,
                "persisted_payload_bytes": entry.payload_bytes,
                "persisted_payload_sha256": entry.payload_sha256,
                "candidate_bytes": dict(entry.candidate_bytes),
                "rejected_candidates": list(entry.rejected_candidates),
            }
            for entry in writer_result.entries
        ],
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "peak_temp_bytes": peak_temp_bytes,
        "wall_seconds": time.time() - started,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "worldpack_experiment_only",
    }
    _write_worldpack_result(
        result_path,
        result,
        run_name=f"worldpack-{stage}",
    )
    shutil.rmtree(restored_root)
    print(
        f"WORLDPACK_STAGE_DONE {stage} "
        f"source={source_bytes} archive={writer_result.complete_persisted_bytes}",
        flush=True,
    )


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
        "timing_comparability": "not_registered_size_only_scale_audit",
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


def run_webgraph_complete_scale_audit() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    database_path = capture_root / contract["input"]["sqlite"]["path"]
    graph_input = build_webgraph_complete_input(database_path)
    revision = subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "status", "--porcelain"],
        text=True,
    ).strip()
    if (
        revision != contract["upstreams"]["webgraph"]["commit"]
        or not source_tree_clean
    ):
        raise RuntimeError("WebGraph source identity is not the clean frozen revision")
    scratch = Path("/private/tmp/pw_worldpack_webgraph_complete.checkpoint.v1")
    scratch.mkdir(parents=True, exist_ok=True)
    input_path = scratch / "canonical-graph.bin"
    input_path.write_bytes(graph_input.payload)
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
        raise RuntimeError("complete WebGraph scale audit missed a grid arm")
    if len({str(arm["mapping_raw_sha256"]) for arm in arms}) != 1:
        raise RuntimeError("complete WebGraph mapping changed across grid arms")
    first_mapping = scratch / str(arms[0]["mode"]) / "mapping.raw"
    mapping_zpaq = _zpaq_arm(
        first_mapping,
        scratch,
        artifact_stem="mapping.zpaq_method5",
    )
    canonical_zpaq = _zpaq_arm(
        input_path,
        scratch,
        artifact_stem="canonical.zpaq_method5",
    )
    mapping_zpaq_bytes = int(mapping_zpaq["complete_persisted_bytes"])
    zpaq_baseline_bytes = int(canonical_zpaq["complete_persisted_bytes"])
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
    minimum_path = RESULTS_ROOT / "webgraph-minimum.json"
    minimum = json.loads(minimum_path.read_text())
    result: dict[str, object] = {
        "schema": "pw_webgraph_complete_scale_audit_v1",
        "scope": graph_input.scope,
        "official_revision": revision,
        "official_crate_version": registered["crate_version"],
        "source_tree_clean": source_tree_clean,
        "post_hoc_scale_audit": True,
        "registered_deviation": (
            "expanded_after_minimum_loss_to_test_fixed_overhead_extrapolation"
        ),
        "deviation_reason": (
            "minimum-unit fixed graph/index overhead cannot support a family-wide "
            "or full-scale conclusion"
        ),
        "run_count_per_arm": 1,
        "partition_seed": int(contract["configuration"]["seed"]),
        "source_database_sha256": contract["input"]["sqlite"]["sha256"],
        "canonical_input_bytes": input_path.stat().st_size,
        "canonical_input_sha256": sha256_file(input_path),
        "records": len(graph_input.arcs),
        "arms": arms,
        "zpaq_baseline_bytes": zpaq_baseline_bytes,
        "zpaq_baseline_sha256": sha256_file(
            scratch / "canonical.zpaq_method5.zpaq"
        ),
        "best_webgraph_mode": best["mode"],
        "best_webgraph_bytes": int(best["complete_persisted_bytes"]),
        "best_webgraph_vs_zpaq_ratio": int(best["complete_persisted_bytes"])
        / zpaq_baseline_bytes,
        "minimum_best_webgraph_vs_zpaq_ratio": int(
            minimum["best_webgraph_bytes"]
        )
        / int(minimum["zpaq_baseline_bytes"]),
        "scale_changed_relative_gap": (
            int(best["complete_persisted_bytes"]) / zpaq_baseline_bytes
            != int(minimum["best_webgraph_bytes"])
            / int(minimum["zpaq_baseline_bytes"])
        ),
        "minimum_result_sha256": sha256_file(minimum_path),
        "offsets_semantics": "build_only_deleted_before_accounting_and_read",
        "random_read_policy": "eight_evenly_spaced_record_nodes",
        "wall_seconds": time.time() - started,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": "complete_real_match_graph_registered_grid",
        "family_global_optimum_claimed": False,
    }
    _write_and_log_result(
        RESULTS_ROOT / "webgraph-complete-scale-audit.json",
        result,
        run_name="webgraph-complete-scale-audit",
    )
    print(
        "WEBGRAPH_COMPLETE_SCALE_RESULT_WRITTEN "
        f"best={best['mode']} bytes={best['complete_persisted_bytes']} "
        f"zpaq={zpaq_baseline_bytes}",
        flush=True,
    )


def run_webgraph_direct(scope: str) -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    database_path = capture_root / contract["input"]["sqlite"]["path"]
    if scope == "minimum":
        graph_input = build_webgraph_minimum_input(database_path)
        record_result_path = RESULTS_ROOT / "webgraph-minimum.json"
        result_path = RESULTS_ROOT / "webgraph-direct-minimum.json"
        schema = "pw_webgraph_direct_minimum_result_v1"
    elif scope == "complete":
        minimum = json.loads(
            (RESULTS_ROOT / "webgraph-direct-minimum.json").read_text()
        )
        if not minimum["expand_to_complete"]:
            raise RuntimeError("direct-edge representation did not win its local gate")
        graph_input = build_webgraph_complete_input(database_path)
        record_result_path = RESULTS_ROOT / "webgraph-complete-scale-audit.json"
        result_path = RESULTS_ROOT / "webgraph-direct-complete.json"
        schema = "pw_webgraph_direct_complete_result_v1"
    else:
        raise ValueError(f"unknown direct WebGraph scope {scope}")
    revision = subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    source_tree_clean = not subprocess.check_output(
        ["git", "-C", str(WEBGRAPH_SOURCE), "status", "--porcelain"],
        text=True,
    ).strip()
    if (
        revision != contract["upstreams"]["webgraph"]["commit"]
        or not source_tree_clean
    ):
        raise RuntimeError("WebGraph source identity is not the clean frozen revision")
    scratch = Path(f"/private/tmp/pw_worldpack_webgraph_direct_{scope}.checkpoint.v1")
    scratch.mkdir(parents=True, exist_ok=True)
    input_path = scratch / "canonical-graph.bin"
    input_path.write_bytes(graph_input.payload)
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
            representation="direct_unique_edges_v1",
        )
        for window, max_ref, min_interval, code in configurations
    ]
    if len(arms) != 16 or len(
        {str(arm["mapping_raw_sha256"]) for arm in arms}
    ) != 1:
        raise RuntimeError("direct WebGraph grid or mapping identity is incomplete")
    mapping_path = scratch / str(arms[0]["mode"]) / "mapping.raw"
    mapping_zpaq = _zpaq_arm(
        mapping_path,
        scratch,
        artifact_stem="mapping.zpaq_method5",
    )
    mapping_zpaq_bytes = int(mapping_zpaq["complete_persisted_bytes"])
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
    record_result = json.loads(record_result_path.read_text())
    if record_result["canonical_input_sha256"] != sha256_file(input_path):
        raise RuntimeError("direct and record-node comparisons use different inputs")
    record_best_key = (
        "best_webgraph_bytes" if scope == "minimum" else "best_webgraph_bytes"
    )
    record_best_bytes = int(record_result[record_best_key])
    structural_win = int(best["complete_persisted_bytes"]) < record_best_bytes
    result: dict[str, object] = {
        "schema": schema,
        "scope": graph_input.scope,
        "official_revision": revision,
        "official_crate_version": registered["crate_version"],
        "source_tree_clean": source_tree_clean,
        "representation": "direct_unique_edges_v1",
        "representation_semantics": (
            "unique feature arcs plus ZPAQ-compressed reversible record-order, "
            "duplicate, table, pair, and feature mapping sidecar"
        ),
        "run_count_per_arm": 1,
        "partition_seed": int(contract["configuration"]["seed"]),
        "source_database_sha256": contract["input"]["sqlite"]["sha256"],
        "canonical_input_bytes": input_path.stat().st_size,
        "canonical_input_sha256": sha256_file(input_path),
        "records": len(graph_input.arcs),
        "arms": arms,
        "zpaq_baseline_bytes": int(record_result["zpaq_baseline_bytes"]),
        "zpaq_baseline_sha256": record_result["zpaq_baseline_sha256"],
        "record_node_baseline_bytes": record_best_bytes,
        "record_node_result_sha256": sha256_file(record_result_path),
        "best_direct_mode": best["mode"],
        "best_direct_bytes": int(best["complete_persisted_bytes"]),
        "direct_vs_record_delta_bytes": int(best["complete_persisted_bytes"])
        - record_best_bytes,
        "direct_vs_record_reduction_fraction": 1
        - int(best["complete_persisted_bytes"]) / record_best_bytes,
        "strict_structural_winner": structural_win,
        "expand_to_complete": structural_win if scope == "minimum" else False,
        "wall_seconds": time.time() - started,
        "timing_comparability": "not_registered_size_only_structural_audit",
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "production_promoted": False,
        "phone_accessed": False,
        "conclusion_scope": f"direct_unique_edges_{scope}_registered_grid",
        "family_global_optimum_claimed": False,
    }
    _write_and_log_result(
        result_path,
        result,
        run_name=f"webgraph-direct-{scope}",
    )
    print(
        f"WEBGRAPH_DIRECT_{scope.upper()}_RESULT_WRITTEN "
        f"best={best['complete_persisted_bytes']} "
        f"record={record_best_bytes} zpaq={result['zpaq_baseline_bytes']}",
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
            "webgraph-complete-scale-audit",
            "webgraph-direct-minimum",
            "webgraph-direct-complete",
            "worldpack-minimum",
            "worldpack-100mb",
            "worldpack-complete",
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
    elif args.stage == "webgraph-complete-scale-audit":
        run_webgraph_complete_scale_audit()
    elif args.stage == "webgraph-direct-minimum":
        run_webgraph_direct("minimum")
    elif args.stage == "webgraph-direct-complete":
        run_webgraph_direct("complete")
    elif args.stage == "worldpack-minimum":
        run_worldpack("minimum")
    elif args.stage == "worldpack-100mb":
        run_worldpack("approximately-100mb")
    elif args.stage == "worldpack-complete":
        run_worldpack("complete")
    else:
        raise SystemExit("select --write-manifest or a registered --stage")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
