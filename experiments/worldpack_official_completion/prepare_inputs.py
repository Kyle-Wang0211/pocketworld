"""Read-only, deterministic extraction of exact SQLite semantic streams."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import sqlite3
import struct

from exact_io import ExactFrame


MAX_IMAGE_ID = 2_147_483_647


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@dataclass(frozen=True)
class GraphArc:
    table: str
    pair_id: int
    row_ordinal: int
    source: tuple[int, int]
    target: tuple[int, int]


@dataclass(frozen=True)
class DescriptorStreams:
    dimension: int
    node_keys: tuple[tuple[int, int], ...]
    parents: tuple[int, ...]
    root_ordinals: tuple[int, ...]
    residual_ordinals: tuple[int, ...]
    roots: ExactFrame
    residuals: ExactFrame

    def reconstruct(self) -> bytes:
        nodes: list[bytes | None] = [None] * len(self.node_keys)
        for offset, ordinal in enumerate(self.root_ordinals):
            begin = offset * self.dimension
            nodes[ordinal] = self.roots.payload[begin : begin + self.dimension]
        for offset, ordinal in enumerate(self.residual_ordinals):
            parent_ordinal = self.parents[ordinal]
            if parent_ordinal < 0 or parent_ordinal >= ordinal:
                raise ValueError("descriptor parent ordering is invalid")
            parent = nodes[parent_ordinal]
            if parent is None:
                raise ValueError("descriptor parent has not been reconstructed")
            begin = offset * self.dimension
            residual = self.residuals.payload[begin : begin + self.dimension]
            nodes[ordinal] = bytes(
                (parent[lane] + residual[lane]) & 0xFF
                for lane in range(self.dimension)
            )
        if any(node is None for node in nodes):
            raise ValueError("descriptor topology does not cover every node")
        return b"".join(node for node in nodes if node is not None)


@dataclass(frozen=True)
class PreparedInputs:
    source_sha256: str
    descriptors: DescriptorStreams
    keypoint_columns: tuple[ExactFrame, ...]
    keypoint_layout: tuple[tuple[int, int, int], ...]
    graph_arcs: tuple[GraphArc, ...]


@dataclass(frozen=True)
class DescriptorPairChunk:
    pair_id: int
    image_ids: tuple[int, int]
    node_keys: tuple[tuple[int, int], ...]
    parents: tuple[int, ...]
    roots: bytes
    residuals: bytes
    original_descriptors: bytes
    openzl_bundle: bytes

    def reconstruct(self) -> bytes:
        dimension = 128
        nodes: list[bytes | None] = [None] * len(self.node_keys)
        root_offset = 0
        residual_offset = 0
        for ordinal, parent in enumerate(self.parents):
            if parent < 0:
                nodes[ordinal] = self.roots[
                    root_offset : root_offset + dimension
                ]
                root_offset += dimension
            else:
                if parent >= ordinal or nodes[parent] is None:
                    raise ValueError("pair chunk parent ordering is invalid")
                residual = self.residuals[
                    residual_offset : residual_offset + dimension
                ]
                residual_offset += dimension
                parent_value = nodes[parent]
                assert parent_value is not None
                nodes[ordinal] = bytes(
                    (parent_value[lane] + residual[lane]) & 0xFF
                    for lane in range(dimension)
                )
        if root_offset != len(self.roots) or residual_offset != len(self.residuals):
            raise ValueError("pair chunk descriptor streams contain trailing bytes")
        return b"".join(node for node in nodes if node is not None)


def _connect_read_only(database_path: Path) -> sqlite3.Connection:
    uri = f"{database_path.resolve().as_uri()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    connection.execute("PRAGMA query_only = ON")
    return connection


def _table_exists(connection: sqlite3.Connection, table: str) -> bool:
    row = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", (table,)
    ).fetchone()
    return row is not None


def _decode_pair_id(pair_id: int) -> tuple[int, int]:
    if pair_id < 0:
        raise ValueError("pair ID must be non-negative")
    second = pair_id % MAX_IMAGE_ID
    first = (pair_id - second) // MAX_IMAGE_ID
    if first < 0 or second < 0 or first >= second or second >= MAX_IMAGE_ID:
        raise ValueError("pair ID is outside the COLMAP domain")
    return first, second


def _read_match_table(
    connection: sqlite3.Connection, table: str
) -> tuple[GraphArc, ...]:
    if not _table_exists(connection, table):
        return ()
    arcs: list[GraphArc] = []
    rows = connection.execute(
        f'SELECT pair_id, rows, cols, data FROM "{table}" ORDER BY pair_id'
    )
    for pair_id_value, row_count_value, column_count_value, data_value in rows:
        pair_id = int(pair_id_value)
        row_count = int(row_count_value)
        column_count = int(column_count_value)
        payload = bytes(data_value or b"")
        if row_count < 0 or column_count < 2:
            raise ValueError(f"{table} dimensions are invalid")
        expected_bytes = row_count * column_count * 4
        if len(payload) != expected_bytes:
            raise ValueError(f"{table} byte length does not match dimensions")
        first_image, second_image = _decode_pair_id(pair_id)
        for row_ordinal in range(row_count):
            begin = row_ordinal * column_count * 4
            first_feature, second_feature = struct.unpack_from("<II", payload, begin)
            arcs.append(
                GraphArc(
                    table=table,
                    pair_id=pair_id,
                    row_ordinal=row_ordinal,
                    source=(first_image, first_feature),
                    target=(second_image, second_feature),
                )
            )
    return tuple(arcs)


def _read_descriptors(
    connection: sqlite3.Connection, parent_arcs: tuple[GraphArc, ...]
) -> DescriptorStreams:
    rows = connection.execute(
        "SELECT image_id, type, rows, cols, data FROM descriptors ORDER BY image_id"
    )
    node_keys: list[tuple[int, int]] = []
    values: list[bytes] = []
    dimension: int | None = None
    for image_id_value, _type_value, row_count_value, column_count_value, data_value in rows:
        image_id = int(image_id_value)
        row_count = int(row_count_value)
        column_count = int(column_count_value)
        payload = bytes(data_value or b"")
        if row_count < 0 or column_count <= 0:
            raise ValueError("descriptor dimensions are invalid")
        if dimension is None:
            dimension = column_count
        if column_count != dimension:
            raise ValueError("mixed descriptor dimensions are unsupported")
        if len(payload) != row_count * column_count:
            raise ValueError("descriptor byte length does not match dimensions")
        for row_ordinal in range(row_count):
            begin = row_ordinal * column_count
            node_keys.append((image_id, row_ordinal))
            values.append(payload[begin : begin + column_count])
    if not values or dimension is None:
        raise ValueError("descriptor table is empty")

    ordinal_by_key = {key: ordinal for ordinal, key in enumerate(node_keys)}
    earlier_neighbors: list[set[int]] = [set() for _ in node_keys]
    for arc in parent_arcs:
        source = ordinal_by_key.get(arc.source)
        target = ordinal_by_key.get(arc.target)
        if source is None or target is None or source == target:
            continue
        earlier, later = sorted((source, target))
        earlier_neighbors[later].add(earlier)

    parents: list[int] = []
    root_ordinals: list[int] = []
    residual_ordinals: list[int] = []
    roots = bytearray()
    residuals = bytearray()
    for ordinal, value in enumerate(values):
        candidates = earlier_neighbors[ordinal]
        if not candidates:
            parents.append(-1)
            root_ordinals.append(ordinal)
            roots.extend(value)
            continue
        parent = min(
            candidates,
            key=lambda candidate: (
                sum(
                    abs(value[lane] - values[candidate][lane])
                    for lane in range(dimension)
                ),
                candidate,
            ),
        )
        parents.append(parent)
        residual_ordinals.append(ordinal)
        residuals.extend(
            (value[lane] - values[parent][lane]) & 0xFF for lane in range(dimension)
        )

    return DescriptorStreams(
        dimension=dimension,
        node_keys=tuple(node_keys),
        parents=tuple(parents),
        root_ordinals=tuple(root_ordinals),
        residual_ordinals=tuple(residual_ordinals),
        roots=ExactFrame(
            stream_type="descriptor_roots_uint8",
            element_width=dimension,
            count=len(root_ordinals),
            ordinal=0,
            payload=bytes(roots),
        ),
        residuals=ExactFrame(
            stream_type="descriptor_residuals_uint8_mod256",
            element_width=dimension,
            count=len(residual_ordinals),
            ordinal=1,
            payload=bytes(residuals),
        ),
    )


def _read_keypoint_columns(
    connection: sqlite3.Connection,
) -> tuple[tuple[ExactFrame, ...], tuple[tuple[int, int, int], ...]]:
    layout: list[tuple[int, int, int]] = []
    columns: list[bytearray] = []
    total_rows = 0
    expected_columns: int | None = None
    rows = connection.execute(
        "SELECT image_id, rows, cols, data FROM keypoints ORDER BY image_id"
    )
    for image_id_value, row_count_value, column_count_value, data_value in rows:
        image_id = int(image_id_value)
        row_count = int(row_count_value)
        column_count = int(column_count_value)
        payload = bytes(data_value or b"")
        if row_count < 0 or column_count <= 0:
            raise ValueError("keypoint dimensions are invalid")
        if len(payload) != row_count * column_count * 4:
            raise ValueError("keypoint byte length does not match float32 dimensions")
        if expected_columns is None:
            expected_columns = column_count
            columns = [bytearray() for _ in range(column_count)]
        if column_count != expected_columns:
            raise ValueError("mixed keypoint column counts are unsupported")
        layout.append((image_id, row_count, column_count))
        total_rows += row_count
        for row_ordinal in range(row_count):
            for column_ordinal in range(column_count):
                begin = (row_ordinal * column_count + column_ordinal) * 4
                columns[column_ordinal].extend(payload[begin : begin + 4])
    if expected_columns is None:
        return (), ()
    frames = tuple(
        ExactFrame(
            stream_type="keypoint_float32_column",
            element_width=4,
            count=total_rows,
            ordinal=column_ordinal,
            payload=bytes(payload),
        )
        for column_ordinal, payload in enumerate(columns)
    )
    return frames, tuple(layout)


def _typed_bundle_record(element_width: int, tag: int, payload: bytes) -> bytes:
    return struct.pack("<IBI", len(payload), element_width, tag) + payload


def _descriptor_row(
    connection: sqlite3.Connection, image_id: int
) -> tuple[int, bytes]:
    row = connection.execute(
        "SELECT rows, cols, data FROM descriptors WHERE image_id = ?", (image_id,)
    ).fetchone()
    if row is None:
        raise ValueError(f"descriptor row is missing for image {image_id}")
    row_count = int(row[0])
    column_count = int(row[1])
    payload = bytes(row[2] or b"")
    if row_count < 0 or column_count != 128 or len(payload) != row_count * 128:
        raise ValueError("descriptor byte length does not match pair dimensions")
    return row_count, payload


def build_descriptor_pair_chunks(
    database_path: Path,
    *,
    maximum_matches: int,
    maximum_chunks: int,
    require_disjoint_images: bool,
) -> tuple[DescriptorPairChunk, ...]:
    if maximum_matches <= 0 or maximum_chunks <= 0:
        raise ValueError("pair chunk limits must be positive")
    database_path = database_path.resolve()
    source_sha_before = _sha256(database_path)
    connection = _connect_read_only(database_path)
    chunks: list[DescriptorPairChunk] = []
    used_images: set[int] = set()
    try:
        rows = connection.execute(
            "SELECT pair_id, rows, cols, data FROM two_view_geometries "
            "WHERE rows > 0 ORDER BY pair_id"
        )
        for pair_id_value, row_count_value, column_count_value, data_value in rows:
            pair_id = int(pair_id_value)
            first_image, second_image = _decode_pair_id(pair_id)
            if require_disjoint_images and (
                first_image in used_images or second_image in used_images
            ):
                continue
            row_count = int(row_count_value)
            column_count = int(column_count_value)
            payload = bytes(data_value or b"")
            if column_count < 2 or len(payload) != row_count * column_count * 4:
                raise ValueError("two-view byte length does not match pair dimensions")
            selected_edges: list[tuple[tuple[int, int], tuple[int, int]]] = []
            for row_ordinal in range(min(row_count, maximum_matches)):
                begin = row_ordinal * column_count * 4
                first_feature, second_feature = struct.unpack_from(
                    "<II", payload, begin
                )
                selected_edges.append(
                    (
                        (first_image, first_feature),
                        (second_image, second_feature),
                    )
                )
            if not selected_edges:
                continue

            descriptor_rows = {
                first_image: _descriptor_row(connection, first_image),
                second_image: _descriptor_row(connection, second_image),
            }
            node_keys = sorted(
                {node for edge in selected_edges for node in edge}
            )
            values: list[bytes] = []
            for image_id, feature_ordinal in node_keys:
                image_rows, image_payload = descriptor_rows[image_id]
                if feature_ordinal >= image_rows:
                    raise ValueError("two-view feature index exceeds descriptor rows")
                begin = feature_ordinal * 128
                values.append(image_payload[begin : begin + 128])

            ordinal_by_key = {
                key: ordinal for ordinal, key in enumerate(node_keys)
            }
            earlier_neighbors: list[set[int]] = [set() for _ in node_keys]
            for first, second in selected_edges:
                source = ordinal_by_key[first]
                target = ordinal_by_key[second]
                if source == target:
                    continue
                earlier, later = sorted((source, target))
                earlier_neighbors[later].add(earlier)

            parents: list[int] = []
            roots = bytearray()
            residuals = bytearray()
            for ordinal, value in enumerate(values):
                candidates = earlier_neighbors[ordinal]
                if not candidates:
                    parents.append(-1)
                    roots.extend(value)
                    continue
                parent = min(
                    candidates,
                    key=lambda candidate: (
                        sum(
                            abs(value[lane] - values[candidate][lane])
                            for lane in range(128)
                        ),
                        candidate,
                    ),
                )
                parents.append(parent)
                residuals.extend(
                    (value[lane] - values[parent][lane]) & 0xFF
                    for lane in range(128)
                )
            encoded_parents = b"".join(
                struct.pack("<I", parent if parent >= 0 else 0xFFFFFFFF)
                for parent in parents
            )
            bundle = b"".join(
                (
                    _typed_bundle_record(1, 1000, bytes(roots)),
                    _typed_bundle_record(1, 1001, bytes(residuals)),
                    _typed_bundle_record(4, 1002, encoded_parents),
                )
            )
            chunk = DescriptorPairChunk(
                pair_id=pair_id,
                image_ids=(first_image, second_image),
                node_keys=tuple(node_keys),
                parents=tuple(parents),
                roots=bytes(roots),
                residuals=bytes(residuals),
                original_descriptors=b"".join(values),
                openzl_bundle=bundle,
            )
            if chunk.reconstruct() != chunk.original_descriptors:
                raise RuntimeError("pair chunk descriptor transform is not reversible")
            chunks.append(chunk)
            used_images.update((first_image, second_image))
            if len(chunks) == maximum_chunks:
                break
    finally:
        connection.close()
    if _sha256(database_path) != source_sha_before:
        raise RuntimeError("source database changed during pair extraction")
    return tuple(chunks)


def prepare_database(database_path: Path) -> PreparedInputs:
    database_path = database_path.resolve()
    source_sha_before = _sha256(database_path)
    connection = _connect_read_only(database_path)
    try:
        match_arcs = _read_match_table(connection, "matches")
        geometry_arcs = _read_match_table(connection, "two_view_geometries")
        parent_arcs = geometry_arcs if geometry_arcs else match_arcs
        descriptors = _read_descriptors(connection, parent_arcs)
        keypoint_columns, keypoint_layout = _read_keypoint_columns(connection)
    finally:
        connection.close()
    source_sha_after = _sha256(database_path)
    if source_sha_after != source_sha_before:
        raise RuntimeError("source database changed during read-only extraction")
    return PreparedInputs(
        source_sha256=source_sha_before,
        descriptors=descriptors,
        keypoint_columns=keypoint_columns,
        keypoint_layout=keypoint_layout,
        graph_arcs=match_arcs + geometry_arcs,
    )
