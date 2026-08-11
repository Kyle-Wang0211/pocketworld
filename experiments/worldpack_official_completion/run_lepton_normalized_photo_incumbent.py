#!/usr/bin/env python3
"""Replace JXL-backed logical photos with smaller exact Lepton streams per photo."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import yaml

from photo_candidate_ledger import PhotoCandidateLedger
from photo_semantic_layer import build_photo_layer_manifest
import run_benchmark
import run_semantic_complete
from worldpack import WorldPackReader
from worldpack_semantic_rewrite import RawAddition, rewrite_drop_add_raw_members


ROOT = Path(__file__).resolve().parent
PLR_ROOT = ROOT.parent / "plr_derived_brunsli_two_photo"
SOURCE_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-full-semantic-incumbent/capture.full-semantic.worldpack"
)
SOURCE_RESULT = ROOT / "results/worldpack-full-semantic-incumbent.json"
LOGICAL_RESULT = ROOT / "results/worldpack-logical-photo-manifest.json"
LEPTON = Path(
    "/private/tmp/pw_worldpack_lepton_host_target.0.5.8/release/lepton_jpeg_util"
)
LEPTON_SHA256 = (
    "3173002ec9b63ea11de48c6c5c48a653d0060abb024100bf5865a7049c8a907e"
)
DJXL = PLR_ROOT / "build/libjxl-host-0.12.0/out/tools/djxl"
PWA2_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-full-forest-complete/pwa2-full-forest.worldpack"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-lepton-normalized-incumbent"
)
STREAM_ROOT = RUN_ROOT / "streams"
PROGRESS = RUN_ROOT / "progress.json"
ARCHIVE = RUN_ROOT / "capture.lepton-normalized.worldpack"
SEMANTIC_MANIFEST = RUN_ROOT / "semantic-manifest.json"
NORMALIZED_LOGICAL_RESULT = ROOT / "results/worldpack-logical-photo-manifest-v2.json"
RESULT = ROOT / "results/worldpack-lepton-normalized-incumbent.json"
SEMANTIC_MANIFEST_PATH = "__semantic__/manifest.json"
NESTED_DATABASE_PATH = "__semantic__/official_sfm_live.pwa2.worldpack"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def _run(command: list[str]) -> None:
    subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )


def _atomic_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def _member_path(logical_path: str) -> str:
    identity = hashlib.sha256(logical_path.encode("utf-8")).hexdigest()[:24]
    return f"__semantic__/photos/incumbent/{identity}.lep"


def _encode_candidate(
    photo: dict[str, object],
    *,
    current_payload_bytes: int,
) -> dict[str, object]:
    logical_path = str(photo["logical_path"])
    source = Path(str(photo["logical_jpeg_path"]))
    if (
        source.stat().st_size != int(photo["logical_bytes"])
        or _sha256(source) != photo["logical_sha256"]
    ):
        raise RuntimeError(f"logical JPEG source changed: {logical_path}")
    identity = hashlib.sha256(logical_path.encode("utf-8")).hexdigest()[:24]
    directory = STREAM_ROOT / identity
    if directory.exists():
        shutil.rmtree(directory)
    directory.mkdir(parents=True)
    archive = directory / "photo.lep"
    restored = directory / "restored.jpg"
    _run([str(LEPTON), "--quiet", "--overwrite", str(source), str(archive)])
    _run([str(LEPTON), "--quiet", "--overwrite", str(archive), str(restored)])
    if restored.read_bytes() != source.read_bytes() or _sha256(restored) != photo[
        "logical_sha256"
    ]:
        raise RuntimeError(f"Lepton exactness failed: {logical_path}")
    restored.unlink()
    return {
        "logical_path": logical_path,
        "source_bytes": int(photo["logical_bytes"]),
        "source_sha256": str(photo["logical_sha256"]),
        "predecessor_storage_path": str(photo["storage_path"]),
        "predecessor_worldpack_payload_bytes": current_payload_bytes,
        "member_path": _member_path(logical_path),
        "archive_path": str(archive),
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": _sha256(archive),
        "byte_equal": True,
        "sha256_equal": True,
    }


def _verify_candidate(record: dict[str, object]) -> None:
    archive = Path(str(record["archive_path"]))
    if (
        not archive.is_file()
        or archive.stat().st_size != int(record["archive_bytes"])
        or _sha256(archive) != record["archive_sha256"]
    ):
        raise RuntimeError("committed Lepton candidate identity changed")


def _restore_all_photos(
    reader: WorldPackReader,
    logical: dict[str, object],
) -> tuple[int, int]:
    working = RUN_ROOT / "photo-restore"
    if working.exists():
        shutil.rmtree(working)
    working.mkdir(parents=True)
    exact_bytes = 0
    exact_sha = 0
    for ordinal, photo in enumerate(logical["photos"], start=1):
        stored = working / "stored"
        restored = working / "restored.jpg"
        stored.unlink(missing_ok=True)
        restored.unlink(missing_ok=True)
        reader.extract_member(str(photo["storage_path"]), stored)
        codec = str(photo["storage_codec"])
        if codec == "lepton_jpeg_0_5_8":
            _run([str(LEPTON), "--quiet", "--overwrite", str(stored), str(restored)])
        elif codec == "jxl_0_12_0_exact_jpeg":
            _run(
                [
                    str(DJXL),
                    "--output_format=jpeg",
                    str(stored),
                    str(restored),
                ]
            )
        elif codec == "jpeg_original":
            shutil.copyfile(stored, restored)
        else:
            raise RuntimeError(f"unknown normalized photo codec: {codec}")
        expected = Path(str(photo["logical_jpeg_path"]))
        if restored.read_bytes() == expected.read_bytes():
            exact_bytes += 1
        if _sha256(restored) == photo["logical_sha256"]:
            exact_sha += 1
        if ordinal % 10 == 0 or ordinal == len(logical["photos"]):
            print(f"LEPTON_NORMALIZED_RESTORE {ordinal}/155", flush=True)
    shutil.rmtree(working)
    return exact_bytes, exact_sha


def main() -> None:
    if RESULT.exists() or NORMALIZED_LOGICAL_RESULT.exists():
        raise FileExistsError("Lepton normalized terminal evidence already exists")
    started = time.monotonic()
    predecessor = json.loads(SOURCE_RESULT.read_bytes())
    logical = json.loads(LOGICAL_RESULT.read_bytes())
    if (
        predecessor.get("schema") != "pw_worldpack_full_semantic_incumbent_v1"
        or logical.get("schema") != "pw_worldpack_logical_photo_manifest_v1"
        or logical.get("logical_photo_count") != 155
        or SOURCE_ARCHIVE.stat().st_size != predecessor["complete_persisted_bytes"]
        or _sha256(SOURCE_ARCHIVE) != predecessor["archive_sha256"]
        or _sha256(LEPTON) != LEPTON_SHA256
    ):
        raise RuntimeError("Lepton normalization evidence gate failed")
    codecs = [
        *run_benchmark._worldpack_codecs(require_similarity=True),
        run_semantic_complete._database_codec(),
    ]
    before = WorldPackReader(SOURCE_ARCHIVE, codecs=codecs)
    entries = {entry.path: entry for entry in before.entries}
    identity = {
        "predecessor_archive_sha256": predecessor["archive_sha256"],
        "logical_photo_manifest_sha256": _sha256(LOGICAL_RESULT),
        "logical_photo_identity_sha256": logical["logical_photo_identity_sha256"],
        "lepton_binary_sha256": LEPTON_SHA256,
        "candidate_scope": "111_jxl_backed_logical_original_jpegs",
    }
    ledger = PhotoCandidateLedger.open(PROGRESS, identity=identity)
    jxl_photos = [
        photo
        for photo in logical["photos"]
        if photo["storage_codec"] == "jxl_0_12_0_exact_jpeg"
    ]
    if len(jxl_photos) != 111:
        raise RuntimeError(f"expected 111 JXL-backed photos, found {len(jxl_photos)}")
    for ordinal, photo in enumerate(jxl_photos, start=1):
        logical_path = str(photo["logical_path"])
        entry = entries.get(str(photo["storage_path"]))
        if (
            entry is None
            or entry.original_bytes != int(photo["storage_bytes"])
            or entry.original_sha256 != photo["storage_sha256"]
        ):
            raise RuntimeError(f"predecessor photo member changed: {logical_path}")
        record = ledger.get(logical_path)
        if record is None:
            record = _encode_candidate(
                photo, current_payload_bytes=entry.payload_bytes
            )
            ledger.record(logical_path, record)
        else:
            _verify_candidate(record)
        print(f"LEPTON_NORMALIZED_ENCODE {ordinal}/111", flush=True)

    records = {path: ledger.get(path) for path in [str(p["logical_path"]) for p in jxl_photos]}
    if any(record is None for record in records.values()):
        raise RuntimeError("Lepton normalization ledger is incomplete")
    selected = {
        path: record
        for path, record in records.items()
        if int(record["archive_bytes"])
        < int(record["predecessor_worldpack_payload_bytes"])
    }
    if not selected:
        raise RuntimeError("Lepton did not beat any JXL-backed WorldPack payload")

    normalized_photos: list[dict[str, object]] = []
    for photo in logical["photos"]:
        record = selected.get(str(photo["logical_path"]))
        if record is None:
            normalized_photos.append(dict(photo))
        else:
            normalized_photos.append(
                {
                    **photo,
                    "storage_path": record["member_path"],
                    "storage_codec": "lepton_jpeg_0_5_8",
                    "storage_bytes": record["archive_bytes"],
                    "storage_sha256": record["archive_sha256"],
                    "normalized_from_jxl": True,
                }
            )
    normalized_logical: dict[str, object] = {
        **logical,
        "schema": "pw_worldpack_logical_photo_manifest_v2",
        "photos": normalized_photos,
        "lepton_revision": "90fdc27828676892fbb41777cfcc6bad1e470516",
        "lepton_binary_sha256": LEPTON_SHA256,
        "lepton_candidates_tested": len(records),
        "lepton_candidates_selected": len(selected),
        "selected_photo_payload_bytes": sum(
            (
                int(selected[str(photo["logical_path"])]["archive_bytes"])
                if str(photo["logical_path"]) in selected
                else entries[str(photo["storage_path"])].payload_bytes
            )
            for photo in logical["photos"]
        ),
    }
    _atomic_json(NORMALIZED_LOGICAL_RESULT, normalized_logical)
    predecessor_manifest = json.loads(before.read_member(SEMANTIC_MANIFEST_PATH))
    semantic_manifest: dict[str, object] = {
        "schema": "pw_worldpack_semantic_manifest_v2_1",
        "capture_id": predecessor_manifest["capture_id"],
        "source_manifest_sha256": predecessor_manifest["source_manifest_sha256"],
        "logical_output_member_count": predecessor_manifest[
            "logical_output_member_count"
        ],
        "database": predecessor_manifest["database"],
        "photo_layer": build_photo_layer_manifest(normalized_logical),
        "terminal_photo_decision": "lepton_normalized_incumbent_pending_plr",
    }
    _atomic_json(SEMANTIC_MANIFEST, semantic_manifest)
    drop_paths = {SEMANTIC_MANIFEST_PATH}
    additions: list[RawAddition] = []
    for logical_path in sorted(selected, key=lambda value: value.encode()):
        record = selected[logical_path]
        drop_paths.add(str(record["predecessor_storage_path"]))
        additions.append(
            RawAddition(str(record["member_path"]), Path(str(record["archive_path"])))
        )
    additions.append(RawAddition(SEMANTIC_MANIFEST_PATH, SEMANTIC_MANIFEST))
    written = rewrite_drop_add_raw_members(
        SOURCE_ARCHIVE,
        ARCHIVE,
        codecs=codecs,
        manifest_sha256=_sha256(SEMANTIC_MANIFEST),
        drop_paths=drop_paths,
        additions=tuple(additions),
    )
    reader = WorldPackReader(ARCHIVE, codecs=codecs)
    if "official_sfm_live.db" in reader.paths:
        raise RuntimeError("Lepton-normalized archive retained physical SQLite")
    nested = RUN_ROOT / "database.pwa2.worldpack"
    reader.extract_member(NESTED_DATABASE_PATH, nested)
    if nested.read_bytes() != PWA2_ARCHIVE.read_bytes():
        raise RuntimeError("normalized database payload changed")
    nested.unlink()
    exact_bytes, exact_sha = _restore_all_photos(reader, normalized_logical)
    if exact_bytes != 155 or exact_sha != 155:
        raise RuntimeError("Lepton-normalized photo layer is not exact")

    frozen_manifest = run_benchmark._load_frozen_manifest()
    contract = yaml.safe_load(run_benchmark.CONTRACT_PATH.read_text())
    source_root = Path(contract["input"]["capture_root"])
    addition_sources = {addition.relative_path: addition.source_path for addition in additions}
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
        if path in addition_sources:
            expected = addition_sources[path].read_bytes()
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
        raise RuntimeError("Lepton normalized outer archive gate failed")
    if written.complete_persisted_bytes >= int(predecessor["complete_persisted_bytes"]):
        raise RuntimeError("Lepton normalized complete archive is not smaller")

    result: dict[str, object] = {
        "schema": "pw_worldpack_lepton_normalized_incumbent_v1",
        "archive_path": str(ARCHIVE),
        "archive_sha256": written.archive_sha256,
        "complete_persisted_bytes": written.complete_persisted_bytes,
        "predecessor_archive_bytes": predecessor["complete_persisted_bytes"],
        "improvement_bytes": (
            int(predecessor["complete_persisted_bytes"])
            - written.complete_persisted_bytes
        ),
        "jxl_backed_photo_count_tested": len(records),
        "candidate_roundtrip_exact": sum(
            bool(record["byte_equal"] and record["sha256_equal"])
            for record in records.values()
        ),
        "selected_lepton_photo_count": len(selected),
        "retained_photo_count": 155 - len(selected),
        "logical_original_jpegs_byte_equal": exact_bytes,
        "logical_original_jpegs_sha256_equal": exact_sha,
        "logical_photo_identity_sha256": logical[
            "logical_photo_identity_sha256"
        ],
        "logical_photo_manifest_v2_sha256": _sha256(NORMALIZED_LOGICAL_RESULT),
        "physical_sqlite_member_present": False,
        "database_page_history_preserved": False,
        "database_all_cells_equal": predecessor["database_all_cells_equal"],
        "database_all_rows_and_order_equal": predecessor[
            "database_all_rows_and_order_equal"
        ],
        "materialized_sqlite_integrity_ok": predecessor[
            "materialized_sqlite_integrity_ok"
        ],
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
