from __future__ import annotations

import hashlib
import json
import sqlite3
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import yaml


COLMAP_MAX_IMAGE_ID = 2_147_483_647


def _sha256_file(source: Path) -> str:
    digest = hashlib.sha256()
    with source.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _pair_id(first: int, second: int) -> int:
    low, high = sorted((first, second))
    return low * COLMAP_MAX_IMAGE_ID + high


@dataclass(frozen=True)
class Photo:
    ordinal: int
    database_image_id: int
    database_name: str
    name: str
    source_bytes: int
    source_sha256: str
    incumbent_path: Path
    incumbent_bytes: int
    incumbent_sha256: str
    metadata_path: Path


@dataclass(frozen=True)
class Edge:
    first: int
    second: int
    verified_rows: int
    median_descriptor_distance: float

    def __post_init__(self) -> None:
        if self.first == self.second:
            raise ValueError("feature edge cannot be a self loop")
        if self.verified_rows <= 0:
            raise ValueError("feature edge must contain verified matches")


@dataclass(frozen=True)
class TreeEdge:
    parent: int
    child: int
    verified_rows: int
    median_descriptor_distance: float


@dataclass(frozen=True)
class PredictionTree:
    root: int
    edges: tuple[TreeEdge, ...]
    maximum_dependency_photos: int


@dataclass(frozen=True)
class CollectionSlice:
    capture_root: Path
    photos: tuple[Photo, ...]
    edges: tuple[Edge, ...]
    tree: PredictionTree


class _DisjointSet:
    def __init__(self, nodes: tuple[int, ...]) -> None:
        self._parent = {node: node for node in nodes}

    def find(self, node: int) -> int:
        parent = self._parent[node]
        if parent != node:
            self._parent[node] = self.find(parent)
        return self._parent[node]

    def union(self, first: int, second: int) -> bool:
        root_first = self.find(first)
        root_second = self.find(second)
        if root_first == root_second:
            return False
        low, high = sorted((root_first, root_second))
        self._parent[high] = low
        return True


def maximum_feature_tree(
    nodes: tuple[int, ...],
    edges: tuple[Edge, ...],
    incumbent_bytes: dict[int, int],
) -> PredictionTree:
    if not nodes or len(set(nodes)) != len(nodes):
        raise ValueError("tree nodes must be non-empty and unique")
    node_set = set(nodes)
    if set(incumbent_bytes) != node_set:
        raise ValueError("incumbent byte map must cover every node")
    if any(edge.first not in node_set or edge.second not in node_set for edge in edges):
        raise ValueError("feature edge references an unknown node")

    centrality = {node: 0 for node in nodes}
    for edge in edges:
        centrality[edge.first] += edge.verified_rows
        centrality[edge.second] += edge.verified_rows
    root = min(
        nodes,
        key=lambda node: (-centrality[node], incumbent_bytes[node], node),
    )

    disjoint = _DisjointSet(nodes)
    selected: list[Edge] = []
    for edge in sorted(
        edges,
        key=lambda value: (
            -value.verified_rows,
            value.median_descriptor_distance,
            min(value.first, value.second),
            max(value.first, value.second),
        ),
    ):
        if disjoint.union(edge.first, edge.second):
            selected.append(edge)
            if len(selected) == len(nodes) - 1:
                break
    if len(selected) != len(nodes) - 1:
        raise ValueError("feature graph is disconnected")

    adjacency: dict[int, list[tuple[int, Edge]]] = {node: [] for node in nodes}
    for edge in selected:
        adjacency[edge.first].append((edge.second, edge))
        adjacency[edge.second].append((edge.first, edge))

    queue = deque([(root, 1)])
    visited = {root}
    oriented: list[TreeEdge] = []
    maximum_depth = 1
    while queue:
        parent, depth = queue.popleft()
        maximum_depth = max(maximum_depth, depth)
        for child, edge in sorted(
            adjacency[parent],
            key=lambda item: (
                -item[1].verified_rows,
                item[1].median_descriptor_distance,
                item[0],
            ),
        ):
            if child in visited:
                continue
            visited.add(child)
            oriented.append(
                TreeEdge(
                    parent=parent,
                    child=child,
                    verified_rows=edge.verified_rows,
                    median_descriptor_distance=edge.median_descriptor_distance,
                )
            )
            queue.append((child, depth + 1))
    return PredictionTree(root, tuple(oriented), maximum_depth)


def _descriptor_matrix(connection: sqlite3.Connection, image_id: int) -> np.ndarray:
    row = connection.execute(
        "SELECT rows, cols, data FROM descriptors WHERE image_id = ?",
        (image_id,),
    ).fetchone()
    if row is None:
        raise ValueError(f"missing descriptors for image {image_id}")
    rows, columns, payload = int(row[0]), int(row[1]), bytes(row[2])
    values = np.frombuffer(payload, dtype=np.uint8)
    if values.size != rows * columns:
        raise ValueError(f"descriptor payload size mismatch for image {image_id}")
    return values.reshape(rows, columns)


