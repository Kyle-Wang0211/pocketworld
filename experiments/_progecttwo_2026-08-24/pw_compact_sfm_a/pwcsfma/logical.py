from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path
import sqlite3
import struct
from typing import Sequence


_DIGEST_MAGIC = b"PWCSFMA_LOGICAL_V1\x00"


@dataclass(frozen=True)
class Column:
    name: str
    declared_type: str
    not_null: int
    default_value: object
    primary_key_order: int


@dataclass(frozen=True)
class Table:
    name: str
    columns: tuple[Column, ...]
    rows: tuple[tuple[object, ...], ...]


@dataclass(frozen=True)
class LogicalDataset:
    tables: tuple[Table, ...]


def _length_prefix(value: bytes) -> bytes:
    return struct.pack("<Q", len(value)) + value


def _encode_value(value: object) -> bytes:
    if value is None:
        return b"N"
    if isinstance(value, int):
        return b"I" + struct.pack("<q", value)
    if isinstance(value, float):
        return b"F" + struct.pack("<d", value)
    if isinstance(value, str):
        return b"T" + _length_prefix(value.encode("utf-8"))
    if isinstance(value, memoryview):
        value = value.tobytes()
    if isinstance(value, bytes):
        return b"B" + _length_prefix(value)
    raise TypeError(f"unsupported SQLite value type: {type(value)!r}")


def _encode_row(row: Sequence[object]) -> bytes:
    encoded = bytearray(struct.pack("<Q", len(row)))
    for value in row:
        field = _encode_value(value)
        encoded.extend(_length_prefix(field))
    return bytes(encoded)


def _quote_identifier(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def _table_names(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        "SELECT name FROM sqlite_schema "
        "WHERE type='table' "
        "AND (name NOT LIKE 'sqlite_%' OR name='sqlite_sequence') "
        "ORDER BY name"
    )
    return [str(row[0]) for row in rows]


def _table_info(
    connection: sqlite3.Connection, table: str
) -> list[tuple[object, ...]]:
    return list(connection.execute(f"PRAGMA table_info({_quote_identifier(table)})"))


def _table_rows(
    connection: sqlite3.Connection,
    table: str,
    info: Sequence[Sequence[object]],
) -> list[tuple[object, ...]]:
    columns = [str(column[1]) for column in info]
    select_columns = ",".join(_quote_identifier(column) for column in columns)
    primary_key = sorted(
        ((int(column[5]), str(column[1])) for column in info if int(column[5]) > 0)
    )
    query = f"SELECT {select_columns} FROM {_quote_identifier(table)}"
    if primary_key:
        query += " ORDER BY " + ",".join(
            _quote_identifier(column) for _, column in primary_key
        )
        return list(connection.execute(query))
    rows = list(connection.execute(query))
    rows.sort(key=_encode_row)
    return rows


def logical_digest(path: str | Path) -> str:
    return digest_dataset(read_logical_dataset(path))


def read_logical_dataset(path: str | Path) -> LogicalDataset:
    database_path = Path(path).resolve()
    connection = sqlite3.connect(
        f"file:{database_path}?mode=ro&immutable=1",
        uri=True,
    )
    try:
        tables: list[Table] = []
        for table_name in _table_names(connection):
            info = _table_info(connection, table_name)
            columns: list[Column] = []
            for column in info:
                columns.append(
                    Column(
                        name=str(column[1]),
                        declared_type=str(column[2]),
                        not_null=int(column[3]),
                        default_value=column[4],
                        primary_key_order=int(column[5]),
                    )
                )
            rows = _table_rows(connection, table_name, info)
            tables.append(
                Table(
                    name=table_name,
                    columns=tuple(columns),
                    rows=tuple(tuple(row) for row in rows),
                )
            )
        return LogicalDataset(tables=tuple(tables))
    finally:
        connection.close()


def digest_dataset(dataset: LogicalDataset) -> str:
    digest = hashlib.sha256()
    digest.update(_DIGEST_MAGIC)
    digest.update(struct.pack("<Q", len(dataset.tables)))
    for table in dataset.tables:
        digest.update(_length_prefix(table.name.encode("utf-8")))
        digest.update(struct.pack("<Q", len(table.columns)))
        for column in table.columns:
            schema_value = (
                column.name,
                column.declared_type,
                column.not_null,
                column.default_value,
                column.primary_key_order,
            )
            digest.update(_length_prefix(_encode_row(schema_value)))
        digest.update(struct.pack("<Q", len(table.rows)))
        for row in table.rows:
            digest.update(_length_prefix(_encode_row(row)))
    return digest.hexdigest()
