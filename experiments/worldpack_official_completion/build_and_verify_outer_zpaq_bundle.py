#!/usr/bin/env python3
"""Build and independently decode the complete exact SQLite local winner."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import platform
import shutil
import sqlite3
import subprocess
import tempfile
import time

import mlflow

from sqlite_webgraph_composite import (
    canonical_records_to_match_blobs,
    decode_java_u64_permutation,
    restore_canonical_from_v1_permutation,
    restore_match_blobs,
    validate_match_blobs,
)
from sqlite_webgraph_outer_bundle import (
    build_database_bundle,
    extract_database_bundle,
    parse_webgraph_outer_envelope,
)
from webgraph_llp_verify import read_arcs_tsv
from worldpack import WorldPackCorruption, WorldPackReader


EXPERIMENT_ROOT = Path(__file__).resolve().parent
RESULT = EXPERIMENT_ROOT / "results/worldpack-sqlite-webgraph-outer-complete.json"
MLFLOW_DATABASE = EXPERIMENT_ROOT / "mlflow.db"
RUN_ROOT = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "sqlite-webgraph-outer-complete"
)
SOURCE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "recovered-capture/official_sfm_live.db"
)
SIMILARITY_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "sqlite-webgraph-composite-b/similarity/similarity_forest_v1.zpaq"
)
WEBGRAPH_ARCHIVE = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-runs/"
    "webgraph-complete-outer-zpaq-i0-sidecar-first/complete.zpaq"
)
SIMILARITY_DECODER = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-build/"
    "similarity-decoder/worldpack_similarity_forest_decoder"
)
WEBGRAPH = Path(
    "/Users/kaidongwang/Documents/progecttwo/.tmp/worldpack-build/"
    "webgraph-rs/target/release/webgraph"
)
ZPAQ = Path(
    "/private/tmp/pw_worldpack_zpaq_adapter_bin.v715/worldpack_zpaq_adapter"
)
BUNDLE = RUN_ROOT / "sqlite-webgraph-outer-complete.pwdb"

SOURCE_BYTES = 198_983_680
SOURCE_SHA = "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
ZEROED_SHA = "77c193fd1a2176686cb8ffe015034734028f8296f1410a70a7a3092c83c37379"
CANONICAL_SHA = "1bf49e01aae0c1844d934a9a91f3e2a83826fb39d9be09d8561f64e59e492acf"
SIMILARITY_ARCHIVE_BYTES = 115_130_088
SIMILARITY_ARCHIVE_SHA = (
    "0ac032fc04e3b9f529eb00e18a4e4d7e24e3030de8223095909f6f84c81599c5"
)
WEBGRAPH_ARCHIVE_BYTES = 1_443_354
WEBGRAPH_ARCHIVE_SHA = (
    "78b0f0039b7122949127a9c3a7e1a2a5b53141d724f5b26ad2d535a47024ad5d"
)
PREVIOUS_DATABASE_PAYLOAD_BYTES = 116_739_319


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def files_byte_equal(left: Path, right: Path) -> bool:
    if left.stat().st_size != right.stat().st_size:
        return False
    with left.open("rb") as first, right.open("rb") as second:
        while True:
            first_block = first.read(1024 * 1024)
            second_block = second.read(1024 * 1024)
            if first_block != second_block:
                return False
            if not first_block:
                return True


def verify_inputs() -> None:
    expected = (
        (SOURCE, SOURCE_BYTES, SOURCE_SHA),
        (SIMILARITY_ARCHIVE, SIMILARITY_ARCHIVE_BYTES, SIMILARITY_ARCHIVE_SHA),
        (WEBGRAPH_ARCHIVE, WEBGRAPH_ARCHIVE_BYTES, WEBGRAPH_ARCHIVE_SHA),
    )
    for path, byte_count, digest in expected:
        if (
            not path.is_file()
            or path.stat().st_size != byte_count
            or sha256_file(path) != digest
        ):
            raise RuntimeError(f"registered input identity changed: {path}")
    for executable in (SIMILARITY_DECODER, WEBGRAPH, ZPAQ):
        if not executable.is_file():
            raise RuntimeError(f"registered decoder is missing: {executable}")


def metadata() -> dict[str, object]:
    return {
        "schema": "pw_sqlite_webgraph_outer_bundle_v1",
        "source_bytes": SOURCE_BYTES,
        "source_sha256": SOURCE_SHA,
        "zeroed_sha256": ZEROED_SHA,
        "similarity_archive_bytes": SIMILARITY_ARCHIVE_BYTES,
        "similarity_archive_sha256": SIMILARITY_ARCHIVE_SHA,
        "webgraph_archive_bytes": WEBGRAPH_ARCHIVE_BYTES,
        "webgraph_archive_sha256": WEBGRAPH_ARCHIVE_SHA,
        "webgraph_envelope_sha256": (
            "12df6c996bdacf25fc363d8819b0147ea041f621577ab4a35a1ac3a238b16246"
        ),
        "canonical_match_sha256": CANONICAL_SHA,
        "webgraph_revision": "f8698a7bdda2c4e171017548307179cd5c7a3166",
        "webgraph_parameters": {
            "bvgraphz": True,
            "compression_window": 31,
            "maximum_reference_count": 7,
            "minimum_interval_length": 0,
            "outdegrees": "unary",
            "references": "unary",
            "blocks": "unary",
            "residuals": "omega",
        },
        "outer_codec": {"name": "ZPAQ", "version": "7.15", "method": 5},
    }


def decode_bundle(source: Path, destination: Path) -> dict[str, object]:
    extracted = extract_database_bundle(source, destination / "bundle")
    zeroed = destination / "zeroed.db"
    subprocess.run(
        [
            str(SIMILARITY_DECODER),
            str(extracted.similarity_archive),
            str(zeroed),
            ZEROED_SHA,
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    envelope = destination / "webgraph-envelope.bin"
    subprocess.run(
        [
            str(ZPAQ),
            "decompress",
            str(extracted.webgraph_archive),
            str(envelope),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if sha256_file(envelope) != extracted.metadata["webgraph_envelope_sha256"]:
        raise RuntimeError("decoded WebGraph envelope identity changed")
    webgraph_root = destination / "webgraph"
    webgraph_root.mkdir()
    members = parse_webgraph_outer_envelope(envelope.read_bytes())
    for name, value in members.items():
        (webgraph_root / name).write_bytes(value)
    winner = webgraph_root / "winner"
    arcs = webgraph_root / "winner.arcs.tsv"
    with arcs.open("wb") as output:
        subprocess.run(
            [str(WEBGRAPH), "to", "arcs", str(winner)],
            check=True,
            stdout=output,
            stderr=subprocess.PIPE,
        )
    canonical = restore_canonical_from_v1_permutation(
        members["mapping.raw"],
        decode_java_u64_permutation(members["permutation.java"]),
        read_arcs_tsv(arcs),
    )
    if hashlib.sha256(canonical).hexdigest() != CANONICAL_SHA:
        raise RuntimeError("WebGraph members restored the wrong canonical records")
    blobs = canonical_records_to_match_blobs(canonical)
    restore_match_blobs(zeroed, blobs)
    covered_rows, records = validate_match_blobs(zeroed, blobs)
    connection = sqlite3.connect(f"file:{zeroed}?mode=ro", uri=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
    finally:
        connection.close()
    restored_sha = sha256_file(zeroed)
    byte_equal = files_byte_equal(zeroed, SOURCE)
    if not byte_equal or restored_sha != SOURCE_SHA or integrity != "ok":
        raise RuntimeError("database bundle did not restore the exact source SQLite")
    return {
        "restored_bytes": zeroed.stat().st_size,
        "restored_sha256": restored_sha,
        "covered_sqlite_rows": covered_rows,
        "match_records": records,
        "sqlite_integrity_check": integrity,
        "byte_equal": int(byte_equal),
        "sha256_equal": int(restored_sha == SOURCE_SHA),
    }


def decode_bundle_to_file(source: Path, destination: Path) -> dict[str, object]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pw-database-bundle-decode-") as temporary:
        working = Path(temporary)
        exactness = decode_bundle(source, working)
        shutil.copyfile(working / "zeroed.db", destination)
    return exactness


def corruption_probe() -> bool:
    reader = WorldPackReader(BUNDLE, codecs=[])
    entry = next(value for value in reader.entries if value.path == "webgraph.zpaq")
    corrupt = RUN_ROOT / "sqlite-webgraph-outer-complete.corrupt.pwdb"
    shutil.copyfile(BUNDLE, corrupt)
    with corrupt.open("r+b") as output:
        output.seek(entry.payload_offset + 17)
        value = output.read(1)
        output.seek(-1, 1)
        output.write(bytes((value[0] ^ 0x80,)))
    try:
        with tempfile.TemporaryDirectory(
            prefix="corrupt-", dir=RUN_ROOT
        ) as temporary:
            extract_database_bundle(corrupt, Path(temporary))
    except WorldPackCorruption:
        return True
    finally:
        corrupt.unlink(missing_ok=True)
    return False


def main() -> None:
    started = time.monotonic()
    verify_inputs()
    RUN_ROOT.mkdir(parents=True, exist_ok=True)
    written = build_database_bundle(
        BUNDLE,
        similarity_archive=SIMILARITY_ARCHIVE,
        webgraph_archive=WEBGRAPH_ARCHIVE,
        metadata=metadata(),
        scratch_root=RUN_ROOT / "bundle-scratch",
    )
    with tempfile.TemporaryDirectory(
        prefix="decode-", dir=RUN_ROOT
    ) as temporary:
        exactness = decode_bundle(BUNDLE, Path(temporary))
    corruption_rejected = corruption_probe()
    if not corruption_rejected:
        raise RuntimeError("corrupted database bundle was accepted")
    improvement_bytes = (
        PREVIOUS_DATABASE_PAYLOAD_BYTES - written.complete_persisted_bytes
    )
    if improvement_bytes <= 0:
        raise RuntimeError("outer WebGraph bundle did not beat previous database member")

    mlflow.set_tracking_uri("sqlite:///" + str(MLFLOW_DATABASE.resolve()))
    mlflow.set_experiment("pocketworld-worldpack-official-completion")
    with mlflow.start_run(run_name="sqlite-webgraph-outer-complete") as active_run:
        result: dict[str, object] = {
            "schema": "pw_worldpack_sqlite_webgraph_outer_complete_result_v1",
            "source_bytes": SOURCE_BYTES,
            "source_sha256": SOURCE_SHA,
            "similarity_archive_bytes": SIMILARITY_ARCHIVE_BYTES,
            "similarity_archive_sha256": SIMILARITY_ARCHIVE_SHA,
            "webgraph_archive_bytes": WEBGRAPH_ARCHIVE_BYTES,
            "webgraph_archive_sha256": WEBGRAPH_ARCHIVE_SHA,
            "complete_persisted_bytes": written.complete_persisted_bytes,
            "archive_sha256": written.archive_sha256,
            "payload_bytes": written.payload_bytes,
            "container_overhead_bytes": (
                written.complete_persisted_bytes - written.payload_bytes
            ),
            "previous_database_payload_bytes": PREVIOUS_DATABASE_PAYLOAD_BYTES,
            "improvement_bytes": improvement_bytes,
            "improvement_fraction": (
                improvement_bytes / PREVIOUS_DATABASE_PAYLOAD_BYTES
            ),
            **exactness,
            "corruption_rejected": int(corruption_rejected),
            "mlflow_run_id": active_run.info.run_id,
            "mlflow_tracking_store": "mlflow.db",
            "host": {
                "platform": platform.platform(),
                "machine": platform.machine(),
            },
            "wall_seconds": time.monotonic() - started,
            "production_promoted": False,
            "phone_accessed": False,
            "conclusion_scope": "worldpack_experiment_only",
        }
        RESULT.write_text(json.dumps(result, indent=2) + "\n")
        mlflow.log_params(
            {
                "source_sha256": SOURCE_SHA,
                "similarity_archive_sha256": SIMILARITY_ARCHIVE_SHA,
                "webgraph_archive_sha256": WEBGRAPH_ARCHIVE_SHA,
                "previous_database_payload_bytes": PREVIOUS_DATABASE_PAYLOAD_BYTES,
            }
        )
        mlflow.log_metrics(
            {
                "complete_persisted_bytes": written.complete_persisted_bytes,
                "improvement_bytes": improvement_bytes,
                "byte_equal": exactness["byte_equal"],
                "sha256_equal": exactness["sha256_equal"],
            }
        )
        mlflow.log_artifact(str(RESULT), artifact_path="results")
    print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
