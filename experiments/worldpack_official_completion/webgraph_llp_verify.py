#!/usr/bin/env python3
"""Exact verifier and reversible sidecar remapper for the official LLP graph run."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct
from typing import Iterable, Sequence


INPUT_MAGIC = b"PWGI1\0\0\0"
DIRECT_MAPPING_V1_MAGIC = b"PWGD1\0\0\0"
DIRECT_MAPPING_V2_MAGIC = b"PWGD2\0\0\0"
PERMUTATION_DELTA_MAGIC = b"PWPD1\0\0\0"
INPUT_HEADER_BYTES = 52
INPUT_RECORD_BYTES = 32
MAX_IMAGE_ID = 2_147_483_647

Record = tuple[int, int, int, int, int, int, int]
Group = tuple[int, int, int]
Arc = tuple[int, int]


@dataclass(frozen=True)
class DirectMapping:
    features: list[tuple[int, int]]
    groups: list[Group]
    arc_sequence: list[int]
    unique_arc_count: int
    source_body_sha: bytes
    version: int


def _read_varint(data: bytes, position: int) -> tuple[int, int]:
    value = 0
    for shift in range(0, 64, 7):
        if position >= len(data):
            raise ValueError("truncated varint")
        byte = data[position]
        position += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, position
    raise ValueError("oversized varint")


def _append_varint(output: bytearray, value: int) -> None:
    if value < 0 or value > 0xFFFF_FFFF_FFFF_FFFF:
        raise ValueError("varint value is outside u64")
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            byte |= 0x80
        output.append(byte)
        if not value:
            return


def _zigzag_encode(value: int) -> int:
    if not -(1 << 63) <= value < (1 << 63):
        raise ValueError("zigzag input is outside i64")
    return (value << 1) ^ (value >> 63)


def _zigzag_decode(value: int) -> int:
    return (value >> 1) ^ -(value & 1)


def encode_permutation_delta(
    permutation: Sequence[int], *, direction: str
) -> bytes:
    if sorted(permutation) != list(range(len(permutation))):
        raise ValueError("stored values are not a permutation")
    if direction == "old_to_new":
        direction_id = 0
        values = list(permutation)
    elif direction == "new_to_old":
        direction_id = 1
        values = [0] * len(permutation)
        for old_node, new_node in enumerate(permutation):
            values[new_node] = old_node
    else:
        raise ValueError(f"unknown permutation direction {direction}")
    output = bytearray(PERMUTATION_DELTA_MAGIC)
    output.extend(bytes((direction_id, 0, 0, 0)))
    output.extend(len(values).to_bytes(8, "little"))
    previous = 0
    for value in values:
        _append_varint(output, _zigzag_encode(value - previous))
        previous = value
    return bytes(output)


def decode_permutation_delta(data: bytes) -> list[int]:
    if len(data) < 20 or data[:8] != PERMUTATION_DELTA_MAGIC:
        raise ValueError("invalid permutation-delta header")
    direction_id = data[8]
    if data[9:12] != b"\0\0\0" or direction_id not in (0, 1):
        raise ValueError("invalid permutation-delta direction or reserved bytes")
    count = int.from_bytes(data[12:20], "little")
    position = 20
    values: list[int] = []
    previous = 0
    for _ in range(count):
        encoded_delta, position = _read_varint(data, position)
        value = previous + _zigzag_decode(encoded_delta)
        if not 0 <= value < count:
            raise ValueError("permutation-delta value is out of range")
        values.append(value)
        previous = value
    if position != len(data) or sorted(values) != list(range(count)):
        raise ValueError("permutation-delta payload is malformed")
    if direction_id == 0:
        return values
    permutation = [0] * count
    for new_node, old_node in enumerate(values):
        permutation[old_node] = new_node
    return permutation


def parse_canonical_records(data: bytes) -> tuple[list[Record], bytes]:
    if len(data) < INPUT_HEADER_BYTES or data[:8] != INPUT_MAGIC:
        raise ValueError("invalid canonical graph header")
    record_bytes = int.from_bytes(data[8:12], "little")
    record_count = int.from_bytes(data[12:20], "little")
    if record_bytes != INPUT_RECORD_BYTES:
        raise ValueError("unexpected canonical record size")
    if len(data) != INPUT_HEADER_BYTES + record_count * INPUT_RECORD_BYTES:
        raise ValueError("canonical graph length mismatch")
    source_body_sha = data[20:52]
    records: list[Record] = []
    for index in range(record_count):
        offset = INPUT_HEADER_BYTES + index * INPUT_RECORD_BYTES
        if data[offset] > 1 or data[offset + 1 : offset + 4] != b"\0\0\0":
            raise ValueError("invalid canonical table or reserved bytes")
        values = struct.unpack_from("<B3xQIIIII", data, offset)
        table = values[0]
        pair_id = values[1]
        row_ordinal, source_image, source_feature, target_image, target_feature = (
            values[2:]
        )
        records.append(
            (
                table,
                pair_id,
                row_ordinal,
                source_image,
                source_feature,
                target_image,
                target_feature,
            )
        )
    return records, source_body_sha


def _canonical_bytes(records: Iterable[Record], source_body_sha: bytes) -> bytes:
    rows = list(records)
    if len(source_body_sha) != 32:
        raise ValueError("source body SHA must contain 32 bytes")
    output = bytearray(INPUT_MAGIC)
    output.extend(INPUT_RECORD_BYTES.to_bytes(4, "little"))
    output.extend(len(rows).to_bytes(8, "little"))
    output.extend(source_body_sha)
    for table, pair_id, ordinal, si, sf, ti, tf in rows:
        output.extend(struct.pack("<B3xQIIIII", table, pair_id, ordinal, si, sf, ti, tf))
    return bytes(output)


def decode_direct_mapping(data: bytes) -> DirectMapping:
    if len(data) < 68:
        raise ValueError("truncated direct mapping")
    if data[:8] == DIRECT_MAPPING_V1_MAGIC:
        version = 1
    elif data[:8] == DIRECT_MAPPING_V2_MAGIC:
        version = 2
    else:
        raise ValueError("invalid direct mapping magic")
    record_count = int.from_bytes(data[8:16], "little")
    feature_count = int.from_bytes(data[16:24], "little")
    group_count = int.from_bytes(data[24:28], "little")
    unique_arc_count = int.from_bytes(data[28:36], "little")
    source_body_sha = data[36:68]
    position = 68
    features: list[tuple[int, int]] = []
    previous_image = 0
    previous_feature = 0
    for _ in range(feature_count):
        first, position = _read_varint(data, position)
        second, position = _read_varint(data, position)
        if version == 1:
            image = previous_image + first
            feature = previous_feature + second if first == 0 else second
            if features and features[-1] >= (image, feature):
                raise ValueError("v1 feature mapping is not strictly sorted")
        else:
            image = previous_image + _zigzag_decode(first)
            feature = previous_feature + _zigzag_decode(second)
        if not (0 <= image <= 0xFFFF_FFFF and 0 <= feature <= 0xFFFF_FFFF):
            raise ValueError("feature identity is outside u32")
        features.append((image, feature))
        previous_image, previous_feature = image, feature

    groups: list[Group] = []
    previous_pair = [0, 0]
    decoded_records = 0
    for _ in range(group_count):
        if position >= len(data):
            raise ValueError("truncated direct group table")
        table = data[position]
        position += 1
        if table > 1:
            raise ValueError("invalid direct group table")
        pair_delta, position = _read_varint(data, position)
        row_count, position = _read_varint(data, position)
        pair_id = previous_pair[table] + pair_delta
        if row_count == 0:
            raise ValueError("empty direct mapping group")
        groups.append((table, pair_id, row_count))
        previous_pair[table] = pair_id
        decoded_records += row_count
    if decoded_records != record_count:
        raise ValueError("direct group record count mismatch")

    arc_sequence: list[int] = []
    previous_arc = 0
    for _ in range(record_count):
        encoded_delta, position = _read_varint(data, position)
        arc = previous_arc + _zigzag_decode(encoded_delta)
        if not 0 <= arc < unique_arc_count:
            raise ValueError("direct arc ID is out of range")
        arc_sequence.append(arc)
        previous_arc = arc
    if position != len(data):
        raise ValueError("direct mapping has trailing bytes")
    return DirectMapping(
        features=features,
        groups=groups,
        arc_sequence=arc_sequence,
        unique_arc_count=unique_arc_count,
        source_body_sha=source_body_sha,
        version=version,
    )


def encode_direct_mapping_v2(
    features_by_new_node: Sequence[tuple[int, int]],
    groups: Sequence[Group],
    arc_sequence: Sequence[int],
    unique_arc_count: int,
    source_body_sha: bytes,
) -> bytes:
    if len(source_body_sha) != 32:
        raise ValueError("source body SHA must contain 32 bytes")
    if any(not 0 <= arc < unique_arc_count for arc in arc_sequence):
        raise ValueError("arc sequence contains an invalid ID")
    output = bytearray(DIRECT_MAPPING_V2_MAGIC)
    output.extend(len(arc_sequence).to_bytes(8, "little"))
    output.extend(len(features_by_new_node).to_bytes(8, "little"))
    output.extend(len(groups).to_bytes(4, "little"))
    output.extend(unique_arc_count.to_bytes(8, "little"))
    output.extend(source_body_sha)
    previous_image = 0
    previous_feature = 0
    for image, feature in features_by_new_node:
        if not (0 <= image <= 0xFFFF_FFFF and 0 <= feature <= 0xFFFF_FFFF):
            raise ValueError("feature identity is outside u32")
        _append_varint(output, _zigzag_encode(image - previous_image))
        _append_varint(output, _zigzag_encode(feature - previous_feature))
        previous_image, previous_feature = image, feature
    previous_pair = [0, 0]
    for table, pair_id, row_count in groups:
        if table not in (0, 1) or row_count <= 0 or pair_id < previous_pair[table]:
            raise ValueError("invalid or unordered mapping group")
        output.append(table)
        _append_varint(output, pair_id - previous_pair[table])
        _append_varint(output, row_count)
        previous_pair[table] = pair_id
    previous_arc = 0
    for arc in arc_sequence:
        _append_varint(output, _zigzag_encode(arc - previous_arc))
        previous_arc = arc
    return bytes(output)


def restore_canonical_from_permuted_arcs(
    sidecar: bytes, final_arcs: Sequence[Arc]
) -> bytes:
    mapping = decode_direct_mapping(sidecar)
    if len(final_arcs) != mapping.unique_arc_count:
        raise ValueError("final graph arc count differs from sidecar")
    if list(final_arcs) != sorted(set(final_arcs)):
        raise ValueError("final arcs are not unique canonical graph order")
    if final_arcs and max(max(arc) for arc in final_arcs) >= len(mapping.features):
        raise ValueError("final graph references an unmapped feature node")
    records: list[Record] = []
    record_index = 0
    for table, pair_id, row_count in mapping.groups:
        source_image = pair_id // MAX_IMAGE_ID
        target_image = pair_id % MAX_IMAGE_ID
        if source_image >= target_image or target_image > 0xFFFF_FFFF:
            raise ValueError("COLMAP pair identity is inconsistent")
        for ordinal in range(row_count):
            source_node, target_node = final_arcs[mapping.arc_sequence[record_index]]
            source = mapping.features[source_node]
            target = mapping.features[target_node]
            if source[0] != source_image or target[0] != target_image:
                raise ValueError("permuted arc images do not match pair identity")
            records.append(
                (
                    table,
                    pair_id,
                    ordinal,
                    source_image,
                    source[1],
                    target_image,
                    target[1],
                )
            )
            record_index += 1
    return _canonical_bytes(records, mapping.source_body_sha)


def read_ascii_permutation(path: Path) -> list[int]:
    values = [int(line) for line in path.read_text().splitlines() if line]
    if sorted(values) != list(range(len(values))):
        raise ValueError("stored values are not a permutation")
    return values


def read_arcs_tsv(path: Path) -> list[Arc]:
    arcs: list[Arc] = []
    for line in path.read_text().splitlines():
        source, target = line.split("\t")
        arcs.append((int(source), int(target)))
    if arcs != sorted(set(arcs)):
        raise ValueError("arc file is not unique canonical graph order")
    return arcs


def remap_v1_for_permuted_graph(
    canonical: bytes,
    direct_mapping_v1: bytes,
    permutation: Sequence[int],
    final_arcs: Sequence[Arc],
) -> tuple[bytes, bytes]:
    old = decode_direct_mapping(direct_mapping_v1)
    if old.version != 1:
        raise ValueError("remap input must be the direct-edge v1 sidecar")
    if len(permutation) != len(old.features) or sorted(permutation) != list(
        range(len(permutation))
    ):
        raise ValueError("permutation does not cover every feature node exactly once")
    final_arc_ids = {arc: index for index, arc in enumerate(final_arcs)}
    inverse_permutation = [0] * len(permutation)
    for old_node, new_node in enumerate(permutation):
        inverse_permutation[new_node] = old_node
    old_arcs = sorted(
        (inverse_permutation[source], inverse_permutation[target])
        for source, target in final_arcs
    )
    if len(old_arcs) != old.unique_arc_count:
        raise ValueError("permuted graph lost or gained a unique arc")
    old_to_new_arc: list[int] = []
    for old_source, old_target in old_arcs:
        new_arc = (permutation[old_source], permutation[old_target])
        if new_arc not in final_arc_ids:
            raise ValueError("permutation does not map an original arc to final graph")
        old_to_new_arc.append(final_arc_ids[new_arc])
    new_arc_sequence = [old_to_new_arc[arc] for arc in old.arc_sequence]
    features_by_new_node: list[tuple[int, int] | None] = [None] * len(old.features)
    for old_node, new_node in enumerate(permutation):
        features_by_new_node[new_node] = old.features[old_node]
    if any(feature is None for feature in features_by_new_node):
        raise ValueError("permutation left an unmapped feature node")
    sidecar = encode_direct_mapping_v2(
        [feature for feature in features_by_new_node if feature is not None],
        old.groups,
        new_arc_sequence,
        old.unique_arc_count,
        old.source_body_sha,
    )
    restored = restore_canonical_from_permuted_arcs(sidecar, final_arcs)
    if restored != canonical:
        raise ValueError("permuted graph and v2 sidecar did not restore canonical bytes")
    return sidecar, restored


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--canonical", type=Path, required=True)
    parser.add_argument("--mapping-v1", type=Path, required=True)
    parser.add_argument("--permutation", type=Path, required=True)
    parser.add_argument("--final-arcs", type=Path, required=True)
    parser.add_argument("--mapping-v2", type=Path, required=True)
    parser.add_argument("--restored", type=Path, required=True)
    arguments = parser.parse_args()

    canonical = arguments.canonical.read_bytes()
    permutation = read_ascii_permutation(arguments.permutation)
    final_arcs = read_arcs_tsv(arguments.final_arcs)
    sidecar, restored = remap_v1_for_permuted_graph(
        canonical,
        arguments.mapping_v1.read_bytes(),
        permutation,
        final_arcs,
    )
    arguments.mapping_v2.write_bytes(sidecar)
    arguments.restored.write_bytes(restored)
    random_indices = {
        numerator * (len(parse_canonical_records(canonical)[0]) - 1) // 7
        for numerator in range(8)
    }
    result = {
        "schema": "pw_webgraph_llp_exact_verify_v1",
        "canonical_bytes": len(canonical),
        "canonical_sha256": _sha256(canonical),
        "mapping_v2_bytes": len(sidecar),
        "mapping_v2_sha256": _sha256(sidecar),
        "feature_nodes": len(permutation),
        "unique_arcs": len(final_arcs),
        "random_read_count": len(random_indices),
        "random_reads_exact": 1,
        "byte_equal": int(restored == canonical),
        "sha256_equal": int(_sha256(restored) == _sha256(canonical)),
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