def _edge_from_database(
    connection: sqlite3.Connection,
    first: int,
    second: int,
    descriptors: dict[int, np.ndarray],
) -> Edge:
    row = connection.execute(
        "SELECT rows, cols, data FROM two_view_geometries WHERE pair_id = ?",
        (_pair_id(first, second),),
    ).fetchone()
    if row is None or int(row[0]) <= 0 or int(row[1]) != 2:
        raise ValueError(f"missing verified relationship {first}-{second}")
    count = int(row[0])
    matches = np.frombuffer(bytes(row[2]), dtype="<u4")
    if matches.size != count * 2:
        raise ValueError(f"verified relationship payload mismatch {first}-{second}")
    matches = matches.reshape(count, 2)
    first_descriptors = descriptors[first]
    second_descriptors = descriptors[second]
    if (
        int(matches[:, 0].max(initial=0)) >= len(first_descriptors)
        or int(matches[:, 1].max(initial=0)) >= len(second_descriptors)
    ):
        raise ValueError(f"verified match index exceeds descriptors {first}-{second}")
    delta = (
        first_descriptors[matches[:, 0]].astype(np.int16)
        - second_descriptors[matches[:, 1]].astype(np.int16)
    )
    squared_distance = np.sum(delta.astype(np.int32) ** 2, axis=1, dtype=np.int64)
    return Edge(first, second, count, float(np.median(squared_distance)))


def extract_collection_slice(manifest_path: Path) -> CollectionSlice:
    manifest_path = Path(manifest_path)
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    capture_root = Path(manifest["capture"]["root"])
    for item in manifest["context_files"]:
        source = capture_root / item["path"]
        if source.stat().st_size != int(item["bytes"]):
            raise ValueError(f"frozen context length changed: {item['path']}")
        if _sha256_file(source) != item["sha256"]:
            raise ValueError(f"frozen context SHA-256 changed: {item['path']}")

    bundle = json.loads((capture_root / "official_photo_bundle.json").read_bytes())
    archive = json.loads((capture_root / "official_photo_archive.json").read_bytes())
    sparse = json.loads((capture_root / "official_sfm_sparse_meta.json").read_bytes())
    ordinals = tuple(int(value) for value in manifest["selection"]["capture_ordinals"])
    if ordinals != tuple(range(8)):
        raise ValueError("frozen photo selection changed")
    registered = {
        int(item["frame_id"])
        for item in sparse["poses"]
        if item.get("registered") is True
    }
    if not set(ordinals).issubset(registered):
        raise ValueError("one or more frozen photos lost SfM registration")

    database_path = capture_root / "official_sfm_live.db"
    connection = sqlite3.connect(f"file:{database_path}?mode=ro&immutable=1", uri=True)
    try:
        photos: list[Photo] = []
        for ordinal, expected in zip(ordinals, manifest["photos"], strict=True):
            frame = bundle["frames"][ordinal]
            name = str(frame["highresFilename"])
            if name != expected["name"]:
                raise ValueError(f"photo selection identity changed at ordinal {ordinal}")
            archived = archive["entries"][name]
            image_id = ordinal + 1
            database_row = connection.execute(
                "SELECT name FROM images WHERE image_id = ?", (image_id,)
            ).fetchone()
            if database_row is None:
                raise ValueError(f"missing database image {image_id}")
            incumbent_path = capture_root / archived["archive_relative_path"]
            metadata_path = capture_root / "photos_highres" / name.replace(".jpg", ".json")
            if incumbent_path.stat().st_size != int(expected["archive_bytes"]):
                raise ValueError(f"incumbent length changed: {name}")
            if _sha256_file(incumbent_path) != expected["archive_sha256"]:
                raise ValueError(f"incumbent SHA-256 changed: {name}")
            if metadata_path.stat().st_size != int(expected["metadata_bytes"]):
                raise ValueError(f"metadata length changed: {name}")
            if _sha256_file(metadata_path) != expected["metadata_sha256"]:
                raise ValueError(f"metadata SHA-256 changed: {name}")
            photos.append(
                Photo(
                    ordinal=ordinal,
                    database_image_id=image_id,
                    database_name=str(database_row[0]),
                    name=name,
                    source_bytes=int(expected["source_bytes"]),
                    source_sha256=str(expected["source_sha256"]),
                    incumbent_path=incumbent_path,
                    incumbent_bytes=int(expected["archive_bytes"]),
                    incumbent_sha256=str(expected["archive_sha256"]),
                    metadata_path=metadata_path,
                )
            )

        nodes = tuple(photo.database_image_id for photo in photos)
        descriptors = {node: _descriptor_matrix(connection, node) for node in nodes}
        edges = tuple(
            _edge_from_database(connection, first, second, descriptors)
            for first in nodes
            for second in nodes
            if first < second
        )
    finally:
        connection.close()

    tree = maximum_feature_tree(
        nodes,
        edges,
        {photo.database_image_id: photo.incumbent_bytes for photo in photos},
    )
    if len(edges) != int(manifest["selection"]["relationship_edges"]):
        raise ValueError("frozen relationship edge count changed")
    if sum(edge.verified_rows for edge in edges) != int(
        manifest["selection"]["verified_match_rows"]
    ):
        raise ValueError("frozen verified match count changed")
    return CollectionSlice(capture_root, tuple(photos), edges, tree)

