#!/usr/bin/env python3
"""Build and verify the complete normalized SQLite semantic candidate."""

from __future__ import annotations

from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

import mlflow

from worldpack import (
    FileCodec,
    MemberSpec,
    WorldPackCorruption,
    WorldPackReader,
    WorldPackWriter,
)


ROOT = Path(__file__).resolve().parent
MEMBERS = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-semantic-full-forest-v1"
)
SOURCE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "recovered-capture/official_sfm_live.db"
)
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "pwa2-full-forest-complete"
)
CACHE = RUN_ROOT / "zpaq-cache"
ARCHIVE = RUN_ROOT / "pwa2-full-forest.worldpack"
RESULT = ROOT / "results/pwa2-full-forest-complete.json"
ZPAQ = Path(
    "/private/tmp/pw_worldpack_zpaq_adapter_bin.v715/"
    "worldpack_zpaq_adapter"
)
VERIFIER = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-build/"
    "pwa2-pack-only/pwa2_verify_only"
)

SOURCE_BYTES = 198_983_680
SOURCE_SHA256 = "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
EXPECTED_MEMBER_COUNT = 109
DESCRIPTOR_NODES = 1_251_246
ROOT_DESCRIPTOR_NODES = 8_192
PREDICTED_DESCRIPTOR_NODES = 1_243_054
UNMATCHED_DESCRIPTOR_NODES = 0
CURRENT_EXACT_DATABASE_MEMBER_BYTES = 116_576_307


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_inputs() -> list[Path]:
    if (
        not SOURCE.is_file()
        or SOURCE.stat().st_size != SOURCE_BYTES
        or sha256_file(SOURCE) != SOURCE_SHA256
    ):
        raise RuntimeError("registered SQLite source identity changed")
    if not ZPAQ.is_file() or sha256_file(ZPAQ) != (
        "6002dceb1877b24adc2de674732f0f5dc12ecc6dde80a61a08b3350600c78326"
    ):
        raise RuntimeError("registered ZPAQ adapter identity changed")
    if not VERIFIER.is_file() or sha256_file(VERIFIER) != (
        "0fa8c3310274939cfa881173bf37fbbc75ac287cbacb961f1906b35cdc3662dc"
    ):
        raise RuntimeError("registered PWA2 verifier identity changed")
    members = sorted(path for path in MEMBERS.iterdir() if path.is_file())
    if len(members) != EXPECTED_MEMBER_COUNT:
        raise RuntimeError("normalized member count changed")
    return members


