"""Self-contained exact SQLite bundle for similarity forest plus WebGraph."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import struct

from worldpack import MemberSpec, WorldPackReader, WorldPackWriteResult, WorldPackWriter


WEBGRAPH_OUTER_MAGIC = b"PWWGO1\0\0"
_WEBGRAPH_MEMBER_NAMES = (
    "mapping.raw",
    "permutation.java",
    "winner.graph",
    "winner.properties",
    "winner.ef",
)
_WEBGRAPH_MEMBER_HEADER = struct.Struct("<Q32s")


@dataclass(frozen=True)
class ExtractedDatabaseBundle:
    metadata: dict[str, object]
    similarity_archive: Path
    webgraph_archive: Path


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_webgraph_outer_envelope(document: bytes) -> dict[str, bytes]:
    """Parse and authenticate the registered five-member WebGraph envelope."""
    header_bytes = len(WEBGRAPH_OUTER_MAGIC) + len(_WEBGRAPH_MEMBER_NAMES) * (
        _WEBGRAPH_MEMBER_HEADER.size
    )
    if len(document) < header_bytes or not document.startswith(
        WEBGRAPH_OUTER_MAGIC
    ):
        raise ValueError("invalid WebGraph outer envelope")
    position = len(WEBGRAPH_OUTER_MAGIC)
    registered: list[tuple[str, int, bytes]] = []
    for name in _WEBGRAPH_MEMBER_NAMES:
        member_bytes, member_sha = _WEBGRAPH_MEMBER_HEADER.unpack_from(
            document, position
        )
        position += _WEBGRAPH_MEMBER_HEADER.size
        registered.append((name, member_bytes, member_sha))
    members: dict[str, bytes] = {}
    for name, member_bytes, member_sha in registered:
        end = position + member_bytes
        if end > len(document):
            raise ValueError("truncated WebGraph outer member")
        value = document[position:end]
        if hashlib.sha256(value).digest() != member_sha:
            raise ValueError(f"WebGraph outer member SHA-256 mismatch: {name}")
        members[name] = value
        position = end
    if position != len(document):
        raise ValueError("WebGraph outer envelope has trailing bytes")
    return members


def build_database_bundle(
    destination: Path,
    *,
    similarity_archive: Path,
    webgraph_archive: Path,
    metadata: dict[str, object],
    scratch_root: Path,
) -> WorldPackWriteResult:
    """Persist the two already-compressed exact streams without recompression."""
    if metadata.get("schema") != "pw_sqlite_webgraph_outer_bundle_v1":
        raise ValueError("unsupported SQLite WebGraph bundle metadata")
    expected = {
        "similarity_archive_sha256": _sha256_file(similarity_archive),
        "webgraph_archive_sha256": _sha256_file(webgraph_archive),
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ValueError(f"metadata {key} does not match its payload")
    scratch_root.mkdir(parents=True, exist_ok=True)
    metadata_path = scratch_root / "metadata.json"
    metadata_path.write_text(
        json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n"
    )
    return WorldPackWriter(
        destination,
        manifest_sha256=hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
        scratch_root=scratch_root / "writer",
        codecs=[],
    ).write(
        [
            MemberSpec("metadata.json", metadata_path, ("raw",)),
            MemberSpec("similarity.zpaq", similarity_archive, ("raw",)),
            MemberSpec("webgraph.zpaq", webgraph_archive, ("raw",)),
        ]
    )


def extract_database_bundle(
    source: Path, destination: Path
) -> ExtractedDatabaseBundle:
    """Authenticate and extract both exact streams from a database bundle."""
    reader = WorldPackReader(source, codecs=[])
    reader.extract_all(destination)
    metadata_path = destination / "metadata.json"
    metadata = json.loads(metadata_path.read_text())
    if metadata.get("schema") != "pw_sqlite_webgraph_outer_bundle_v1":
        raise ValueError("unsupported SQLite WebGraph bundle metadata")
    similarity_archive = destination / "similarity.zpaq"
    webgraph_archive = destination / "webgraph.zpaq"
    if _sha256_file(similarity_archive) != metadata.get(
        "similarity_archive_sha256"
    ):
        raise ValueError("similarity archive identity differs from metadata")
    if _sha256_file(webgraph_archive) != metadata.get("webgraph_archive_sha256"):
        raise ValueError("WebGraph archive identity differs from metadata")
    return ExtractedDatabaseBundle(
        metadata=metadata,
        similarity_archive=similarity_archive,
        webgraph_archive=webgraph_archive,
    )
