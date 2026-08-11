"""Exact SQLite match-graph factoring for the experiment-only WorldPack B arm."""

from __future__ import annotations

from collections import defaultdict
import hashlib
from pathlib import Path
import sqlite3
import struct
from typing import Mapping, Sequence

from webgraph_llp_verify import (
    MAX_IMAGE_ID,
    Arc,
    decode_direct_mapping,
    encode_direct_mapping_v2,
    parse_canonical_records,
    restore_canonical_from_permuted_arcs,
)


_PATCH_MAGIC = b"PWPAT1\0\0"
_PATCH_HEADER = struct.Struct("<8sQQ32s32sI")
_PATCH_RANGE = struct.Struct("<QQ")
_TABLES = {0: "matches", 1: "two_view_geometries"}


def _sha256_bytes(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def _sha256_file(path: Path) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.digest()


def decode_java_u64_permutation(data: bytes) -> list[int]:
    """Decode WebGraph's Java-compatible big-endian u64 permutation."""
    if len(data) % 8:
        raise ValueError("Java permutation length is not divisible by eight")
    values = [value[0] for value in struct.iter_unpack(">Q", data)]
    if sorted(values) != list(range(len(values))):
        raise ValueError("Java values are not a permutation")
    return values


def restore_canonical_from_v1_permutation(
    direct_mapping_v1: bytes,
    permutation: Sequence[int],
    final_arcs: Sequence[Arc],
) -> bytes:
    """Restore canonical record bytes from only the persisted WebGraph pieces."""
    old = decode_direct_mapping(direct_mapping_v1)
    if old.version != 1:
        raise ValueError("persisted mapping must be direct-edge v1")
    if len(permutation) != len(old.features) or sorted(permutation) != list(
        range(len(permutation))
    ):
        raise ValueError("permutation does not cover every feature node")
    if list(final_arcs) != sorted(set(final_arcs)):
        raise ValueError("final graph arcs are not unique canonical order")

    final_arc_ids = {arc: index for index, arc in enumerate(final_arcs)}
    inverse = [0] * len(permutation)
    for old_node, new_node in enumerate(permutation):
        inverse[new_node] = old_node
    old_arcs = sorted((inverse[source], inverse[target]) for source, target in final_arcs)
    if len(old_arcs) != old.unique_arc_count:
        raise ValueError("permuted graph lost or gained a unique arc")
    old_to_new_arc: list[int] = []
    for source, target in old_arcs:
        new_arc = (permutation[source], permutation[target])
        try:
            old_to_new_arc.append(final_arc_ids[new_arc])
        except KeyError as error:
            raise ValueError("permutation does not map an original arc") from error

    features_by_new_node: list[tuple[int, int] | None] = [None] * len(old.features)
    for old_node, new_node in enumerate(permutation):
        features_by_new_node[new_node] = old.features[old_node]
    sidecar_v2 = encode_direct_mapping_v2(
        [value for value in features_by_new_node if value is not None],
        old.groups,
        [old_to_new_arc[arc] for arc in old.arc_sequence],
        old.unique_arc_count,
        old.source_body_sha,
    )
    return restore_canonical_from_permuted_arcs(sidecar_v2, final_arcs)


def canonical_records_to_match_blobs(canonical: bytes) -> dict[tuple[int, int], bytes]:
    """Rebuild exact COLMAP match BLOBs, retaining table, row, and record order."""
    records, _ = parse_canonical_records(canonical)
    blobs: dict[tuple[int, int], bytearray] = defaultdict(bytearray)
    for table, pair_id, ordinal, source_image, source_feature, target_image, target_feature in records:
        if table not in _TABLES:
            raise ValueError("canonical record contains an unknown table")
        if source_image != pair_id // MAX_IMAGE_ID or target_image != pair_id % MAX_IMAGE_ID:
            raise ValueError("canonical record pair identity differs from its images")
        key = (table, pair_id)
        if ordinal != len(blobs[key]) // 8:
            raise ValueError("canonical record ordinal is missing or reordered")
        blobs[key].extend(struct.pack("<II", source_feature, target_feature))
    return {key: bytes(value) for key, value in blobs.items()}


def validate_match_blobs(
    database: Path, blobs: Mapping[tuple[int, int], bytes]
) -> tuple[int, int]:
    """Prove the factored graph covers every non-empty match row byte-for-byte."""
    actual: dict[tuple[int, int], bytes] = {}
    row_count = 0
    connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    try:
        for table_id, table in _TABLES.items():
            for pair_id, rows, columns, data in connection.execute(
                f"SELECT pair_id, rows, cols, data FROM {table} WHERE rows > 0 ORDER BY pair_id"
            ):
                value = bytes(data)
                if int(columns) != 2 or len(value) != int(rows) * 8:
                    raise ValueError(f"{table} row dimensions are invalid")
                actual[(table_id, int(pair_id))] = value
                row_count += int(rows)
    finally:
        connection.close()
    if actual.keys() != blobs.keys():
        raise ValueError("database and canonical graph cover different match rows")
    if any(actual[key] != blobs[key] for key in actual):
        raise ValueError("database and canonical graph match content differs")
    return len(actual), row_count


def _rewrite_match_blobs(
    database: Path,
    blobs: Mapping[tuple[int, int], bytes],
    *,
    zero: bool,
) -> None:
    connection = sqlite3.connect(database)
    try:
        connection.execute("PRAGMA synchronous=FULL")
        connection.execute("BEGIN IMMEDIATE")
        for (table_id, pair_id), restored in sorted(blobs.items()):
            table = _TABLES.get(table_id)
            if table is None:
                raise ValueError("match BLOB map contains an unknown table")
            row = connection.execute(
                f"SELECT rows, cols, length(data) FROM {table} WHERE pair_id=?",
                (pair_id,),
            ).fetchone()
            if row is None:
                raise ValueError(f"{table} pair {pair_id} is missing")
            rows, columns, stored_bytes = (int(value) for value in row)
            if columns != 2 or rows * 8 != len(restored) or stored_bytes != len(restored):
                raise ValueError(f"{table} pair {pair_id} dimensions differ from graph")
            with connection.blobopen(table, "data", pair_id, readonly=False) as blob:
                blob.write(bytes(len(restored)) if zero else restored)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def zero_match_blobs(database: Path, blobs: Mapping[tuple[int, int], bytes]) -> None:
    _rewrite_match_blobs(database, blobs, zero=True)


def restore_match_blobs(database: Path, blobs: Mapping[tuple[int, int], bytes]) -> None:
    _rewrite_match_blobs(database, blobs, zero=False)


def build_exact_patch(base: bytes, target: bytes) -> bytes:
    """Encode only differing byte ranges plus strict base/target identities."""
    if len(base) != len(target):
        raise ValueError("exact patch requires equal base and target lengths")
    ranges: list[tuple[int, bytes]] = []
    start: int | None = None
    for index, (before, after) in enumerate(zip(base, target, strict=True)):
        if before != after and start is None:
            start = index
        elif before == after and start is not None:
            ranges.append((start, target[start:index]))
            start = None
    if start is not None:
        ranges.append((start, target[start:]))
    output = bytearray(
        _PATCH_HEADER.pack(
            _PATCH_MAGIC,
            len(base),
            len(target),
            _sha256_bytes(base),
            _sha256_bytes(target),
            len(ranges),
        )
    )
    for offset, value in ranges:
        output.extend(_PATCH_RANGE.pack(offset, len(value)))
        output.extend(value)
    return bytes(output)


def apply_exact_patch(path: Path, patch: bytes) -> None:
    if len(patch) < _PATCH_HEADER.size:
        raise ValueError("exact patch is truncated")
    magic, base_bytes, target_bytes, base_sha, target_sha, count = _PATCH_HEADER.unpack_from(patch)
    if magic != _PATCH_MAGIC or base_bytes != target_bytes:
        raise ValueError("exact patch header is invalid")
    if path.stat().st_size != base_bytes or _sha256_file(path) != base_sha:
        raise ValueError("exact patch base SHA or length differs")
    position = _PATCH_HEADER.size
    previous_end = 0
    ranges: list[tuple[int, bytes]] = []
    for _ in range(count):
        if position + _PATCH_RANGE.size > len(patch):
            raise ValueError("exact patch range is truncated")
        offset, length = _PATCH_RANGE.unpack_from(patch, position)
        position += _PATCH_RANGE.size
        end = position + length
        if offset < previous_end or offset + length > target_bytes or end > len(patch):
            raise ValueError("exact patch range is overlapping or out of bounds")
        ranges.append((offset, patch[position:end]))
        previous_end = offset + length
        position = end
    if position != len(patch):
        raise ValueError("exact patch has trailing bytes")
    with path.open("r+b") as output:
        for offset, value in ranges:
            output.seek(offset)
            output.write(value)
        output.flush()
    if path.stat().st_size != target_bytes or _sha256_file(path) != target_sha:
        raise ValueError("exact patch target SHA or length differs")
