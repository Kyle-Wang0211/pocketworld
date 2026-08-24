import math
from pathlib import Path
import sqlite3
import struct
import tempfile
import unittest

from experiments.pw_compact_sfm_a.pwcsfma.logical import logical_digest


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


def make_database(path: Path, reverse: bool = False) -> None:
    connection = sqlite3.connect(path)
    connection.executescript(SCHEMA)
    image_rows = [(1, "one.jpg", 7), (2, "two.jpg", 7)]
    if reverse:
        image_rows.reverse()
    connection.executemany(
        "INSERT INTO images(image_id,name,camera_id) VALUES(?,?,?)",
        image_rows,
    )
    nan_payload = struct.pack("<I", 0x7FC12345)
    keypoint_blob = (
        struct.pack("<I", 0x3F800000)
        + nan_payload
        + struct.pack("<IIII", 0, 0x80000000, 0x7F800000, 0xFF800000)
    )
    connection.execute(
        "INSERT INTO keypoints(image_id,rows,cols,data) VALUES(?,?,?,?)",
        (1, 1, 6, keypoint_blob),
    )
    descriptor = bytes(range(128))
    connection.execute(
        "INSERT INTO descriptors(image_id,type,rows,cols,data) "
        "VALUES(?,?,?,?,?)",
        (1, 0, 1, 128, descriptor),
    )
    match_blob = struct.pack("<IIII", 3, 4, 1, 2)
    connection.execute(
        "INSERT INTO matches(pair_id,rows,cols,data) VALUES(?,?,?,?)",
        (2147483649, 2, 2, match_blob),
    )
    connection.execute(
        "INSERT INTO two_view_geometries("
        "pair_id,rows,cols,data,config,F,E,H,qvec,tvec"
        ") VALUES(?,?,?,?,?,?,?,?,?,?)",
        (
            2147483649,
            1,
            2,
            struct.pack("<II", 1, 2),
            2,
            None,
            b"",
            bytes(range(72)),
            None,
            b"\x00" * 24,
        ),
    )
    connection.commit()
    connection.close()


class LogicalDigestTest(unittest.TestCase):
    def test_digest_is_independent_of_sql_insert_order(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pwcsfma-logical-") as directory:
            first = Path(directory) / "first.db"
            second = Path(directory) / "second.db"
            make_database(first, reverse=False)
            make_database(second, reverse=True)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(logical_digest(first), logical_digest(second))

    def test_digest_changes_when_match_row_order_changes(self) -> None:
        with tempfile.TemporaryDirectory(prefix="pwcsfma-logical-") as directory:
            first = Path(directory) / "first.db"
            second = Path(directory) / "second.db"
            make_database(first)
            make_database(second)
            connection = sqlite3.connect(second)
            connection.execute(
                "UPDATE matches SET data=? WHERE pair_id=?",
                (struct.pack("<IIII", 1, 2, 3, 4), 2147483649),
            )
            connection.commit()
            connection.close()
            self.assertNotEqual(logical_digest(first), logical_digest(second))


if __name__ == "__main__":
    unittest.main()

