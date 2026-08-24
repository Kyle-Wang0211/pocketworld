from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest

from experiments.pw_compact_sfm_a.pwcsfma.logical import (
    digest_dataset,
    read_logical_dataset,
)
from experiments.pw_compact_sfm_a.pwcsfma.optimistic_stream import (
    decode_stream,
    encode_database,
)
from experiments.pw_compact_sfm_a.pwcsfma.varint import (
    decode_svarint,
    decode_uvarint,
    encode_svarint,
    encode_uvarint,
)


SCHEMA = """
CREATE TABLE images(
  image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
  name TEXT NOT NULL UNIQUE,
  camera_id INTEGER NOT NULL
);
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


def make_transform_fixture(path: Path) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    connection.executemany(
        "INSERT INTO images(image_id,name,camera_id) VALUES(?,?,?)",
        [(1, "one.jpg", 3), (2, "two.jpg", 3)],
    )
    float_bits = [
        0x00000000,
        0x80000000,
        0x3F800000,
        0x7FC12345,
        0x7F800000,
        0xFF800000,
        0x40000000,
        0x40400000,
        0x40800000,
        0x40A00000,
        0x40C00000,
        0x40E00000,
    ]
    keypoints = b"".join(struct.pack("<I", value) for value in float_bits)
    connection.execute(
        "INSERT INTO keypoints(image_id,rows,cols,data) VALUES(?,?,?,?)",
        (1, 2, 6, keypoints),
    )
    descriptors = bytes((row * 17 + column * 3) & 0xFF for row in range(3) for column in range(128))
    connection.execute(
        "INSERT INTO descriptors(image_id,type,rows,cols,data) "
        "VALUES(?,?,?,?,?)",
        (1, 0, 3, 128, descriptors),
    )
    raw_pairs = [(5, 7), (5, 7), (9, 2), (1, 3)]
    raw_blob = b"".join(struct.pack("<II", *pair) for pair in raw_pairs)
    connection.execute(
        "INSERT INTO matches(pair_id,rows,cols,data) VALUES(?,?,?,?)",
        (2147483649, len(raw_pairs), 2, raw_blob),
    )
    verified_pairs = [(5, 7), (9, 2), (77, 88), (5, 7)]
    verified_blob = b"".join(
        struct.pack("<II", *pair) for pair in verified_pairs
    )
    connection.execute(
        "INSERT INTO two_view_geometries("
        "pair_id,rows,cols,data,config,F,E,H,qvec,tvec"
        ") VALUES(?,?,?,?,?,?,?,?,?,?)",
        (
            2147483649,
            len(verified_pairs),
            2,
            verified_blob,
            6,
            None,
            b"",
            bytes(range(72)),
            b"\x00" * 32,
            b"\xFF" * 24,
        ),
    )
    connection.commit()
    connection.close()


class VarintTest(unittest.TestCase):
    def test_unsigned_round_trip(self) -> None:
        for value in (0, 1, 127, 128, 255, 16384, 2**32 - 1, 2**63 - 1):
            encoded = encode_uvarint(value)
            decoded, offset = decode_uvarint(encoded, 0)
            self.assertEqual(decoded, value)
            self.assertEqual(offset, len(encoded))

    def test_signed_round_trip(self) -> None:
        for value in (
            -(2**32),
            -16384,
            -1,
            0,
            1,
            16384,
            2**32,
        ):
            encoded = encode_svarint(value)
            decoded, offset = decode_svarint(encoded, 0)
            self.assertEqual(decoded, value)
            self.assertEqual(offset, len(encoded))


class OptimisticStreamTest(unittest.TestCase):
    def test_round_trip_preserves_every_logical_value_and_row_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pwcsfma-stream-") as directory:
            database = Path(directory) / "fixture.db"
            make_transform_fixture(database)
            source = read_logical_dataset(database)

            encoded = encode_database(database)
            restored = decode_stream(encoded)

            self.assertEqual(restored, source)
            self.assertEqual(digest_dataset(restored), digest_dataset(source))

    def test_encoding_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pwcsfma-stream-") as directory:
            database = Path(directory) / "fixture.db"
            make_transform_fixture(database)
            self.assertEqual(encode_database(database), encode_database(database))

    def test_truncated_stream_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pwcsfma-stream-") as directory:
            database = Path(directory) / "fixture.db"
            make_transform_fixture(database)
            encoded = encode_database(database)
            with self.assertRaises(ValueError):
                decode_stream(encoded[:-1])


if __name__ == "__main__":
    unittest.main()

