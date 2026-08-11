#!/usr/bin/env python3
"""Splice the exact database local winner into one complete frozen WorldPack."""

from __future__ import annotations

from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import shutil
import sqlite3
import time

import yaml

from build_and_verify_outer_zpaq_bundle import decode_bundle_to_file
import run_benchmark
from worldpack import FileCodec, WorldPackReader
from worldpack_verified_rewrite import (
    PreverifiedPayloadEvidence,
    rewrite_member_payload,
)


EXPERIMENT_ROOT = Path(__file__).resolve().parent
OLD_ARCHIVE = Path("/private/tmp/pw_worldpack_complete.checkpoint.v1/capture.worldpack")
OLD_ARCHIVE_SHA = "67855f0a116d6dc21d16f89672249c8fd1c86bbe0443cfd825022de70bdafd14"
DATABASE_BUNDLE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "sqlite-webgraph-outer-complete/sqlite-webgraph-outer-complete.pwdb"
)
DATABASE_RESULT = (
    EXPERIMENT_ROOT / "results/worldpack-sqlite-webgraph-outer-complete.json"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-semantic-complete"
)
ARCHIVE = RUN_ROOT / "capture.worldpack"
RESULT = EXPERIMENT_ROOT / "results/worldpack-semantic-complete.json"
DATABASE_CODEC_ID = "similarity_forest_webgraph_outer_zpaq_v1"
SOURCE_BYTES = 580_406_089
PREVIOUS_COMPLETE_BYTES = 471_311_917
DATABASE_PATH = "official_sfm_live.db"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _database_codec() -> FileCodec:
    def encode(source: Path, destination: Path) -> None:
        if (
            source.stat().st_size != 198_983_680
            or sha256_file(source)
            != "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
        ):
            raise ValueError("semantic database source identity changed")
        shutil.copyfile(DATABASE_BUNDLE, destination)

    def decode(source: Path, destination: Path) -> None:
        decode_bundle_to_file(source, destination)

    return FileCodec(DATABASE_CODEC_ID, encode, decode)


def _verify_database_evidence() -> tuple[dict[str, object], PreverifiedPayloadEvidence]:
    value = json.loads(DATABASE_RESULT.read_text())
    required = {
        "schema": "pw_worldpack_sqlite_webgraph_outer_complete_result_v1",
        "source_bytes": 198_983_680,
        "source_sha256": (
            "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
        ),
        "byte_equal": 1,
        "sha256_equal": 1,
        "corruption_rejected": 1,
        "sqlite_integrity_check": "ok",
        "production_promoted": False,
        "phone_accessed": False,
    }
    for key, expected in required.items():
        if value.get(key) != expected:
            raise RuntimeError(f"database evidence gate failed: {key}")
    if (
        not DATABASE_BUNDLE.is_file()
        or DATABASE_BUNDLE.stat().st_size != value["complete_persisted_bytes"]
        or sha256_file(DATABASE_BUNDLE) != value["archive_sha256"]
    ):
        raise RuntimeError("database bundle differs from its exactness evidence")
    return value, PreverifiedPayloadEvidence(
        payload_sha256=str(value["archive_sha256"]),
        source_bytes=int(value["source_bytes"]),
        source_sha256=str(value["source_sha256"]),
        byte_equal=True,
        sha256_equal=True,
        corruption_rejected=True,
    )


def _restore_all_resumably(
    reader: WorldPackReader,
    manifest: dict[str, object],
    restored_root: Path,
) -> bool:
    restored_root.mkdir(parents=True, exist_ok=True)
    entries = list(manifest["entries"])
    for ordinal, entry in enumerate(entries):
        destination = restored_root / str(entry["path"])
        already_exact = (
            destination.is_file()
            and destination.stat().st_size == int(entry["bytes"])
            and sha256_file(destination) == entry["sha256"]
        )
        if not already_exact:
            reader.extract_member(str(entry["path"]), destination)
        if (ordinal + 1) % 20 == 0 or ordinal + 1 == len(entries):
            print(
                f"SEMANTIC_WORLDPACK_RESTORE {ordinal + 1}/{len(entries)}",
                flush=True,
            )
    return all(
        (restored_root / str(entry["path"])).is_file()
        and (restored_root / str(entry["path"])).stat().st_size
        == int(entry["bytes"])
        and sha256_file(restored_root / str(entry["path"])) == entry["sha256"]
        for entry in entries
    )


