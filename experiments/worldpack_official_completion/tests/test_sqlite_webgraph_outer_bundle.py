from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct

import pytest

from sqlite_webgraph_outer_bundle import (
    WEBGRAPH_OUTER_MAGIC,
    build_database_bundle,
    extract_database_bundle,
    parse_webgraph_outer_envelope,
)
from worldpack import WorldPackCorruption, WorldPackReader


MEMBER_NAMES = (
    "mapping.raw",
    "permutation.java",
    "winner.graph",
    "winner.properties",
    "winner.ef",
)

RESULT_PATH = (
    Path(__file__).resolve().parents[1]
    / "results/worldpack-sqlite-webgraph-outer-complete.json"
)


def _outer_envelope(values: dict[str, bytes]) -> bytes:
    header = bytearray(WEBGRAPH_OUTER_MAGIC)
    payload = bytearray()
    for name in MEMBER_NAMES:
        value = values[name]
        header.extend(struct.pack("<Q", len(value)))
        header.extend(hashlib.sha256(value).digest())
        payload.extend(value)
    return bytes(header + payload)


def test_parse_webgraph_outer_envelope_preserves_every_registered_member() -> None:
    values = {
        "mapping.raw": b"mapping",
        "permutation.java": b"permutation",
        "winner.graph": b"graph",
        "winner.properties": b"properties",
        "winner.ef": b"elias-fano",
    }

    assert parse_webgraph_outer_envelope(_outer_envelope(values)) == values

    corrupt = bytearray(_outer_envelope(values))
    corrupt[-1] ^= 0x80
    with pytest.raises(ValueError, match="SHA-256"):
        parse_webgraph_outer_envelope(bytes(corrupt))


def test_database_bundle_round_trips_precompressed_payloads_and_rejects_corruption(
    tmp_path: Path,
) -> None:
    similarity = tmp_path / "similarity.zpaq"
    webgraph = tmp_path / "webgraph.zpaq"
    similarity.write_bytes(b"similarity-archive")
    webgraph.write_bytes(b"webgraph-archive")
    bundle = tmp_path / "database.pwdb"
    metadata = {
        "schema": "pw_sqlite_webgraph_outer_bundle_v1",
        "source_sha256": "00" * 32,
        "similarity_archive_sha256": hashlib.sha256(
            similarity.read_bytes()
        ).hexdigest(),
        "webgraph_archive_sha256": hashlib.sha256(
            webgraph.read_bytes()
        ).hexdigest(),
    }

    written = build_database_bundle(
        bundle,
        similarity_archive=similarity,
        webgraph_archive=webgraph,
        metadata=metadata,
        scratch_root=tmp_path / "scratch",
    )
    extracted = extract_database_bundle(bundle, tmp_path / "restored")

    assert extracted.metadata == metadata
    assert extracted.similarity_archive.read_bytes() == similarity.read_bytes()
    assert extracted.webgraph_archive.read_bytes() == webgraph.read_bytes()
    assert written.complete_persisted_bytes == bundle.stat().st_size

    reader = WorldPackReader(bundle, codecs=[])
    entry = next(value for value in reader.entries if value.path == "webgraph.zpaq")
    corrupt = tmp_path / "corrupt.pwdb"
    corrupt.write_bytes(bundle.read_bytes())
    with corrupt.open("r+b") as output:
        output.seek(entry.payload_offset)
        value = output.read(1)
        output.seek(-1, 1)
        output.write(bytes((value[0] ^ 0x80,)))
    with pytest.raises(WorldPackCorruption):
        extract_database_bundle(corrupt, tmp_path / "corrupt-restored")

    assert json.loads((tmp_path / "restored/metadata.json").read_text()) == metadata


def test_complete_outer_bundle_is_exact_and_smaller_than_previous_database_member() -> None:
    result = json.loads(RESULT_PATH.read_text())
    assert result["schema"] == (
        "pw_worldpack_sqlite_webgraph_outer_complete_result_v1"
    )
    assert result["source_bytes"] == 198_983_680
    assert result["source_sha256"] == (
        "0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0"
    )
    assert result["similarity_archive_bytes"] == 115_130_088
    assert result["webgraph_archive_bytes"] == 1_443_354
    assert result["complete_persisted_bytes"] < result[
        "previous_database_payload_bytes"
    ]
    assert result["improvement_bytes"] == (
        result["previous_database_payload_bytes"]
        - result["complete_persisted_bytes"]
    )
    assert result["restored_bytes"] == result["source_bytes"]
    assert result["restored_sha256"] == result["source_sha256"]
    assert result["covered_sqlite_rows"] == 3_557
    assert result["match_records"] == 857_844
    assert result["sqlite_integrity_check"] == "ok"
    assert result["byte_equal"] == 1
    assert result["sha256_equal"] == 1
    assert result["corruption_rejected"] == 1
    assert result["production_promoted"] is False
    assert result["phone_accessed"] is False
