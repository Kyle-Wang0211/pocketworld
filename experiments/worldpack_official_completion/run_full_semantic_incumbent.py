#!/usr/bin/env python3
"""Finalize the incumbent photo view inside the normalized semantic archive."""

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

from photo_semantic_layer import build_photo_layer_manifest
import run_benchmark
import run_semantic_complete
from worldpack import WorldPackReader
from worldpack_semantic_rewrite import RawAddition, rewrite_drop_add_raw_members


ROOT = Path(__file__).resolve().parent
PLR_ROOT = ROOT.parent / "plr_derived_brunsli_two_photo"
SOURCE_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-normalized-semantic-complete/capture.semantic.worldpack"
)
SOURCE_RESULT = ROOT / "results/worldpack-normalized-semantic-complete.json"
PHOTO_RESULT = ROOT / "results/worldpack-logical-photo-manifest.json"
JXL_BUILD_RESULT = PLR_ROOT / "results/libjxl-host-0.12.0-build.json"
DJXL = PLR_ROOT / "build/libjxl-host-0.12.0/out/tools/djxl"
PWA2_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-full-forest-complete/pwa2-full-forest.worldpack"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-full-semantic-incumbent"
)
ARCHIVE = RUN_ROOT / "capture.full-semantic.worldpack"
SEMANTIC_MANIFEST = RUN_ROOT / "semantic-manifest-v2.json"
RESULT = ROOT / "results/worldpack-full-semantic-incumbent.json"
SEMANTIC_MANIFEST_PATH = "__semantic__/manifest.json"
NESTED_DATABASE_PATH = "__semantic__/official_sfm_live.pwa2.worldpack"


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


def _load_inputs() -> tuple[dict[str, object], dict[str, object], dict[str, object]]:
    normalized = json.loads(SOURCE_RESULT.read_bytes())
    photos = json.loads(PHOTO_RESULT.read_bytes())
    jxl = json.loads(JXL_BUILD_RESULT.read_bytes())
    gates = {
        "schema": "pw_worldpack_normalized_semantic_complete_v1",
        "physical_sqlite_member_present": False,
        "database_page_history_preserved": False,
        "database_all_cells_equal": 1,
        "database_all_rows_and_order_equal": 1,
        "materialized_sqlite_integrity_ok": 1,
        "random_reads_exact": 1,
        "corruption_rejected": 1,
        "source_unchanged": 1,
    }
    for key, expected in gates.items():
        if normalized.get(key) != expected:
            raise RuntimeError(f"normalized archive evidence gate failed: {key}")
    if (
        SOURCE_ARCHIVE.stat().st_size != normalized["complete_persisted_bytes"]
        or _sha256(SOURCE_ARCHIVE) != normalized["archive_sha256"]
    ):
        raise RuntimeError("normalized source archive identity changed")
    if (
        photos.get("schema") != "pw_worldpack_logical_photo_manifest_v1"
        or photos.get("logical_photo_count") != 155
        or photos.get("source_unchanged") != 1
    ):
        raise RuntimeError("logical photo evidence gate failed")
    if (
        jxl.get("schema") != "pw_plr_libjxl_host_build_v1"
        or jxl.get("version") != "0.12.0"
        or _sha256(DJXL) != jxl.get("djxl_sha256")
    ):
        raise RuntimeError("pinned JXL decoder identity changed")
    return normalized, photos, jxl


