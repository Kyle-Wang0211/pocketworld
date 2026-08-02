from __future__ import annotations

import hashlib
import json
import sqlite3
import struct
import sys
from pathlib import Path

import pytest


EXPERIMENT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(EXPERIMENT_ROOT))

from exact_io import ExactFrame, decode_frame, encode_frame  # noqa: E402
from prepare_inputs import (  # noqa: E402
    build_alp_columns,
    build_alp_minimum_columns,
    build_descriptor_pair_chunks,
    prepare_database,
)


MAX_IMAGE_ID = 2_147_483_647


def _pair_id(first: int, second: int) -> int:
    lower, upper = sorted((first, second))
    return lower * MAX_IMAGE_ID + upper


def _descriptor(seed: int) -> bytes:
    return bytes((seed + lane * 3) & 0xFF for lane in range(128))


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _openzl_bundle_tags(bundle: bytes) -> list[int]:
    tags: list[int] = []
    position = 0
    while position < len(bundle):
        length = struct.unpack_from("<I", bundle, position)[0]
        width = bundle[position + 4]
        tag = struct.unpack_from("<I", bundle, position + 5)[0]
        assert width in {1, 2, 4, 8}
        position += 9 + length
        tags.append(tag)
    assert position == len(bundle)
    return tags


def _make_fixture(path: Path) -> bytes:
    database = sqlite3.connect(path)
    database.executescript(
        """
        CREATE TABLE keypoints(
          image_id INTEGER PRIMARY KEY NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB
        );
        CREATE TABLE descriptors(
          image_id INTEGER PRIMARY KEY NOT NULL,
          type INTEGER NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB
        );
        CREATE TABLE matches(
          pair_id INTEGER PRIMARY KEY NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB
        );
        CREATE TABLE two_view_geometries(
          pair_id INTEGER PRIMARY KEY NOT NULL,
          rows INTEGER NOT NULL,
          cols INTEGER NOT NULL,
          data BLOB,
          config INTEGER NOT NULL,
          F BLOB,
          E BLOB,
          H BLOB,
          qvec BLOB,
          tvec BLOB
        );
        """
    )
    descriptors = {
        1: _descriptor(1) + _descriptor(2),
        2: _descriptor(4) + _descriptor(8),
        3: _descriptor(16) + _descriptor(32),
    }
    for image_id, payload in descriptors.items():
        database.execute(
            "INSERT INTO descriptors VALUES(?, 0, 2, 128, ?)",
            (image_id, payload),
        )
        keypoints = b"".join(
            struct.pack("<4f", image_id + row / 4, -0.0, float(row), 1.0)
            for row in range(2)
        )
        database.execute(
            "INSERT INTO keypoints VALUES(?, 2, 4, ?)",
            (image_id, keypoints),
        )
    pairs = {
        (1, 2): [(0, 1), (1, 0)],
        (2, 3): [(0, 0), (1, 1), (1, 1)],
    }
    for (first, second), matches in pairs.items():
        payload = b"".join(struct.pack("<II", *match) for match in matches)
        pair_id = _pair_id(first, second)
        database.execute(
            "INSERT INTO matches VALUES(?, ?, 2, ?)",
            (pair_id, len(matches), payload),
        )
        database.execute(
            "INSERT INTO two_view_geometries VALUES(?, ?, 2, ?, 2, NULL, NULL, NULL, NULL, NULL)",
            (pair_id, len(matches), payload),
        )
    database.commit()
    database.close()
    return b"".join(descriptors[image_id] for image_id in sorted(descriptors))


def test_exact_frame_round_trip_and_corruption_rejection() -> None:
    source = ExactFrame(
        stream_type="float32_column",
        element_width=4,
        count=3,
        ordinal=7,
        payload=struct.pack("<III", 0x80000000, 0x7FC01234, 0x3F800000),
    )
    encoded = encode_frame(source)
    assert decode_frame(encoded) == source

    corrupted = bytearray(encoded)
    corrupted[-1] ^= 1
    with pytest.raises(ValueError, match="SHA-256"):
        decode_frame(bytes(corrupted))


