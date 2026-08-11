#!/usr/bin/env python3
"""Build a complete WorldPack whose SQLite truth is normalized logical data."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import yaml

import run_benchmark
import run_semantic_complete
from worldpack import FileCodec, WorldPackReader
from worldpack_semantic_rewrite import RawAddition, rewrite_drop_add_raw_members


ROOT = Path(__file__).resolve().parent
CURRENT_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-semantic-complete/capture.worldpack"
)
CURRENT_RESULT = ROOT / "results/worldpack-semantic-complete.json"
PWA2_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-full-forest-complete/pwa2-full-forest.worldpack"
)
PWA2_RESULT = ROOT / "results/pwa2-full-forest-complete.json"
PWA2_VERIFIER = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-build/"
    "pwa2-pack-only/pwa2_verify_only"
)
ZPAQ = Path(
    "/private/tmp/pw_worldpack_zpaq_adapter_bin.v715/worldpack_zpaq_adapter"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-normalized-semantic-complete"
)
ARCHIVE = RUN_ROOT / "capture.semantic.worldpack"
SEMANTIC_MANIFEST = RUN_ROOT / "semantic-manifest.json"
RESULT = ROOT / "results/worldpack-normalized-semantic-complete.json"
DATABASE_PATH = "official_sfm_live.db"
NESTED_DATABASE_PATH = "__semantic__/official_sfm_live.pwa2.worldpack"
SEMANTIC_MANIFEST_PATH = "__semantic__/manifest.json"


def sha256_file(path: Path) -> str:
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


def _nested_zpaq_codec() -> FileCodec:
    def forbidden_encode(_: Path, __: Path) -> None:
        raise AssertionError("verified nested PWA2 archive must not be re-encoded")

    def decode(source: Path, destination: Path) -> None:
        subprocess.run(
            [str(ZPAQ), "decompress", str(source), str(destination)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    return FileCodec("zpaq_7_15_method5", forbidden_encode, decode)


def _verify_inputs() -> tuple[dict[str, object], dict[str, object]]:
    current = json.loads(CURRENT_RESULT.read_bytes())
    pwa2 = json.loads(PWA2_RESULT.read_bytes())
    if (
        current.get("schema") != "pw_worldpack_semantic_complete_result_v1"
        or current.get("all_members_byte_equal") != 1
        or current.get("sqlite_integrity_check") != "ok"
        or CURRENT_ARCHIVE.stat().st_size != current["complete_persisted_bytes"]
        or sha256_file(CURRENT_ARCHIVE) != current["archive_sha256"]
    ):
        raise RuntimeError("current complete archive evidence gate failed")
    required = {
        "schema": "pw_pwa2_full_forest_complete_result_v1",
        "all_cells_equal": 1,
        "all_rows_and_order_equal": 1,
        "all_tables_covered": 1,
        "materialized_sqlite_integrity_ok": 1,
        "random_reads_exact": 1,
        "corruption_rejected": 1,
        "source_unchanged": 1,
    }
    for key, expected in required.items():
        if pwa2.get(key) != expected:
            raise RuntimeError(f"PWA2 semantic evidence gate failed: {key}")
    if (
        PWA2_ARCHIVE.stat().st_size != pwa2["complete_persisted_bytes"]
        or sha256_file(PWA2_ARCHIVE) != pwa2["archive_sha256"]
    ):
        raise RuntimeError("PWA2 archive identity differs from evidence")
    return current, pwa2


def _restore_retained(
    reader: WorldPackReader,
    source_root: Path,
    manifest: dict[str, object],
    restored_root: Path,
) -> int:
    expected = {
        str(entry["path"]): entry
        for entry in manifest["entries"]
        if entry["path"] != DATABASE_PATH
    }
    exact = 0
    restored_root.mkdir(parents=True, exist_ok=True)
    for ordinal, (path, entry) in enumerate(expected.items(), start=1):
        destination = restored_root / path
        reader.extract_member(path, destination)
        if (
            destination.stat().st_size == int(entry["bytes"])
            and sha256_file(destination) == entry["sha256"]
            and (source_root / path).stat().st_size == int(entry["bytes"])
            and sha256_file(source_root / path) == entry["sha256"]
        ):
            exact += 1
        if ordinal % 20 == 0 or ordinal == len(expected):
            print(f"NORMALIZED_SEMANTIC_RESTORE {ordinal}/{len(expected)}", flush=True)
    return exact


def main() -> None:
    if RESULT.exists():
        raise FileExistsError("normalized semantic terminal result already exists")
    started = time.monotonic()
    current, pwa2 = _verify_inputs()
    frozen_manifest = run_benchmark._load_frozen_manifest()
    contract = yaml.safe_load(run_benchmark.CONTRACT_PATH.read_text())
    source_root = Path(contract["input"]["capture_root"])
    source_database = source_root / DATABASE_PATH
    RUN_ROOT.mkdir(parents=True, exist_ok=True)
    semantic_manifest: dict[str, object] = {
        "schema": "pw_worldpack_semantic_manifest_v1",
        "capture_id": frozen_manifest["capture_id"],
        "source_manifest_sha256": sha256_file(run_benchmark.MANIFEST_PATH),
        "logical_output_member_count": frozen_manifest["entry_count"],
        "retained_physical_members": frozen_manifest["entry_count"] - 1,
        "database": {
            "logical_output_path": DATABASE_PATH,
            "physical_sqlite_page_history_preserved": False,
            "source_bytes": pwa2["source_bytes"],
            "source_sha256_diagnostic_only": pwa2["source_sha256"],
            "source_logical_sha256": pwa2["source_logical_sha256"],
            "normalized_archive_path": NESTED_DATABASE_PATH,
            "normalized_archive_bytes": pwa2["complete_persisted_bytes"],
            "normalized_archive_sha256": pwa2["archive_sha256"],
            "normalized_member_count": pwa2["member_count"],
            "materializer": "pwa2_sqlite_logical_archive_v2",
        },
        "photo_layer": {
            "status": "incumbent_exact_members_pending_plr_phase4",
            "original_jpeg_byte_recovery_required": True,
        },
    }
    _atomic_json(SEMANTIC_MANIFEST, semantic_manifest)
    manifest_sha = sha256_file(SEMANTIC_MANIFEST)
    old_codecs = run_benchmark._worldpack_codecs(require_similarity=True)
    current_database_codec = run_semantic_complete._database_codec()
    codecs = [*old_codecs, current_database_codec]
    written = rewrite_drop_add_raw_members(
        CURRENT_ARCHIVE,
        ARCHIVE,
        codecs=codecs,
        manifest_sha256=manifest_sha,
        drop_paths={DATABASE_PATH},
        additions=(
            RawAddition(NESTED_DATABASE_PATH, PWA2_ARCHIVE),
            RawAddition(SEMANTIC_MANIFEST_PATH, SEMANTIC_MANIFEST),
        ),
    )
    reader = WorldPackReader(ARCHIVE, codecs=codecs)
    if DATABASE_PATH in reader.paths:
        raise RuntimeError("semantic archive retained physical SQLite truth")
    if reader.manifest_sha256 != manifest_sha:
        raise RuntimeError("semantic archive manifest identity mismatch")

    retained_root = RUN_ROOT / "restored-retained"
    retained_exact = _restore_retained(
        reader, source_root, frozen_manifest, retained_root
    )
    if retained_exact != 321:
        raise RuntimeError("one or more retained physical members changed")

    nested_copy = RUN_ROOT / "restored-database.pwa2.worldpack"
    reader.extract_member(NESTED_DATABASE_PATH, nested_copy)
    if nested_copy.read_bytes() != PWA2_ARCHIVE.read_bytes():
        raise RuntimeError("nested semantic database archive changed")
    database_members = RUN_ROOT / "restored-database-members"
    nested_reader = WorldPackReader(nested_copy, codecs=[_nested_zpaq_codec()])
    nested_reader.extract_all(database_members)
    materialized = RUN_ROOT / "materialized-official_sfm_live.db"
    completed = subprocess.run(
        [
            str(PWA2_VERIFIER),
            str(source_database),
            str(database_members),
            str(materialized),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    database_verification = json.loads(completed.stdout)
    if (
        database_verification["all_cells_equal"] != 1
        or database_verification["all_rows_and_order_equal"] != 1
        or database_verification["materialized_sqlite_integrity_ok"] != 1
        or database_verification["restored_logical_sha256"]
        != pwa2["source_logical_sha256"]
    ):
        raise RuntimeError("nested database materialization differs logically")

    random_paths = [
        reader.paths[index]
        for index in sorted(
            {numerator * (len(reader.paths) - 1) // 7 for numerator in range(8)}
        )
    ]
    random_exact = True
    for ordinal, path in enumerate(random_paths):
        payload, touched = reader.read_member_with_trace(path)
        if len(touched) > 1:
            random_exact = False
        if path == NESTED_DATABASE_PATH:
            expected = PWA2_ARCHIVE.read_bytes()
        elif path == SEMANTIC_MANIFEST_PATH:
            expected = SEMANTIC_MANIFEST.read_bytes()
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
        raise RuntimeError("semantic archive random/corruption/source gate failed")

    result: dict[str, object] = {
        "schema": "pw_worldpack_normalized_semantic_complete_v1",
        "source_bytes": frozen_manifest["source_bytes"],
        "logical_output_member_count": frozen_manifest["entry_count"],
        "stored_member_count": len(reader.paths),
        "complete_persisted_bytes": written.complete_persisted_bytes,
        "archive_sha256": written.archive_sha256,
        "manifest_sha256": manifest_sha,
        "current_best_size_archive_bytes": current["complete_persisted_bytes"],
        "semantic_cost_bytes": (
            written.complete_persisted_bytes - current["complete_persisted_bytes"]
        ),
        "compression_ratio": (
            frozen_manifest["source_bytes"] / written.complete_persisted_bytes
        ),
        "reduction_fraction": (
            1 - written.complete_persisted_bytes / frozen_manifest["source_bytes"]
        ),
        "physical_sqlite_member_present": False,
        "database_page_history_preserved": False,
        "database_normalized_archive_bytes": pwa2["complete_persisted_bytes"],
        "database_normalized_archive_sha256": pwa2["archive_sha256"],
        "database_source_logical_sha256": pwa2["source_logical_sha256"],
        "database_restored_logical_sha256": database_verification[
            "restored_logical_sha256"
        ],
        "database_all_cells_equal": database_verification["all_cells_equal"],
        "database_all_rows_and_order_equal": database_verification[
            "all_rows_and_order_equal"
        ],
        "materialized_sqlite_integrity_ok": database_verification[
            "materialized_sqlite_integrity_ok"
        ],
        "retained_members_byte_equal": retained_exact,
        "retained_members_sha256_equal": retained_exact,
        "unrelated_payloads_reused": 321,
        "random_read_count": len(random_paths),
        "random_reads_exact": int(random_exact),
        "corruption_rejected": int(corruption),
        "source_unchanged": int(source_unchanged),
        "photo_status": "incumbent_exact_members_pending_plr_phase4",
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(RESULT, result)
    shutil.rmtree(retained_root)
    shutil.rmtree(database_members)
    materialized.unlink(missing_ok=True)
    nested_copy.unlink(missing_ok=True)
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