def zpaq_codec() -> FileCodec:
    CACHE.mkdir(parents=True, exist_ok=True)

    def encode(source: Path, destination: Path) -> None:
        identity = sha256_file(source)
        cached = CACHE / f"{source.name}.{identity}.zpaq"
        if not cached.is_file():
            temporary = cached.with_suffix(cached.suffix + ".tmp")
            temporary.unlink(missing_ok=True)
            subprocess.run(
                [str(ZPAQ), "compress", str(source), str(temporary)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            os.replace(temporary, cached)
        shutil.copyfile(cached, destination)

    def decode(source: Path, destination: Path) -> None:
        subprocess.run(
            [str(ZPAQ), "decompress", str(source), str(destination)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    return FileCodec("zpaq_7_15_method5", encode, decode)


def manifest_identity(members: list[Path]) -> str:
    document = [
        {"name": path.name, "bytes": path.stat().st_size, "sha256": sha256_file(path)}
        for path in members
    ]
    encoded = json.dumps(
        document, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def corruption_rejected(codec: FileCodec) -> bool:
    reader = WorldPackReader(ARCHIVE, codecs=[codec])
    entry = max(
        (entry for entry in reader.entries if entry.payload_bytes > 0),
        key=lambda value: value.payload_bytes,
    )
    with tempfile.TemporaryDirectory(prefix="pwa2-corrupt-", dir=RUN_ROOT) as name:
        corrupt = Path(name) / "corrupt.worldpack"
        shutil.copyfile(ARCHIVE, corrupt)
        with corrupt.open("r+b") as output:
            output.seek(entry.payload_offset + entry.payload_bytes // 2)
            value = output.read(1)
            output.seek(-1, 1)
            output.write(bytes((value[0] ^ 0x80,)))
        try:
            WorldPackReader(corrupt, codecs=[codec]).extract_member(
                entry.path, Path(name) / "restored.bin"
            )
        except WorldPackCorruption:
            return True
    return False


def main() -> None:
    started = time.monotonic()
    members = verify_inputs()
    source_before = (SOURCE.stat().st_size, sha256_file(SOURCE))
    manifest_sha = manifest_identity(members)
    RUN_ROOT.mkdir(parents=True, exist_ok=True)
    codec = zpaq_codec()
    written = WorldPackWriter(
        ARCHIVE,
        manifest_sha256=manifest_sha,
        scratch_root=RUN_ROOT / "writer-scratch",
        codecs=[codec],
    ).write(
        [MemberSpec(path.name, path, (codec.codec_id, "raw")) for path in members]
    )

    with tempfile.TemporaryDirectory(prefix="pwa2-verify-", dir=RUN_ROOT) as name:
        working = Path(name)
        decoded = working / "members"
        WorldPackReader(ARCHIVE, codecs=[codec]).extract_all(decoded)
        completed = subprocess.run(
            [str(VERIFIER), str(SOURCE), str(decoded), str(working / "materialized.db")],
            check=True,
            capture_output=True,
            text=True,
        )
        verification = json.loads(completed.stdout)
    corruption = corruption_rejected(codec)
    source_unchanged = source_before == (SOURCE.stat().st_size, sha256_file(SOURCE))
    if not corruption or not source_unchanged:
        raise RuntimeError("semantic candidate failed corruption/source gate")
    codec_counts = Counter(entry.codec_id for entry in written.entries)
    improvement = CURRENT_EXACT_DATABASE_MEMBER_BYTES - written.complete_persisted_bytes

    mlflow.set_tracking_uri("sqlite:///" + str((ROOT / "mlflow.db").resolve()))
    mlflow.set_experiment("pocketworld-worldpack-official-completion")
    with mlflow.start_run(run_name="pwa2-full-forest-complete") as active_run:
        result = {
            "schema": "pw_pwa2_full_forest_complete_result_v1",
            "source_bytes": SOURCE_BYTES,
            "source_sha256": SOURCE_SHA256,
            "member_count": len(members),
            "raw_member_bytes": sum(path.stat().st_size for path in members),
            "descriptor_nodes": DESCRIPTOR_NODES,
            "root_descriptor_nodes": ROOT_DESCRIPTOR_NODES,
            "predicted_descriptor_nodes": PREDICTED_DESCRIPTOR_NODES,
            "unmatched_descriptor_nodes": UNMATCHED_DESCRIPTOR_NODES,
            "complete_persisted_bytes": written.complete_persisted_bytes,
            "payload_bytes": written.payload_bytes,
            "archive_sha256": written.archive_sha256,
            "manifest_sha256": manifest_sha,
            "codec_counts": dict(sorted(codec_counts.items())),
            "current_exact_database_member_bytes": CURRENT_EXACT_DATABASE_MEMBER_BYTES,
            "improvement_bytes": improvement,
            "strictly_smaller_than_current": int(improvement > 0),
            **verification,
            "corruption_rejected": int(corruption),
            "source_unchanged": int(source_unchanged),
            "wall_seconds": time.monotonic() - started,
            "mlflow_run_id": active_run.info.run_id,
            "host": {"platform": platform.platform(), "machine": platform.machine()},
            "production_promoted": False,
            "phone_accessed": False,
            "conclusion_scope": "host_semantic_database_candidate_only",
        }
        RESULT.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        mlflow.log_params(
            {
                "source_sha256": SOURCE_SHA256,
                "manifest_sha256": manifest_sha,
                "descriptor_nodes": DESCRIPTOR_NODES,
                "predicted_descriptor_nodes": PREDICTED_DESCRIPTOR_NODES,
            }
        )
        mlflow.log_metrics(
            {
                "complete_persisted_bytes": written.complete_persisted_bytes,
                "improvement_bytes": improvement,
                "all_cells_equal": verification["all_cells_equal"],
                "all_rows_and_order_equal": verification[
                    "all_rows_and_order_equal"
                ],
            }
        )
        mlflow.log_artifact(str(RESULT), artifact_path="results")
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
