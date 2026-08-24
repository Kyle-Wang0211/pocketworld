from __future__ import annotations

import argparse
import filecmp
import hashlib
import json
import os
from pathlib import Path
import resource
import sqlite3
import subprocess
import tempfile
import time

from experiments.pw_compact_sfm_a.pwcsfma.logical import (
    digest_dataset,
    read_logical_dataset,
)
from experiments.pw_compact_sfm_a.pwcsfma.optimistic_stream import (
    decode_stream,
    encode_database,
)


FIRST_SCREEN_BYTES = 50_008_064
FIRST_SCREEN_SHA256 = (
    "d71b3c54843ae3b25cb2269e723a0c33612a4a2bade08ff97f85a6108ce0bfe7"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _integrity_check(path: Path) -> str:
    connection = sqlite3.connect(f"file:{path.resolve()}?mode=ro&immutable=1", uri=True)
    try:
        row = connection.execute("PRAGMA integrity_check").fetchone()
        return "" if row is None else str(row[0])
    finally:
        connection.close()


def _run_zpaq(
    zpaq_cli: Path,
    operation: str,
    source: Path,
    destination: Path,
) -> int:
    started = time.monotonic_ns()
    subprocess.run(
        [zpaq_cli, operation, source, destination],
        check=True,
        capture_output=True,
        text=True,
    )
    return (time.monotonic_ns() - started) // 1_000_000


def _persist_json(path: Path, result: dict[str, object]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    )
    os.replace(temporary, path)
    json.loads(path.read_text())


def run_potential(
    *,
    input_path: str | Path,
    output_dir: str | Path,
    zpaq_cli: str | Path,
    expected_sha256: str,
    expected_bytes: int,
) -> dict[str, object]:
    source = Path(input_path).resolve()
    output = Path(output_dir).resolve()
    cli = Path(zpaq_cli).resolve()
    output.mkdir(parents=True, exist_ok=True)

    source_bytes = source.stat().st_size
    source_sha256_before = _sha256(source)
    if source_bytes != expected_bytes:
        raise ValueError(
            f"source length {source_bytes} does not match {expected_bytes}"
        )
    if source_sha256_before != expected_sha256:
        raise ValueError("source SHA-256 does not match the frozen input")
    integrity = _integrity_check(source)
    if integrity != "ok":
        raise ValueError(f"SQLite integrity_check failed: {integrity}")

    started = time.monotonic_ns()
    source_dataset = read_logical_dataset(source)
    source_logical_digest = digest_dataset(source_dataset)
    normalized = encode_database(source)
    decoded = decode_stream(normalized)
    logical_exact = decoded == source_dataset
    logical_digest_exact = digest_dataset(decoded) == source_logical_digest
    if not logical_exact or not logical_digest_exact:
        raise ValueError("normalized stream changed logical data")

    with tempfile.TemporaryDirectory(prefix="work-", dir=output) as work_name:
        work = Path(work_name)
        normalized_path = work / "candidate.pwcsfma"
        normalized_archive = work / "candidate.pwcsfma.zpaq"
        normalized_restored = work / "candidate.pwcsfma.restored"
        raw_archive = work / "source.db.zpaq"
        raw_restored = work / "source.db.restored"
        normalized_path.write_bytes(normalized)

        raw_compress_ms = _run_zpaq(cli, "compress", source, raw_archive)
        raw_decompress_ms = _run_zpaq(
            cli, "decompress", raw_archive, raw_restored
        )
        normalized_compress_ms = _run_zpaq(
            cli, "compress", normalized_path, normalized_archive
        )
        normalized_decompress_ms = _run_zpaq(
            cli, "decompress", normalized_archive, normalized_restored
        )

        raw_file_exact = filecmp.cmp(source, raw_restored, shallow=False)
        normalized_stream_exact = filecmp.cmp(
            normalized_path, normalized_restored, shallow=False
        )
        restored_dataset = decode_stream(normalized_restored.read_bytes())
        restored_logical_exact = restored_dataset == source_dataset
        if not raw_file_exact:
            raise ValueError("raw ZPAQ round trip changed SQLite bytes")
        if not normalized_stream_exact or not restored_logical_exact:
            raise ValueError("candidate ZPAQ round trip changed logical data")

        raw_archive_bytes = raw_archive.stat().st_size
        normalized_archive_bytes = normalized_archive.stat().st_size
        candidate_fraction = normalized_archive_bytes / raw_archive_bytes
        size_gate_passed = candidate_fraction <= 0.90
        result: dict[str, object] = {
            "schema": "pw_compact_sfm_a_host_screen_v1",
            "source": {
                "path": str(source),
                "bytes": source_bytes,
                "sha256": source_sha256_before,
                "logical_sha256": source_logical_digest,
                "sqlite_integrity_check": integrity,
            },
            "normalized_stream": {
                "bytes": len(normalized),
                "sha256": hashlib.sha256(normalized).hexdigest(),
            },
            "archives": {
                "raw_zpaq_bytes": raw_archive_bytes,
                "raw_zpaq_sha256": _sha256(raw_archive),
                "normalized_zpaq_bytes": normalized_archive_bytes,
                "normalized_zpaq_sha256": _sha256(normalized_archive),
                "candidate_fraction_of_baseline": candidate_fraction,
                "candidate_reduction_vs_baseline": 1.0 - candidate_fraction,
            },
            "elapsed_ms": {
                "total": (time.monotonic_ns() - started) // 1_000_000,
                "raw_compress": raw_compress_ms,
                "raw_decompress": raw_decompress_ms,
                "normalized_compress": normalized_compress_ms,
                "normalized_decompress": normalized_decompress_ms,
            },
            "peak_rss_bytes": max(
                resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
                resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
            ),
            "exactness": {
                "source_unchanged": _sha256(source) == source_sha256_before,
                "raw_file_round_trip": raw_file_exact,
                "normalized_stream_round_trip": normalized_stream_exact,
                "logical_digest_round_trip": restored_logical_exact,
            },
            "size_gate_passed": size_gate_passed,
            "verdict": (
                "continue-to-portable-codec"
                if size_gate_passed
                else "reject-keep-raw-zpaq"
            ),
        }
        _persist_json(output / "result.json", result)
        return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--zpaq-cli",
        type=Path,
        default=Path("/private/tmp/pwcsfma-tests/zpaq_file_cli"),
    )
    parser.add_argument("--expected-sha256", default=FIRST_SCREEN_SHA256)
    parser.add_argument("--expected-bytes", type=int, default=FIRST_SCREEN_BYTES)
    arguments = parser.parse_args()
    result = run_potential(
        input_path=arguments.input,
        output_dir=arguments.output_dir,
        zpaq_cli=arguments.zpaq_cli,
        expected_sha256=arguments.expected_sha256,
        expected_bytes=arguments.expected_bytes,
    )
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
