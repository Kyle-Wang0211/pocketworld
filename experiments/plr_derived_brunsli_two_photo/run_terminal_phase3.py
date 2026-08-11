"""Run the selected model once on the frozen pair, without measuring JXL."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

import yaml

from pw_plr.model_storage import decode_model_storage, encode_model_storage
from pw_plr.terminal_accounting import account_terminal_pair


ROOT = Path(__file__).resolve().parent
SCOPE_PHOTO_COUNT = 96


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _terminal_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "OMP_NUM_THREADS": "1",
            "MKL_NUM_THREADS": "1",
            "VECLIB_MAXIMUM_THREADS": "1",
        }
    )
    return environment


def _run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=ROOT,
        env=_terminal_environment(),
        check=check,
        capture_output=True,
        text=True,
    )


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def _corruption_rejected(
    *,
    upstream: Path,
    model_artifact: Path,
    archive: Path,
    work: Path,
) -> bool:
    document = bytearray(archive.read_bytes())
    document[len(document) // 2] ^= 1
    corrupt = work / f"{archive.stem}.corrupt{archive.suffix}"
    corrupt.write_bytes(document)
    completed = _run(
        [
            sys.executable,
            str(ROOT / "run_terminal_photo_codec.py"),
            "decode",
            "--upstream",
            str(upstream),
            "--model-artifact",
            str(model_artifact),
            "--archive",
            str(corrupt),
            "--pwcf",
            str(work / f"{archive.stem}.corrupt.pwcf"),
            "--trace",
            str(work / f"{archive.stem}.corrupt.trace.json"),
        ],
        check=False,
    )
    return completed.returncode != 0


def _storage_candidates(
    *,
    artifact: Path,
    zstd: Path,
    zpaq: Path,
    output_directory: Path,
) -> list[dict[str, object]]:
    artifact_bytes = artifact.read_bytes()
    output_directory.mkdir(parents=True, exist_ok=True)
    candidates: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="model-storage-", dir=output_directory) as name:
        scratch = Path(name)
        arms = (
            ("raw", None),
            ("zstd_1_5_7_level22", "zstd"),
            ("zpaq_7_15_method5", "zpaq"),
        )
        for codec_id, codec in arms:
            encoded = scratch / f"{codec_id}.encoded"
            restored = scratch / f"{codec_id}.restored.pwmod"
            if codec is None:
                encoded.write_bytes(artifact_bytes)
            elif codec == "zstd":
                _run(
                    [
                        str(zstd),
                        "-q",
                        "--ultra",
                        "-22",
                        "-f",
                        str(artifact),
                        "-o",
                        str(encoded),
                    ]
                )
            else:
                _run([str(zpaq), "compress", str(artifact), str(encoded)])
            envelope = encode_model_storage(
                codec_id=codec_id,
                model_artifact=artifact_bytes,
                encoded_payload=encoded.read_bytes(),
            )
            storage_path = output_directory / f"{codec_id}.pwmst"
            storage_path.write_bytes(envelope)
            decoded = decode_model_storage(storage_path.read_bytes())
            encoded.write_bytes(decoded.encoded_payload)
            if codec is None:
                restored.write_bytes(decoded.encoded_payload)
            elif codec == "zstd":
                _run(
                    [
                        str(zstd),
                        "-q",
                        "-d",
                        "-f",
                        str(encoded),
                        "-o",
                        str(restored),
                    ]
                )
            else:
                _run([str(zpaq), "decompress", str(encoded), str(restored)])
            exact = restored.read_bytes() == artifact_bytes
            if (
                not exact
                or decoded.model_bytes != len(artifact_bytes)
                or decoded.model_sha256 != hashlib.sha256(artifact_bytes).hexdigest()
            ):
                raise RuntimeError(f"model storage round-trip failed: {codec_id}")
            candidates.append(
                {
                    "codec_id": codec_id,
                    "complete_persisted_bytes": storage_path.stat().st_size,
                    "storage_sha256": _sha256(storage_path),
                    "encoded_payload_bytes": len(decoded.encoded_payload),
                    "model_artifact_bytes": len(artifact_bytes),
                    "model_artifact_sha256": decoded.model_sha256,
                    "byte_equal": True,
                    "sha256_equal": True,
                    "path": str(storage_path),
                }
            )
    return candidates


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selection", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--input-manifest", type=Path, required=True)
    parser.add_argument("--phase1", type=Path, required=True)
    parser.add_argument("--runs-directory", type=Path, required=True)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--adapter", type=Path, required=True)
    parser.add_argument("--zstd", type=Path, required=True)
    parser.add_argument("--zpaq", type=Path, required=True)
    parser.add_argument("--work-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if arguments.output.exists():
        raise FileExistsError("terminal Phase 3 result already exists; rerun forbidden")
    started = time.monotonic()
    selection = json.loads(arguments.selection.read_bytes())
    config = yaml.safe_load(arguments.config.read_bytes())
    manifest = yaml.safe_load(arguments.input_manifest.read_bytes())
    phase1 = json.loads(arguments.phase1.read_bytes())
    selected_arm = str(selection["selected_arm"])
    checkpoint = arguments.runs_directory / selected_arm / "best.pt"
    if _sha256(checkpoint) != selection["selected_checkpoint_sha256"]:
        raise RuntimeError("selected checkpoint identity changed")
    if phase1.get("status") != "phase_1_exact_container_passed":
        raise RuntimeError("Phase 1 exact container evidence is absent")
    arms = {str(arm["id"]): arm for arm in config["model_arms"]}
    if selected_arm not in arms:
        raise RuntimeError("selected arm is absent from frozen config")
    arguments.work_directory.mkdir(parents=True, exist_ok=True)
    input_by_role = {str(item["role"]): item for item in manifest["inputs"]}
    phase1_by_role = {str(item["role"]): item for item in phase1["inputs"]}
    role_results: list[dict[str, object]] = []
    artifacts: list[Path] = []
    for role in ("A", "B"):
        source = Path(input_by_role[role]["path"])
        if (
            source.stat().st_size != int(input_by_role[role]["bytes"])
            or _sha256(source) != input_by_role[role]["sha256"]
        ):
            raise RuntimeError(f"frozen source identity changed: {role}")
        coefficients = ROOT / "results/work/training-coefficients" / f"{role}.pwtj"
        side = ROOT / "results/work/v0.1" / role / f"{role}.pwbs"
        if (
            side.stat().st_size != int(phase1_by_role[role]["side_bytes"])
            or _sha256(side) != phase1_by_role[role]["side_sha256"]
        ):
            raise RuntimeError(f"Phase 1 side identity changed: {role}")
        role_directory = arguments.work_directory / role
        role_directory.mkdir(exist_ok=True)
        archive = role_directory / f"{role}.pwpa"
        artifact = role_directory / "model.pwmod"
        encode_trace = role_directory / "encode-trace.json"
        decode_trace = role_directory / "decode-trace.json"
        restored = role_directory / f"{role}.restored.jpg"
        _run(
            [
                sys.executable,
                str(ROOT / "run_terminal_photo_codec.py"),
                "encode",
                "--checkpoint",
                str(checkpoint),
                "--config",
                str(arguments.config),
                "--upstream",
                str(arguments.upstream),
                "--coefficients",
                str(coefficients),
                "--archive",
                str(archive),
                "--model-artifact",
                str(artifact),
                "--trace",
                str(encode_trace),
            ]
        )
        _run(
            [
                sys.executable,
                str(ROOT / "run_terminal_photo_codec.py"),
                "decode",
                "--upstream",
                str(arguments.upstream),
                "--model-artifact",
                str(artifact),
                "--archive",
                str(archive),
                "--pwcf",
                str(role_directory / f"{role}.restored.pwcf"),
                "--trace",
                str(decode_trace),
                "--side",
                str(side),
                "--adapter",
                str(arguments.adapter),
                "--jpeg",
                str(restored),
            ]
        )
        byte_equal = restored.read_bytes() == source.read_bytes()
        sha_equal = _sha256(restored) == input_by_role[role]["sha256"]
        trace_equal = encode_trace.read_bytes() == decode_trace.read_bytes()
        corruption = _corruption_rejected(
            upstream=arguments.upstream,
            model_artifact=artifact,
            archive=archive,
            work=role_directory,
        )
        if not byte_equal or not sha_equal or not trace_equal or not corruption:
            raise RuntimeError(f"terminal exactness gate failed: {role}")
        artifacts.append(artifact)
        role_results.append(
            {
                "role": role,
                "source_bytes": source.stat().st_size,
                "source_sha256": _sha256(source),
                "photo_archive_bytes": archive.stat().st_size,
                "photo_archive_sha256": _sha256(archive),
                "side_bytes": side.stat().st_size,
                "side_sha256": _sha256(side),
                "restored_bytes": restored.stat().st_size,
                "restored_sha256": _sha256(restored),
                "byte_equal": True,
                "sha256_equal": True,
                "integer_cdf_trace_equal": True,
                "integer_cdf_trace_sha256": _sha256(encode_trace),
                "corruption_rejected": True,
            }
        )
    if artifacts[0].read_bytes() != artifacts[1].read_bytes():
        raise RuntimeError("separate encoders produced different deployment models")
    storage_candidates = _storage_candidates(
        artifact=artifacts[0],
        zstd=arguments.zstd,
        zpaq=arguments.zpaq,
        output_directory=arguments.work_directory / "model-storage",
    )
    selected_storage = min(
        storage_candidates,
        key=lambda item: (int(item["complete_persisted_bytes"]), item["codec_id"]),
    )
    accounting = account_terminal_pair(
        photo_archive_bytes=[
            int(item["photo_archive_bytes"]) for item in role_results
        ],
        side_bytes=[int(item["side_bytes"]) for item in role_results],
        complete_model_storage_bytes=int(
            selected_storage["complete_persisted_bytes"]
        ),
        scope_photo_count=SCOPE_PHOTO_COUNT,
    )
    result: dict[str, object] = {
        "schema": "pw_plr_terminal_phase3_result_v1",
        "status": "phase3_selected_model_exact_pair_complete",
        "selected_arm": selected_arm,
        "selected_checkpoint_sha256": _sha256(checkpoint),
        "scope": "scope2_self_contained_per_project",
        "scope_photo_count": SCOPE_PHOTO_COUNT,
        "decoder_sequential_passes": 22,
        "terminal_device": "cpu",
        "terminal_threads": 1,
        "encoder_decoder_processes": "separate",
        "roles": role_results,
        "model_storage_candidates": storage_candidates,
        "selected_model_storage_codec": selected_storage["codec_id"],
        "complete_model_storage_bytes": selected_storage[
            "complete_persisted_bytes"
        ],
        "complete_model_storage_sha256": selected_storage["storage_sha256"],
        "photo_stream_bytes": accounting.photo_stream_bytes,
        "accounted_model_bytes": accounting.accounted_model_bytes,
        "total_accounted_bytes": accounting.total_accounted_bytes,
        "jxl_measured": False,
        "terminal_winner_declared": False,
        "source_unchanged": all(
            _sha256(Path(input_by_role[role]["path"]))
            == input_by_role[role]["sha256"]
            for role in ("A", "B")
        ),
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(arguments.output, result)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