def test_typed_extraction_is_deterministic_reversible_and_read_only(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "fixture.db"
    expected_descriptors = _make_fixture(database_path)
    source_sha = _sha256(database_path)

    first = prepare_database(database_path)
    second = prepare_database(database_path)

    assert first == second
    assert first.source_sha256 == source_sha
    assert _sha256(database_path) == source_sha
    assert first.descriptors.dimension == 128
    assert first.descriptors.node_keys == (
        (1, 0),
        (1, 1),
        (2, 0),
        (2, 1),
        (3, 0),
        (3, 1),
    )
    assert first.descriptors.reconstruct() == expected_descriptors
    assert len(first.descriptors.parents) == 6
    assert sum(parent < 0 for parent in first.descriptors.parents) == 2
    assert all(
        parent < child
        for child, parent in enumerate(first.descriptors.parents)
        if parent >= 0
    )

    assert len(first.keypoint_columns) == 4
    assert all(frame.stream_type == "keypoint_float32_column" for frame in first.keypoint_columns)
    assert all(frame.element_width == 4 for frame in first.keypoint_columns)
    assert all(frame.count == 6 for frame in first.keypoint_columns)
    signed_zero_bits = struct.pack("<I", 0x80000000)
    assert signed_zero_bits in first.keypoint_columns[1].payload

    match_arcs = [arc for arc in first.graph_arcs if arc.table == "matches"]
    geometry_arcs = [
        arc for arc in first.graph_arcs if arc.table == "two_view_geometries"
    ]
    assert len(match_arcs) == 5
    assert len(geometry_arcs) == 5
    assert [(arc.pair_id, arc.row_ordinal) for arc in match_arcs] == sorted(
        (arc.pair_id, arc.row_ordinal) for arc in match_arcs
    )
    assert match_arcs[-1].source == match_arcs[-2].source
    assert match_arcs[-1].target == match_arcs[-2].target
    assert match_arcs[-1].row_ordinal != match_arcs[-2].row_ordinal


def test_malformed_descriptor_dimensions_fail_closed(tmp_path: Path) -> None:
    database_path = tmp_path / "malformed.db"
    expected = _make_fixture(database_path)
    database = sqlite3.connect(database_path)
    database.execute(
        "UPDATE descriptors SET rows = rows + 1 WHERE image_id = 1"
    )
    database.commit()
    database.close()

    assert expected
    with pytest.raises(ValueError, match="descriptor byte length"):
        prepare_database(database_path)


def test_real_pair_chunks_are_local_reversible_typed_bundles(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "pairs.db"
    _make_fixture(database_path)

    chunks = build_descriptor_pair_chunks(
        database_path,
        maximum_matches=2,
        maximum_chunks=2,
        require_disjoint_images=False,
    )

    assert len(chunks) == 2
    assert [chunk.pair_id for chunk in chunks] == sorted(
        chunk.pair_id for chunk in chunks
    )
    assert all(chunk.reconstruct() == chunk.original_descriptors for chunk in chunks)
    assert all(chunk.parents for chunk in chunks)
    assert all(_openzl_bundle_tags(chunk.openzl_bundle) == [1000, 1001, 1002] for chunk in chunks)
    assert len({hashlib.sha256(chunk.openzl_bundle).digest() for chunk in chunks}) == 2


def test_alp_minimum_columns_keep_real_float_bits_and_column_identity(
    tmp_path: Path,
) -> None:
    database_path = tmp_path / "pairs.db"
    _make_fixture(database_path)
    metadata_root = tmp_path / "photos_highres"
    metadata_root.mkdir()
    (metadata_root / "official_tap-2.json").write_text(
        json.dumps(
            {
                "extrinsic": [float(index) for index in range(16)],
                "intrinsics_fxfycxcy": [10.5, 11.5, 12.5, 13.5],
                "t": 100.125,
            }
        )
    )
    (metadata_root / "official_tap-1.json").write_text(
        json.dumps(
            {
                "extrinsic": [float(index + 20) for index in range(16)],
                "intrinsics_fxfycxcy": [20.5, 21.5, 22.5, 23.5],
                "t": 99.875,
            }
        )
    )

    columns = build_alp_minimum_columns(database_path, metadata_root)
    one_value_columns = build_alp_columns(
        database_path,
        metadata_root,
        maximum_keypoint_values=1,
    )
    complete_columns = build_alp_columns(
        database_path,
        metadata_root,
        maximum_keypoint_values=None,
    )

    labels = [column.label for column in columns]
    assert labels == sorted(labels)
    assert labels.count("keypoint_float32_0") == 1
    assert "pose_extrinsic_float32_15" in labels
    assert "pose_intrinsics_float32_3" in labels
    assert "capture_timestamp_float64" in labels
    timestamp = next(
        column for column in columns if column.label == "capture_timestamp_float64"
    )
    assert timestamp.element_type == "float64"
    assert timestamp.payload == struct.pack("<dd", 99.875, 100.125)
    assert all(column.payload for column in columns)
    assert len(
        next(
            column
            for column in one_value_columns
            if column.label == "keypoint_float32_0"
        ).payload
    ) == 4
    assert len(
        next(
            column
            for column in complete_columns
            if column.label == "keypoint_float32_0"
        ).payload
    ) == 6 * 4
