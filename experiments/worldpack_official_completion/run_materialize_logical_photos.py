#!/usr/bin/env python3
"""Materialize and freeze the original-JPEG logical view of one full project."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

import run_benchmark
from photo_semantic_manifest import build_logical_photo_plan


ROOT = Path(__file__).resolve().parent
PLR_ROOT = ROOT.parent / "plr_derived_brunsli_two_photo"
JXL_BUILD_MANIFEST = PLR_ROOT / "results/libjxl-host-0.12.0-build.json"
DJXL = PLR_ROOT / "build/libjxl-host-0.12.0/out/tools/djxl"
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "worldpack-logical-photos"
)
LOGICAL_ROOT = RUN_ROOT / "jpeg"
RESULT = ROOT / "results/worldpack-logical-photo-manifest.json"


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


def main() -> None:
    if RESULT.exists():
        raise FileExistsError("logical photo manifest already exists")
    started = time.monotonic()
    manifest = run_benchmark._load_frozen_manifest()
    contract = __import__("yaml").safe_load(run_benchmark.CONTRACT_PATH.read_text())
    source_root = Path(contract["input"]["capture_root"])
    build = json.loads(JXL_BUILD_MANIFEST.read_bytes())
    if (
        build.get("schema") != "pw_plr_libjxl_host_build_v1"
        or build.get("version") != "0.12.0"
        or build.get("revision")
        != "a7a9c787341cf703dede03c2009fa460cae5e5df"
        or sha256_file(DJXL) != build.get("djxl_sha256")
    ):
        raise RuntimeError("pinned JXL decoder identity mismatch")
    plan = build_logical_photo_plan(manifest["entries"])
    if len(plan) != 155:
        raise RuntimeError(f"expected 155 logical photos, found {len(plan)}")
    LOGICAL_ROOT.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, object]] = []
    for ordinal, item in enumerate(plan, start=1):
        source = source_root / item.storage_path
        if (
            source.stat().st_size != item.storage_bytes
            or sha256_file(source) != item.storage_sha256
        ):
            raise RuntimeError(f"stored photo identity changed: {item.storage_path}")
        if item.storage_codec == "jpeg_original":
            logical = source
            materialized = False
        else:
            logical = LOGICAL_ROOT / item.logical_path.removeprefix(
                "photos_highres/"
            )
            logical.parent.mkdir(parents=True, exist_ok=True)
            temporary = logical.with_suffix(logical.suffix + ".tmp")
            temporary.unlink(missing_ok=True)
            subprocess.run(
                [
                    str(DJXL),
                    "--output_format=jpeg",
                    str(source),
                    str(temporary),
                ],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if not temporary.is_file() or not temporary.read_bytes()[:3] == b"\xff\xd8\xff":
                temporary.unlink(missing_ok=True)
                raise RuntimeError(f"JXL did not reconstruct a JPEG: {item.storage_path}")
            os.replace(temporary, logical)
            materialized = True
        records.append(
            {
                "logical_path": item.logical_path,
                "logical_bytes": logical.stat().st_size,
                "logical_sha256": sha256_file(logical),
                "logical_jpeg_path": str(logical),
                "storage_path": item.storage_path,
                "storage_codec": item.storage_codec,
                "storage_bytes": item.storage_bytes,
                "storage_sha256": item.storage_sha256,
                "materialized_from_jxl": materialized,
            }
        )
        if ordinal % 10 == 0 or ordinal == len(plan):
            print(f"LOGICAL_PHOTO_MATERIALIZE {ordinal}/{len(plan)}", flush=True)
    identity_payload = json.dumps(
        [
            {
                "logical_path": item["logical_path"],
                "logical_bytes": item["logical_bytes"],
                "logical_sha256": item["logical_sha256"],
            }
            for item in records
        ],
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    source_unchanged = run_benchmark._verify_selected_sources(
        source_root,
        [
            entry
            for entry in manifest["entries"]
            if str(entry["path"]).lower().endswith((".jpg", ".jpg.jxl"))
        ],
    )
    if not source_unchanged:
        raise RuntimeError("stored photo source changed while materializing")
    result: dict[str, object] = {
        "schema": "pw_worldpack_logical_photo_manifest_v1",
        "capture_id": manifest["capture_id"],
        "logical_photo_count": len(records),
        "jxl_backed_photo_count": sum(
            bool(item["materialized_from_jxl"]) for item in records
        ),
        "jpeg_backed_photo_count": sum(
            not bool(item["materialized_from_jxl"]) for item in records
        ),
        "logical_original_jpeg_bytes": sum(
            int(item["logical_bytes"]) for item in records
        ),
        "current_stored_photo_bytes": sum(
            int(item["storage_bytes"]) for item in records
        ),
        "logical_photo_identity_sha256": hashlib.sha256(identity_payload).hexdigest(),
        "jxl_version": "0.12.0",
        "jxl_revision": build["revision"],
        "djxl_sha256": build["djxl_sha256"],
        "photos": records,
        "source_unchanged": int(source_unchanged),
        "wall_seconds": time.monotonic() - started,
        "production_promoted": False,
        "phone_accessed": False,
    }
    _atomic_json(RESULT, result)
    print(json.dumps({key: value for key, value in result.items() if key != "photos"}, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
