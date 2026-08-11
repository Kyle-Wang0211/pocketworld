from __future__ import annotations

import hashlib
from pathlib import Path
import sqlite3
import struct

import pytest

from sqlite_webgraph_composite import (
    apply_exact_patch,
    build_exact_patch,
    canonical_records_to_match_blobs,
    decode_java_u64_permutation,
    restore_match_blobs,
    validate_match_blobs,
    zero_match_blobs,
)
from webgraph_llp_verify import INPUT_MAGIC


MAX_IMAGE_ID = 2_147_483_647


def _pair_id(first: int, second: int) -> int:
    return first * MAX_IMAGE_ID + second


def _canonical(records: list[tuple[int, int, int, int, int, int, int]]) -> bytes:
    body = b"".join(struct.pack("<B3xQIIIII", *record) for record in records)
    return (
        INPUT_MAGIC
        + (32).to_bytes(4, "little")
        + len(records).to_bytes(8, "little")
        + hashlib.sha256(body).digest()
        + body
    )


def _database(path: Path) -> bytes:
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        PRAGMA page_size=4096;
        CREATE TABLE matches (
          pair_id INTEGER PRIMARY KEY NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB
        );
        CREATE TABLE two_view_geometries (
          pair_id INTEGER PRIMARY KEY NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB,
          config INTEGER NOT NULL
        );
        """
    )
    pair = _pair_id(1, 2)
    first = struct.pack("<IIII", 7, 8, 9, 10)
    second = struct.pack("<II", 11, 12)
    connection.execute("INSERT INTO matches VALUES (?, 2, 2, ?)", (pair, first))
    connection.execute(
        "INSERT INTO two_view_geometries VALUES (?, 1, 2, ?, 2)",
        (pair, second),
    )
    connection.commit()
    connection.close()
    return path.read_bytes()


def test_zero_restore_and_physical_patch_are_exact(tmp_path: Path) -> None:
    database = tmp_path / "source.db"
    original = _database(database)
    pair = _pair_id(1, 2)
    canonical = _canonical(
        [
            (0, pair, 0, 1, 7, 2, 8),
            (0, pair, 1, 1, 9, 2, 10),
            (1, pair, 0, 1, 11, 2, 12),
        ]
    )

    blobs = canonical_records_to_match_blobs(canonical)
    assert blobs == {(0, pair): struct.pack("<IIII", 7, 8, 9, 10), (1, pair): struct.pack("<II", 11, 12)}
    assert validate_match_blobs(database, blobs) == (2, 3)

    zero_match_blobs(database, blobs)
    connection = sqlite3.connect(database)
    assert connection.execute("SELECT hex(data) FROM matches").fetchone()[0] == "00" * 16
    assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    connection.close()

    restore_match_blobs(database, blobs)
    logically_restored = database.read_bytes()
    patch = build_exact_patch(logically_restored, original)
    apply_exact_patch(database, patch)
    assert database.read_bytes() == original


def test_validation_rejects_changed_match_value(tmp_path: Path) -> None:
    database = tmp_path / "source.db"
    _database(database)
    pair = _pair_id(1, 2)
    wrong = {(0, pair): struct.pack("<IIII", 7, 8, 9, 99), (1, pair): struct.pack("<II", 11, 12)}
    with pytest.raises(ValueError, match="content"):
        validate_match_blobs(database, wrong)


def test_canonical_rejects_missing_or_reordered_ordinals() -> None:
    pair = _pair_id(1, 2)
    malformed = _canonical([(0, pair, 1, 1, 7, 2, 8)])
    with pytest.raises(ValueError, match="ordinal"):
        canonical_records_to_match_blobs(malformed)


def test_java_permutation_is_strict_big_endian_u64() -> None:
    assert decode_java_u64_permutation(struct.pack(">QQQ", 2, 0, 1)) == [2, 0, 1]
    with pytest.raises(ValueError, match="permutation"):
        decode_java_u64_permutation(struct.pack(">QQQ", 2, 0, 0))


def test_patch_rejects_wrong_base(tmp_path: Path) -> None:
    source = b"abcdef"
    target = b"abcXef"
    patch = build_exact_patch(source, target)
    path = tmp_path / "value.bin"
    path.write_bytes(b"abcYef")
    with pytest.raises(ValueError, match="base SHA"):
        apply_exact_patch(path, patch)
