#!/usr/bin/env python3
"""Issue the final full semantic archive verdict after the PLR terminal route."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

import yaml

from full_photo_expansion import phase4_allows_full_project
from photo_semantic_layer import build_photo_layer_manifest
from photo_terminal_plan import build_terminal_photo_rewrite_plan
import run_benchmark
import run_semantic_complete
from worldpack import WorldPackReader
from worldpack_semantic_rewrite import RawAddition, rewrite_drop_add_raw_members


ROOT = Path(__file__).resolve().parent
PLR_ROOT = ROOT.parent / "plr_derived_brunsli_two_photo"
INCUMBENT_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-lepton-normalized-incumbent/capture.lepton-normalized.worldpack"
)
INCUMBENT_RESULT = ROOT / "results/worldpack-lepton-normalized-incumbent.json"
LOGICAL_PHOTOS = ROOT / "results/worldpack-logical-photo-manifest-v2.json"
PHOTO_STREAM_RESULT = ROOT / "results/worldpack-full-photo-candidate-streams.json"
PHOTO_PROGRESS = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-full-photo-candidate/progress.json"
)
PHASE3 = PLR_ROOT / "results/terminal-phase3.json"
PHASE4 = PLR_ROOT / "results/terminal-phase4.json"
MODEL_ARTIFACT = PLR_ROOT / "results/terminal-phase3-work/A/model.pwmod"
RESTORE_MODEL = PLR_ROOT / "run_restore_model_storage.py"
TERMINAL_CODEC = PLR_ROOT / "run_terminal_photo_codec.py"
PLR_PYTHON = PLR_ROOT / ".venv/bin/python"
UPSTREAM = PLR_ROOT / "build/plr-upstream"
ADAPTER = PLR_ROOT / "build/v0.1/pw_brunsli_side_adapter"
DJXL = PLR_ROOT / "build/libjxl-host-0.12.0/out/tools/djxl"
LEPTON = Path(
    "/private/tmp/pw_worldpack_lepton_host_target.0.5.8/release/lepton_jpeg_util"
)
LEPTON_SHA256 = (
    "3173002ec9b63ea11de48c6c5c48a653d0060abb024100bf5865a7049c8a907e"
)
ZSTD = Path("/opt/homebrew/bin/zstd")
ZPAQ = Path(
    "/private/tmp/pw_worldpack_zpaq_adapter_bin.v715/worldpack_zpaq_adapter"
)
PWA2_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-full-forest-complete/pwa2-full-forest.worldpack"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-full-semantic-terminal"
)
CANDIDATE_ARCHIVE = RUN_ROOT / "capture.terminal-candidate.worldpack"
SEMANTIC_MANIFEST = RUN_ROOT / "semantic-manifest-v3.json"
RESULT = ROOT / "results/worldpack-full-semantic-terminal.json"
SEMANTIC_MANIFEST_PATH = "__semantic__/manifest.json"
NESTED_DATABASE_PATH = "__semantic__/official_sfm_live.pwa2.worldpack"
MODEL_MEMBER_PATH = "__semantic__/photos/model.pwmst"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def _run(command: list[str], *, terminal_cpu: bool = False) -> None:
    environment = os.environ.copy()
    if terminal_cpu:
        environment.update(
            {
                "OMP_NUM_THREADS": "1",
                "MKL_NUM_THREADS": "1",
                "VECLIB_MAXIMUM_THREADS": "1",
            }
        )
    subprocess.run(
        command,
        cwd=PLR_ROOT,
        env=environment,
        check=True,
        capture_output=True,
        text=True,
    )


def _write_incumbent_verdict(
    incumbent: dict[str, object],
    phase4: dict[str, object],
    *,
    reason: str,
) -> None:
    result: dict[str, object] = {
        "schema": "pw_worldpack_full_semantic_terminal_v1",
        "terminal_state": reason,
        "selected_photo_layer": "incumbent_exact_jpeg",
        "selected_archive_path": str(INCUMBENT_ARCHIVE),
        "selected_archive_bytes": incumbent["complete_persisted_bytes"],
        "selected_archive_sha256": incumbent["archive_sha256"],
        "candidate_archive_built": False,
        "candidate_archive_bytes": None,
        "candidate_archive_sha256": None,
        "logical_original_project_bytes": incumbent.get(
            "logical_original_project_bytes", 638_645_632
        ),
        "logical_photo_count": incumbent.get("logical_photo_count", 155),
        "logical_original_jpegs_byte_equal": incumbent[
            "logical_original_jpegs_byte_equal"
        ],
        "logical_original_jpegs_sha256_equal": incumbent[
            "logical_original_jpegs_sha256_equal"
        ],
        "database_all_cells_equal": incumbent["database_all_cells_equal"],
        "database_all_rows_and_order_equal": incumbent[
            "database_all_rows_and_order_equal"
        ],
        "materialized_sqlite_integrity_ok": incumbent[
            "materialized_sqlite_integrity_ok"
        ],
        "phase4_terminal_state": phase4["terminal_state"],
        "random_reads_exact": incumbent["random_reads_exact"],
        "corruption_rejected": incumbent["corruption_rejected"],
        "source_unchanged": incumbent["source_unchanged"],
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(RESULT, result)
    print(json.dumps(result, sort_keys=True), flush=True)


def _selected_model_storage(
    phase3: dict[str, object],
) -> tuple[Path, dict[str, object]]:
    selected = next(
        candidate
        for candidate in phase3["model_storage_candidates"]
        if candidate["codec_id"] == phase3["selected_model_storage_codec"]
    )
    path = Path(str(selected["path"]))
    if not path.is_absolute():
        path = PLR_ROOT / path
    if (
        path.stat().st_size != int(selected["complete_persisted_bytes"])
        or _sha256(path) != selected["storage_sha256"]
    ):
        raise RuntimeError("selected model storage identity changed")
    return path, selected


def _restore_model(reader: WorldPackReader, working: Path) -> Path:
    storage = working / "model.pwmst"
    artifact = working / "model.pwmod"
    reader.extract_member(MODEL_MEMBER_PATH, storage)
    _run(
        [
            str(PLR_PYTHON),
            str(RESTORE_MODEL),
            "--storage",
            str(storage),
            "--output",
            str(artifact),
            "--zstd",
            str(ZSTD),
            "--zpaq",
            str(ZPAQ),
        ]
    )
    if artifact.read_bytes() != MODEL_ARTIFACT.read_bytes():
        raise RuntimeError("archive model did not restore canonical artifact")
    return artifact


def _restore_photos(
    reader: WorldPackReader,
    photo_layer: dict[str, object],
    logical_document: dict[str, object],
    progress: dict[str, object],
) -> tuple[int, int, int]:
    logical_by_path = {
        str(photo["logical_path"]): photo for photo in logical_document["photos"]
    }
    completed = progress["completed"]
    exact_bytes = 0
    exact_sha = 0
    trace_equal = 0
    working = RUN_ROOT / "restore-work"
    if working.exists():
        shutil.rmtree(working)
    working.mkdir(parents=True)
    model_artifact = _restore_model(reader, working)
    for ordinal, item in enumerate(photo_layer["photos"], start=1):
        logical_path = str(item["logical_path"])
        source = Path(str(logical_by_path[logical_path]["logical_jpeg_path"]))
        restored = working / "restored.jpg"
        restored.unlink(missing_ok=True)
        if item["storage_kind"] == "plr_derived_exact_jpeg":
            archive = working / "photo.pwpa"
            side = working / "photo.pwbs"
            decoded_pwcf = working / "photo.pwcf"
            trace = working / "decode-trace.json"
            for path in (archive, side, decoded_pwcf, trace):
                path.unlink(missing_ok=True)
            members = item["storage_members"]
            reader.extract_member(str(members[0]["path"]), archive)
            reader.extract_member(str(members[1]["path"]), side)
            _run(
                [
                    str(PLR_PYTHON),
                    str(TERMINAL_CODEC),
                    "decode",
                    "--upstream",
                    str(UPSTREAM),
                    "--model-artifact",
                    str(model_artifact),
                    "--archive",
                    str(archive),
                    "--pwcf",
                    str(decoded_pwcf),
                    "--trace",
                    str(trace),
                    "--side",
                    str(side),
                    "--adapter",
                    str(ADAPTER),
                    "--jpeg",
                    str(restored),
                ],
                terminal_cpu=True,
            )
            expected_trace = Path(
                str(completed[logical_path]["integer_cdf_trace_path"])
            )
            if trace.read_bytes() == expected_trace.read_bytes():
                trace_equal += 1
        else:
            stored = working / "incumbent-photo"
            stored.unlink(missing_ok=True)
            member = item["storage_members"][0]
            reader.extract_member(str(member["path"]), stored)
            if member["codec"] == "jpeg_original":
                shutil.copyfile(stored, restored)
            elif member["codec"] == "jxl_0_12_0_exact_jpeg":
                _run(
                    [
                        str(DJXL),
                        "--output_format=jpeg",
                        str(stored),
                        str(restored),
                    ]
                )
            elif member["codec"] == "lepton_jpeg_0_5_8":
                _run(
                    [
                        str(LEPTON),
                        "--quiet",
                        "--overwrite",
                        str(stored),
                        str(restored),
                    ]
                )
            else:
                raise RuntimeError(f"unknown incumbent photo codec: {member['codec']}")
        if restored.read_bytes() == source.read_bytes():
            exact_bytes += 1
        if _sha256(restored) == item["logical_sha256"]:
            exact_sha += 1
        if ordinal % 10 == 0 or ordinal == len(photo_layer["photos"]):
            print(f"TERMINAL_SEMANTIC_PHOTO_RESTORE {ordinal}/155", flush=True)
    shutil.rmtree(working)
    return exact_bytes, exact_sha, trace_equal


def main() -> None:
    if RESULT.exists():
        raise FileExistsError("full semantic terminal result already exists")
    started = time.monotonic()
    incumbent = json.loads(INCUMBENT_RESULT.read_bytes())
    phase3 = json.loads(PHASE3.read_bytes())
    phase4 = json.loads(PHASE4.read_bytes())
    logical = json.loads(LOGICAL_PHOTOS.read_bytes())
    if (
        incumbent.get("schema") != "pw_worldpack_lepton_normalized_incumbent_v1"
        or phase3.get("schema") != "pw_plr_terminal_phase3_result_v1"
        or phase4.get("schema") != "pw_plr_terminal_phase4_result_v1"
        or _sha256(INCUMBENT_ARCHIVE) != incumbent["archive_sha256"]
        or INCUMBENT_ARCHIVE.stat().st_size != incumbent["complete_persisted_bytes"]
        or _sha256(LEPTON) != LEPTON_SHA256
    ):
        raise RuntimeError("terminal semantic input evidence gate failed")
    if not phase4_allows_full_project(phase4, photo_count=155):
        _write_incumbent_verdict(
            incumbent, phase4, reason="incumbent_final_phase4_did_not_expand"
        )
        return
    if not PHOTO_STREAM_RESULT.is_file():
        raise RuntimeError("authorized full photo stream experiment is incomplete")
    stream_result = json.loads(PHOTO_STREAM_RESULT.read_bytes())
    if stream_result.get("use_shared_model") is not True:
        _write_incumbent_verdict(
            incumbent, phase4, reason="incumbent_final_full_photo_payload_lost"
        )
        return

    progress = json.loads(PHOTO_PROGRESS.read_bytes())
    selected_paths = tuple(str(value) for value in stream_result["selected_logical_paths"])
    model_storage, model_candidate = _selected_model_storage(phase3)
    plan = build_terminal_photo_rewrite_plan(
        logical,
        progress_records=progress["completed"],
        selected_logical_paths=selected_paths,
        model_storage_path=model_storage,
        model_storage_codec=str(phase3["selected_model_storage_codec"]),
    )
    photo_layer = build_photo_layer_manifest(
        logical,
        learned_records=plan.learned_records,
        shared_model=plan.shared_model,
    )
    codecs = [
        *run_benchmark._worldpack_codecs(require_similarity=True),
        run_semantic_complete._database_codec(),
    ]
    before = WorldPackReader(INCUMBENT_ARCHIVE, codecs=codecs)
    predecessor_manifest = json.loads(before.read_member(SEMANTIC_MANIFEST_PATH))
    semantic_manifest: dict[str, object] = {
        "schema": "pw_worldpack_semantic_manifest_v3",
        "capture_id": predecessor_manifest["capture_id"],
        "source_manifest_sha256": predecessor_manifest["source_manifest_sha256"],
        "logical_output_member_count": predecessor_manifest[
            "logical_output_member_count"
        ],
        "database": predecessor_manifest["database"],
        "photo_layer": photo_layer,
        "terminal_photo_decision": "plr_full_project_candidate",
        "phase3_sha256": _sha256(PHASE3),
        "phase4_sha256": _sha256(PHASE4),
    }
    _atomic_json(SEMANTIC_MANIFEST, semantic_manifest)
    additions = (*plan.additions, RawAddition(SEMANTIC_MANIFEST_PATH, SEMANTIC_MANIFEST))
    written = rewrite_drop_add_raw_members(
        INCUMBENT_ARCHIVE,
        CANDIDATE_ARCHIVE,
        codecs=codecs,
        manifest_sha256=_sha256(SEMANTIC_MANIFEST),
        drop_paths=plan.drop_paths,
        additions=additions,
    )
    reader = WorldPackReader(CANDIDATE_ARCHIVE, codecs=codecs)
    if "official_sfm_live.db" in reader.paths:
        raise RuntimeError("terminal semantic archive retained physical SQLite")
    if any(path in reader.paths for path in plan.drop_paths - {SEMANTIC_MANIFEST_PATH}):
        raise RuntimeError("terminal semantic archive retained a replaced photo")
    nested = RUN_ROOT / "database.pwa2.worldpack"
    reader.extract_member(NESTED_DATABASE_PATH, nested)
    if nested.read_bytes() != PWA2_ARCHIVE.read_bytes():
        raise RuntimeError("normalized database payload changed")
    nested.unlink()
    exact_bytes, exact_sha, trace_equal = _restore_photos(
        reader, photo_layer, logical, progress
    )
    if exact_bytes != 155 or exact_sha != 155 or trace_equal != len(selected_paths):
        raise RuntimeError("terminal semantic photo exactness failed")

    frozen_manifest = run_benchmark._load_frozen_manifest()
    contract = yaml.safe_load(run_benchmark.CONTRACT_PATH.read_text())
    source_root = Path(contract["input"]["capture_root"])
    random_paths = [
        reader.paths[index]
        for index in sorted(
            {numerator * (len(reader.paths) - 1) // 7 for numerator in range(8)}
        )
    ]
    random_exact = True
    addition_sources = {addition.relative_path: addition.source_path for addition in additions}
    for path in random_paths:
        payload, touched = reader.read_member_with_trace(path)
        if len(touched) > 1:
            random_exact = False
        if path in addition_sources:
            expected = addition_sources[path].read_bytes()
        elif path == NESTED_DATABASE_PATH:
            expected = PWA2_ARCHIVE.read_bytes()
        else:
            expected = (source_root / path).read_bytes()
        random_exact = random_exact and payload == expected
    corruption = run_benchmark._worldpack_corruption_probe(
        CANDIDATE_ARCHIVE, written, codecs, RUN_ROOT
    )
    source_unchanged = run_benchmark._verify_selected_sources(
        source_root, list(frozen_manifest["entries"])
    )
    if not random_exact or not corruption or not source_unchanged:
        raise RuntimeError("terminal semantic outer archive gate failed")

    candidate_wins = written.complete_persisted_bytes < int(
        incumbent["complete_persisted_bytes"]
    )
    selected_archive = CANDIDATE_ARCHIVE if candidate_wins else INCUMBENT_ARCHIVE
    selected_bytes = (
        written.complete_persisted_bytes
        if candidate_wins
        else int(incumbent["complete_persisted_bytes"])
    )
    selected_sha = written.archive_sha256 if candidate_wins else incumbent["archive_sha256"]
    result: dict[str, object] = {
        "schema": "pw_worldpack_full_semantic_terminal_v1",
        "terminal_state": (
            "learned_photo_candidate_strict_full_archive_winner"
            if candidate_wins
            else "incumbent_final_after_full_archive_framing"
        ),
        "selected_photo_layer": (
            "plr_derived_exact_jpeg" if candidate_wins else "incumbent_exact_jpeg"
        ),
        "selected_archive_path": str(selected_archive),
        "selected_archive_bytes": selected_bytes,
        "selected_archive_sha256": selected_sha,
        "candidate_archive_built": True,
        "candidate_archive_bytes": written.complete_persisted_bytes,
        "candidate_archive_sha256": written.archive_sha256,
        "incumbent_archive_bytes": incumbent["complete_persisted_bytes"],
        "candidate_minus_incumbent_bytes": (
            written.complete_persisted_bytes
            - int(incumbent["complete_persisted_bytes"])
        ),
        "logical_original_project_bytes": incumbent.get(
            "logical_original_project_bytes", 638_645_632
        ),
        "reduction_from_logical_original_project_fraction": (
            1
            - selected_bytes
            / int(incumbent.get("logical_original_project_bytes", 638_645_632))
        ),
        "compression_ratio_from_logical_original_project": (
            int(incumbent.get("logical_original_project_bytes", 638_645_632))
            / selected_bytes
        ),
        "logical_photo_count": 155,
        "learned_photo_count": len(selected_paths),
        "logical_original_jpegs_byte_equal": exact_bytes,
        "logical_original_jpegs_sha256_equal": exact_sha,
        "integer_cdf_trace_equal_photo_count": trace_equal,
        "complete_model_storage_bytes": model_storage.stat().st_size,
        "complete_model_storage_sha256": _sha256(model_storage),
        "model_artifact_sha256": model_candidate["model_artifact_sha256"],
        "database_all_cells_equal": incumbent["database_all_cells_equal"],
        "database_all_rows_and_order_equal": incumbent[
            "database_all_rows_and_order_equal"
        ],
        "materialized_sqlite_integrity_ok": incumbent[
            "materialized_sqlite_integrity_ok"
        ],
        "phase4_terminal_state": phase4["terminal_state"],
        "random_read_count": len(random_paths),
        "random_reads_exact": int(random_exact),
        "corruption_rejected": int(corruption),
        "source_unchanged": int(source_unchanged),
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(RESULT, result)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