def _restore_original_photos(
    reader: WorldPackReader,
    photo_document: dict[str, object],
) -> tuple[int, int]:
    exact_bytes = 0
    exact_sha = 0
    photo_work = RUN_ROOT / "photo-restore"
    photo_work.mkdir(parents=True, exist_ok=True)
    for ordinal, record in enumerate(photo_document["photos"], start=1):
        stored = photo_work / "stored.bin"
        restored = photo_work / "restored.jpg"
        stored.unlink(missing_ok=True)
        restored.unlink(missing_ok=True)
        reader.extract_member(str(record["storage_path"]), stored)
        if (
            stored.stat().st_size != int(record["storage_bytes"])
            or _sha256(stored) != record["storage_sha256"]
        ):
            raise RuntimeError(f"stored photo changed: {record['storage_path']}")
        if record["storage_codec"] == "jpeg_original":
            shutil.copyfile(stored, restored)
        elif record["storage_codec"] == "jxl_0_12_0_exact_jpeg":
            subprocess.run(
                [
                    str(DJXL),
                    "--output_format=jpeg",
                    str(stored),
                    str(restored),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        else:
            raise RuntimeError(f"unknown photo codec: {record['storage_codec']}")
        expected = Path(str(record["logical_jpeg_path"]))
        if (
            expected.stat().st_size != int(record["logical_bytes"])
            or _sha256(expected) != record["logical_sha256"]
        ):
            raise RuntimeError(f"logical JPEG evidence changed: {record['logical_path']}")
        if restored.read_bytes() == expected.read_bytes():
            exact_bytes += 1
        if _sha256(restored) == record["logical_sha256"]:
            exact_sha += 1
        if ordinal % 10 == 0 or ordinal == len(photo_document["photos"]):
            print(f"FULL_SEMANTIC_PHOTO_RESTORE {ordinal}/155", flush=True)
    shutil.rmtree(photo_work)
    return exact_bytes, exact_sha


def main() -> None:
    if RESULT.exists():
        raise FileExistsError("full semantic incumbent result already exists")
    started = time.monotonic()
    normalized, photos, _ = _load_inputs()
    frozen_manifest = run_benchmark._load_frozen_manifest()
    contract = yaml.safe_load(run_benchmark.CONTRACT_PATH.read_text())
    source_root = Path(contract["input"]["capture_root"])
    codecs = [
        *run_benchmark._worldpack_codecs(require_similarity=True),
        run_semantic_complete._database_codec(),
    ]
    before = WorldPackReader(SOURCE_ARCHIVE, codecs=codecs)
    old_manifest = json.loads(before.read_member(SEMANTIC_MANIFEST_PATH))
    if old_manifest.get("schema") != "pw_worldpack_semantic_manifest_v1":
        raise RuntimeError("unexpected predecessor semantic manifest")
    photo_layer = build_photo_layer_manifest(photos)
    semantic_manifest: dict[str, object] = {
        "schema": "pw_worldpack_semantic_manifest_v2",
        "capture_id": frozen_manifest["capture_id"],
        "source_manifest_sha256": _sha256(run_benchmark.MANIFEST_PATH),
        "logical_output_member_count": frozen_manifest["entry_count"],
        "database": old_manifest["database"],
        "photo_layer": photo_layer,
        "terminal_photo_decision": "pending_plr_phase4",
    }
    _atomic_json(SEMANTIC_MANIFEST, semantic_manifest)
    written = rewrite_drop_add_raw_members(
        SOURCE_ARCHIVE,
        ARCHIVE,
        codecs=codecs,
        manifest_sha256=_sha256(SEMANTIC_MANIFEST),
        drop_paths={SEMANTIC_MANIFEST_PATH},
        additions=(RawAddition(SEMANTIC_MANIFEST_PATH, SEMANTIC_MANIFEST),),
    )
    reader = WorldPackReader(ARCHIVE, codecs=codecs)
    if "official_sfm_live.db" in reader.paths:
        raise RuntimeError("full semantic archive retained physical SQLite")
    if json.loads(reader.read_member(SEMANTIC_MANIFEST_PATH)) != semantic_manifest:
        raise RuntimeError("embedded semantic manifest changed")
    nested = RUN_ROOT / "database.pwa2.worldpack"
    reader.extract_member(NESTED_DATABASE_PATH, nested)
    if nested.stat().st_size != PWA2_ARCHIVE.stat().st_size or _sha256(nested) != _sha256(
        PWA2_ARCHIVE
    ):
        raise RuntimeError("verified normalized database payload changed")
    nested.unlink()
    exact_bytes, exact_sha = _restore_original_photos(reader, photos)
    if exact_bytes != 155 or exact_sha != 155:
        raise RuntimeError("one or more logical original JPEGs changed")

    before_by_path = {entry.path: entry for entry in before.entries}
    reused = 0
    for entry in reader.entries:
        old = before_by_path.get(entry.path)
        if entry.path != SEMANTIC_MANIFEST_PATH and old is not None:
            if (
                entry.payload_bytes != old.payload_bytes
                or entry.payload_sha256 != old.payload_sha256
                or entry.codec_id != old.codec_id
            ):
                raise RuntimeError(f"unrelated payload changed: {entry.path}")
            reused += 1
    if reused != 322:
        raise RuntimeError(f"expected 322 reused payloads, found {reused}")

    random_paths = [
        reader.paths[index]
        for index in sorted(
            {numerator * (len(reader.paths) - 1) // 7 for numerator in range(8)}
        )
    ]
    random_exact = True
    for path in random_paths:
        payload, touched = reader.read_member_with_trace(path)
        if len(touched) > 1:
            random_exact = False
        if path == SEMANTIC_MANIFEST_PATH:
            expected = SEMANTIC_MANIFEST.read_bytes()
        elif path == NESTED_DATABASE_PATH:
            expected = PWA2_ARCHIVE.read_bytes()
        else:
            expected = (source_root / path).read_bytes()
        random_exact = random_exact and payload == expected
    corruption = run_benchmark._worldpack_corruption_probe(
        ARCHIVE, written, codecs, RUN_ROOT
    )
    source_unchanged = run_benchmark._verify_selected_sources(
        source_root, list(frozen_manifest["entries"])
    )
    if not random_exact or not corruption or not source_unchanged:
        raise RuntimeError("full semantic archive terminal gate failed")

    logical_original_project_bytes = (
        int(frozen_manifest["source_bytes"])
        - int(photos["current_stored_photo_bytes"])
        + int(photos["logical_original_jpeg_bytes"])
    )
    result: dict[str, object] = {
        "schema": "pw_worldpack_full_semantic_incumbent_v1",
        "archive_sha256": written.archive_sha256,
        "complete_persisted_bytes": written.complete_persisted_bytes,
        "frozen_current_project_bytes": frozen_manifest["source_bytes"],
        "logical_original_project_bytes": logical_original_project_bytes,
        "reduction_from_logical_original_project_fraction": (
            1 - written.complete_persisted_bytes / logical_original_project_bytes
        ),
        "compression_ratio_from_logical_original_project": (
            logical_original_project_bytes / written.complete_persisted_bytes
        ),
        "normalized_predecessor_bytes": normalized["complete_persisted_bytes"],
        "semantic_manifest_bytes": SEMANTIC_MANIFEST.stat().st_size,
        "semantic_manifest_sha256": _sha256(SEMANTIC_MANIFEST),
        "physical_sqlite_member_present": False,
        "database_page_history_preserved": False,
        "database_all_cells_equal": normalized["database_all_cells_equal"],
        "database_all_rows_and_order_equal": normalized[
            "database_all_rows_and_order_equal"
        ],
        "materialized_sqlite_integrity_ok": normalized[
            "materialized_sqlite_integrity_ok"
        ],
        "logical_photo_count": photos["logical_photo_count"],
        "logical_original_jpegs_byte_equal": exact_bytes,
        "logical_original_jpegs_sha256_equal": exact_sha,
        "logical_photo_identity_sha256": photos[
            "logical_photo_identity_sha256"
        ],
        "learned_photo_count": 0,
        "retained_incumbent_photo_count": photos["logical_photo_count"],
        "photo_terminal_decision": "pending_plr_phase4",
        "unrelated_payloads_reused": reused,
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