def main() -> None:
    started = time.monotonic()
    database_result, prior_evidence = _verify_database_evidence()
    if (
        not OLD_ARCHIVE.is_file()
        or OLD_ARCHIVE.stat().st_size != PREVIOUS_COMPLETE_BYTES
        or sha256_file(OLD_ARCHIVE) != OLD_ARCHIVE_SHA
    ):
        raise RuntimeError("saved complete WorldPack baseline identity changed")
    manifest = run_benchmark._load_frozen_manifest()
    contract = yaml.safe_load(run_benchmark.CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    entries = list(manifest["entries"])
    source_database = capture_root / DATABASE_PATH
    old_codecs = run_benchmark._worldpack_codecs(require_similarity=True)
    database_codec = _database_codec()
    codecs = [*old_codecs, database_codec]
    RUN_ROOT.mkdir(parents=True, exist_ok=True)

    written = rewrite_member_payload(
        OLD_ARCHIVE,
        ARCHIVE,
        codecs=codecs,
        member_path=DATABASE_PATH,
        expected_source_path=source_database,
        replacement_codec_id=DATABASE_CODEC_ID,
        replacement_payload=DATABASE_BUNDLE,
        preverified=prior_evidence,
    )
    before = WorldPackReader(OLD_ARCHIVE, codecs=old_codecs)
    reader = WorldPackReader(ARCHIVE, codecs=codecs)
    if reader.paths != before.paths or reader.manifest_sha256 != before.manifest_sha256:
        raise RuntimeError("semantic rewrite changed manifest membership or order")
    unrelated_reused = sum(
        1
        for old, new in zip(before.entries, reader.entries, strict=True)
        if old.path != DATABASE_PATH
        and (
            old.codec_id,
            old.payload_bytes,
            old.payload_sha256,
            old.original_bytes,
            old.original_sha256,
        )
        == (
            new.codec_id,
            new.payload_bytes,
            new.payload_sha256,
            new.original_bytes,
            new.original_sha256,
        )
    )
    if unrelated_reused != len(entries) - 1:
        raise RuntimeError("one or more unrelated WorldPack payloads changed")

    restored_root = RUN_ROOT / "restored"
    restored_exact = _restore_all_resumably(reader, manifest, restored_root)
    if not restored_exact:
        raise RuntimeError("semantic WorldPack did not restore every source member")
    sqlite_connection = sqlite3.connect(
        f"file:{restored_root / DATABASE_PATH}?mode=ro", uri=True
    )
    try:
        sqlite_integrity = sqlite_connection.execute(
            "PRAGMA integrity_check"
        ).fetchone()[0]
    finally:
        sqlite_connection.close()
    if sqlite_integrity != "ok":
        raise RuntimeError("semantic WorldPack SQLite integrity check failed")

    random_indices = sorted(
        {numerator * (len(entries) - 1) // 7 for numerator in range(8)}
    )
    random_exact = True
    random_root = RUN_ROOT / "random-read"
    random_root.mkdir(exist_ok=True)
    for index in random_indices:
        entry = entries[index]
        destination = random_root / f"member-{index}.bin"
        reader.extract_member(str(entry["path"]), destination)
        random_exact = random_exact and (
            destination.stat().st_size == int(entry["bytes"])
            and sha256_file(destination) == entry["sha256"]
        )
        destination.unlink(missing_ok=True)
    if not random_exact:
        raise RuntimeError("semantic WorldPack random read differed from source")
    corruption_rejected = run_benchmark._worldpack_corruption_probe(
        ARCHIVE, written, codecs, RUN_ROOT
    )
    if not corruption_rejected:
        raise RuntimeError("semantic WorldPack accepted registered corruption")
    source_unchanged = run_benchmark._verify_selected_sources(capture_root, entries)
    if not source_unchanged:
        raise RuntimeError("frozen source changed during semantic WorldPack run")

    database_entry = next(
        entry for entry in reader.entries if entry.path == DATABASE_PATH
    )
    improvement_bytes = PREVIOUS_COMPLETE_BYTES - written.complete_persisted_bytes
    if improvement_bytes <= 0:
        raise RuntimeError("semantic WorldPack did not improve the saved archive")
    codec_counts = Counter(entry.codec_id for entry in reader.entries)
    peak_temp_bytes = (
        ARCHIVE.stat().st_size
        + sum(path.stat().st_size for path in restored_root.rglob("*") if path.is_file())
        + DATABASE_BUNDLE.stat().st_size
    )
    result: dict[str, object] = {
        "schema": "pw_worldpack_semantic_complete_result_v1",
        "scope": "complete",
        "selection_policy": "saved_worldpack_replace_exact_database_local_winner",
        "input_manifest_sha256": sha256_file(run_benchmark.MANIFEST_PATH),
        "source_bytes": SOURCE_BYTES,
        "member_count": len(entries),
        "complete_persisted_bytes": written.complete_persisted_bytes,
        "archive_sha256": written.archive_sha256,
        "previous_complete_persisted_bytes": PREVIOUS_COMPLETE_BYTES,
        "previous_archive_sha256": OLD_ARCHIVE_SHA,
        "improvement_bytes": improvement_bytes,
        "improvement_fraction": improvement_bytes / PREVIOUS_COMPLETE_BYTES,
        "compression_ratio": SOURCE_BYTES / written.complete_persisted_bytes,
        "reduction_fraction": 1 - written.complete_persisted_bytes / SOURCE_BYTES,
        "header_bytes": written.header_bytes,
        "chunk_header_bytes": written.chunk_header_bytes,
        "payload_bytes": written.payload_bytes,
        "index_bytes": written.index_bytes,
        "footer_bytes": written.footer_bytes,
        "selected_codec_counts": dict(sorted(codec_counts.items())),
        "database_codec": DATABASE_CODEC_ID,
        "database_archive_bytes": database_entry.payload_bytes,
        "database_archive_sha256": database_entry.payload_sha256,
        "database_result_sha256": sha256_file(DATABASE_RESULT),
        "database_improvement_bytes": database_result["improvement_bytes"],
        "unrelated_payloads_reused": unrelated_reused,
        "all_members_byte_equal": int(restored_exact),
        "all_members_sha256_equal": int(restored_exact),
        "sqlite_integrity_check": sqlite_integrity,
        "random_read_count": len(random_indices),
        "random_reads_exact": int(random_exact),
        "corruption_rejected": int(corruption_rejected),
        "source_unchanged": int(source_unchanged),
        "wall_seconds": time.monotonic() - started,
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "peak_temp_bytes": peak_temp_bytes,
        "host": {
            "platform": platform.platform(),
            "machine": platform.machine(),
        },
        "photo_status": "incumbent_exact_members_pending_plr_phase2_decision",
        "phone_accessed": False,
        "production_promoted": False,
        "conclusion_scope": "worldpack_experiment_only",
    }
    run_benchmark._write_worldpack_result(
        RESULT, result, run_name="worldpack-semantic-complete"
    )
    shutil.rmtree(restored_root)
    try:
        random_root.rmdir()
    except OSError:
        pass
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
