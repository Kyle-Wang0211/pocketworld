#!/usr/bin/env python3
"""Interruptible full-project PLR stream encoding after the frozen Phase 4 gate."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

from full_photo_expansion import learned_member_paths, phase4_allows_full_project
from photo_candidate_ledger import PhotoCandidateLedger
from photo_semantic_selection import PhotoStreamCandidate, select_photo_streams
import run_benchmark
import run_semantic_complete
from worldpack import WorldPackEntry, WorldPackReader


ROOT = Path(__file__).resolve().parent
PLR_ROOT = ROOT.parent / "plr_derived_brunsli_two_photo"
LOGICAL_PHOTOS = ROOT / "results/worldpack-logical-photo-manifest-v2.json"
PHASE3 = PLR_ROOT / "results/terminal-phase3.json"
PHASE4 = PLR_ROOT / "results/terminal-phase4.json"
MODEL_ARTIFACT = PLR_ROOT / "results/terminal-phase3-work/A/model.pwmod"
ADAPTER = PLR_ROOT / "build/v0.1/pw_brunsli_side_adapter"
EXTRACTOR = PLR_ROOT / "build/v0.1/pw_brunsli_training_extract"
UPSTREAM = PLR_ROOT / "build/plr-upstream"
PLR_PYTHON = PLR_ROOT / ".venv/bin/python"
TERMINAL_CODEC = PLR_ROOT / "run_terminal_photo_codec.py"
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-full-photo-candidate"
)
STREAM_ROOT = RUN_ROOT / "streams"
PROGRESS = RUN_ROOT / "progress.json"
RESULT = ROOT / "results/worldpack-full-photo-candidate-streams.json"
INCUMBENT_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-lepton-normalized-incumbent/capture.lepton-normalized.worldpack"
)
INCUMBENT_RESULT = ROOT / "results/worldpack-lepton-normalized-incumbent.json"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _run(
    command: list[str],
    *,
    terminal_cpu: bool = False,
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    if terminal_cpu:
        environment.update(
            {
                "OMP_NUM_THREADS": "1",
                "MKL_NUM_THREADS": "1",
                "VECLIB_MAXIMUM_THREADS": "1",
            }
        )
    return subprocess.run(
        command,
        cwd=PLR_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def _resolve_phase3_path(value: object) -> Path:
    path = Path(str(value))
    return path if path.is_absolute() else PLR_ROOT / path


def _verify_completed_artifacts(record: dict[str, object]) -> None:
    if record.get("eligible_plr_420") is not True:
        return
    for prefix in ("photo_archive", "side", "integer_cdf_trace"):
        path = Path(str(record[f"{prefix}_path"]))
        if (
            not path.is_file()
            or path.stat().st_size != int(record[f"{prefix}_bytes"])
            or _sha256(path) != record[f"{prefix}_sha256"]
        ):
            raise RuntimeError(f"committed photo artifact changed: {prefix}")


def _encode_one(
    photo: dict[str, object],
    *,
    model_artifact_sha256: str,
    incumbent_entry: WorldPackEntry,
) -> dict[str, object]:
    logical_path = str(photo["logical_path"])
    source = Path(str(photo["logical_jpeg_path"]))
    if (
        source.stat().st_size != int(photo["logical_bytes"])
        or _sha256(source) != photo["logical_sha256"]
    ):
        raise RuntimeError(f"logical photo source changed: {logical_path}")
    probe = json.loads(_run([str(EXTRACTOR), "--probe", str(source)]).stdout)
    base: dict[str, object] = {
        "logical_path": logical_path,
        "source_bytes": int(photo["logical_bytes"]),
        "source_sha256": str(photo["logical_sha256"]),
        "incumbent_storage_path": str(photo["storage_path"]),
        "incumbent_source_bytes": int(photo["storage_bytes"]),
        "incumbent_source_sha256": str(photo["storage_sha256"]),
        "incumbent_worldpack_codec": incumbent_entry.codec_id,
        "incumbent_worldpack_payload_bytes": incumbent_entry.payload_bytes,
        "incumbent_worldpack_payload_sha256": incumbent_entry.payload_sha256,
        "eligible_plr_420": bool(probe["eligible_plr_420"]),
    }
    if not probe["eligible_plr_420"]:
        return {**base, "status": "retained_ineligible_geometry"}

    members = learned_member_paths(logical_path)
    identity = hashlib.sha256(logical_path.encode("utf-8")).hexdigest()[:24]
    directory = STREAM_ROOT / identity
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    side = directory / "photo.pwbs"
    source_pwcf = directory / "source.pwcf"
    coefficients = directory / "source.pwtj"
    archive = directory / "photo.pwpa"
    encode_trace = directory / "encode-trace.json"
    decode_trace = directory / "decode-trace.json"
    restored_pwcf = directory / "restored.pwcf"
    restored_jpeg = directory / "restored.jpg"
    _run([str(ADAPTER), "extract", str(source), str(side), str(source_pwcf)])
    _run([str(EXTRACTOR), str(source), str(coefficients)])
    _run(
        [
            str(PLR_PYTHON),
            str(TERMINAL_CODEC),
            "encode-artifact",
            "--upstream",
            str(UPSTREAM),
            "--model-artifact",
            str(MODEL_ARTIFACT),
            "--coefficients",
            str(coefficients),
            "--archive",
            str(archive),
            "--trace",
            str(encode_trace),
        ],
        terminal_cpu=True,
    )
    _run(
        [
            str(PLR_PYTHON),
            str(TERMINAL_CODEC),
            "decode",
            "--upstream",
            str(UPSTREAM),
            "--model-artifact",
            str(MODEL_ARTIFACT),
            "--archive",
            str(archive),
            "--pwcf",
            str(restored_pwcf),
            "--trace",
            str(decode_trace),
            "--side",
            str(side),
            "--adapter",
            str(ADAPTER),
            "--jpeg",
            str(restored_jpeg),
        ],
        terminal_cpu=True,
    )
    if (
        restored_jpeg.read_bytes() != source.read_bytes()
        or _sha256(restored_jpeg) != photo["logical_sha256"]
        or encode_trace.read_bytes() != decode_trace.read_bytes()
        or _sha256(MODEL_ARTIFACT) != model_artifact_sha256
    ):
        raise RuntimeError(f"terminal exactness failed: {logical_path}")
    result = {
        **base,
        "status": "plr_stream_exact",
        "photo_archive_member_path": members.photo_archive,
        "photo_archive_path": str(archive),
        "photo_archive_bytes": archive.stat().st_size,
        "photo_archive_sha256": _sha256(archive),
        "side_member_path": members.side,
        "side_path": str(side),
        "side_bytes": side.stat().st_size,
        "side_sha256": _sha256(side),
        "integer_cdf_trace_path": str(encode_trace),
        "integer_cdf_trace_bytes": encode_trace.stat().st_size,
        "integer_cdf_trace_sha256": _sha256(encode_trace),
        "byte_equal": True,
        "sha256_equal": True,
        "integer_cdf_trace_equal": True,
        "encoder_decoder_processes": "separate",
        "terminal_threads": 1,
    }
    for temporary in (
        source_pwcf,
        coefficients,
        decode_trace,
        restored_pwcf,
        restored_jpeg,
    ):
        temporary.unlink(missing_ok=True)
    return result


def main() -> None:
    if RESULT.exists():
        raise FileExistsError("full photo candidate result already exists")
    started = time.monotonic()
    phase3 = json.loads(PHASE3.read_bytes())
    phase4 = json.loads(PHASE4.read_bytes())
    photos = json.loads(LOGICAL_PHOTOS.read_bytes())
    incumbent_result = json.loads(INCUMBENT_RESULT.read_bytes())
    if (
        phase3.get("schema") != "pw_plr_terminal_phase3_result_v1"
        or phase3.get("status") != "phase3_selected_model_exact_pair_complete"
        or phase4.get("schema") != "pw_plr_terminal_phase4_result_v1"
        or photos.get("schema") != "pw_worldpack_logical_photo_manifest_v2"
        or photos.get("logical_photo_count") != 155
        or incumbent_result.get("schema")
        != "pw_worldpack_lepton_normalized_incumbent_v1"
        or INCUMBENT_ARCHIVE.stat().st_size
        != int(incumbent_result["complete_persisted_bytes"])
        or _sha256(INCUMBENT_ARCHIVE) != incumbent_result["archive_sha256"]
    ):
        raise RuntimeError("full photo expansion evidence gate failed")
    if not phase4_allows_full_project(phase4, photo_count=155):
        raise RuntimeError("Phase 4 did not authorize the 155-photo expansion")
    selected_storage = next(
        candidate
        for candidate in phase3["model_storage_candidates"]
        if candidate["codec_id"] == phase3["selected_model_storage_codec"]
    )
    model_storage = _resolve_phase3_path(selected_storage["path"])
    if (
        model_storage.stat().st_size != int(phase3["complete_model_storage_bytes"])
        or _sha256(model_storage) != phase3["complete_model_storage_sha256"]
        or _sha256(MODEL_ARTIFACT) != selected_storage["model_artifact_sha256"]
    ):
        raise RuntimeError("selected terminal model identity changed")
    for executable in (ADAPTER, EXTRACTOR, PLR_PYTHON):
        if not executable.is_file():
            raise FileNotFoundError(executable)
    identity = {
        "phase3_sha256": _sha256(PHASE3),
        "phase4_sha256": _sha256(PHASE4),
        "logical_photo_manifest_sha256": _sha256(LOGICAL_PHOTOS),
        "logical_photo_identity_sha256": photos["logical_photo_identity_sha256"],
        "model_artifact_sha256": selected_storage["model_artifact_sha256"],
        "model_storage_sha256": phase3["complete_model_storage_sha256"],
        "adapter_sha256": _sha256(ADAPTER),
        "extractor_sha256": _sha256(EXTRACTOR),
        "incumbent_archive_sha256": incumbent_result["archive_sha256"],
    }
    ledger = PhotoCandidateLedger.open(PROGRESS, identity=identity)
    incumbent_reader = WorldPackReader(
        INCUMBENT_ARCHIVE,
        codecs=[
            *run_benchmark._worldpack_codecs(require_similarity=True),
            run_semantic_complete._database_codec(),
        ],
    )
    incumbent_entries = {entry.path: entry for entry in incumbent_reader.entries}
    ordered_photos = sorted(
        photos["photos"], key=lambda item: str(item["logical_path"]).encode()
    )
    for ordinal, photo in enumerate(ordered_photos, start=1):
        logical_path = str(photo["logical_path"])
        completed = ledger.get(logical_path)
        if completed is None:
            storage_path = str(photo["storage_path"])
            incumbent_entry = incumbent_entries.get(storage_path)
            if (
                incumbent_entry is None
                or incumbent_entry.original_bytes != int(photo["storage_bytes"])
                or incumbent_entry.original_sha256 != photo["storage_sha256"]
            ):
                raise RuntimeError(f"incumbent photo member changed: {storage_path}")
            completed = _encode_one(
                photo,
                model_artifact_sha256=str(selected_storage["model_artifact_sha256"]),
                incumbent_entry=incumbent_entry,
            )
            ledger.record(logical_path, completed)
        else:
            _verify_completed_artifacts(completed)
        print(f"FULL_PHOTO_CANDIDATE {ordinal}/155", flush=True)

    records = [ledger.get(str(photo["logical_path"])) for photo in ordered_photos]
    if any(record is None for record in records):
        raise RuntimeError("full photo ledger is incomplete")
    candidates = tuple(
        PhotoStreamCandidate(
            logical_path=str(record["logical_path"]),
            incumbent_storage_path=str(record["incumbent_storage_path"]),
            incumbent_bytes=int(record["incumbent_worldpack_payload_bytes"]),
            learned_photo_bytes=(
                int(record["photo_archive_bytes"])
                if record["eligible_plr_420"]
                else int(record["incumbent_worldpack_payload_bytes"])
            ),
            exact_side_bytes=(
                int(record["side_bytes"]) if record["eligible_plr_420"] else 0
            ),
        )
        for record in records
    )
    selection = select_photo_streams(
        candidates,
        model_storage_bytes=int(phase3["complete_model_storage_bytes"]),
    )
    source_unchanged = all(
        Path(str(photo["logical_jpeg_path"])).stat().st_size
        == int(photo["logical_bytes"])
        and _sha256(Path(str(photo["logical_jpeg_path"])))
        == photo["logical_sha256"]
        for photo in ordered_photos
    )
    if not source_unchanged:
        raise RuntimeError("logical photo source changed during full encoding")
    result: dict[str, object] = {
        "schema": "pw_worldpack_full_photo_candidate_streams_v1",
        "status": (
            "candidate_payload_winner_before_worldpack_framing"
            if selection.use_shared_model
            else "candidate_payload_loser_keep_incumbent"
        ),
        "photo_count": len(records),
        "eligible_plr_photo_count": sum(
            bool(record["eligible_plr_420"]) for record in records
        ),
        "exact_roundtrip_photo_count": sum(
            bool(record.get("byte_equal")) for record in records
        ),
        "integer_cdf_trace_equal_photo_count": sum(
            bool(record.get("integer_cdf_trace_equal")) for record in records
        ),
        "selected_learned_photo_count": len(selection.selected_logical_paths),
        "retained_incumbent_photo_count": len(selection.retained_logical_paths),
        "selected_logical_paths": list(selection.selected_logical_paths),
        "incumbent_payload_bytes": selection.incumbent_payload_bytes,
        "candidate_payload_bytes": selection.candidate_payload_bytes,
        "payload_savings_bytes": selection.payload_savings_bytes,
        "use_shared_model": selection.use_shared_model,
        "complete_model_storage_bytes": (
            phase3["complete_model_storage_bytes"]
            if selection.use_shared_model
            else 0
        ),
        "complete_model_storage_sha256": (
            phase3["complete_model_storage_sha256"]
            if selection.use_shared_model
            else None
        ),
        "progress_sha256": _sha256(PROGRESS),
        "source_unchanged": int(source_unchanged),
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(RESULT, result)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
