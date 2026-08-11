"""Create a semantic WorldPack by dropping physical files and adding raw recipes."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import uuid
import zlib

from worldpack import (
    FileCodec,
    WorldPackEntry,
    WorldPackReader,
    WorldPackWriteResult,
    _CHUNK_HEADER,
    _CHUNK_MAGIC,
    _FILE_HEADER,
    _FILE_MAGIC,
    _FOOTER,
    _FOOTER_MAGIC,
    _VERSION,
    _fsync_directory,
    _sha256_file,
    _validate_codec_id,
    _validate_hex_sha256,
    _validate_relative_path,
)


@dataclass(frozen=True)
class RawAddition:
    relative_path: str
    source_path: Path


def _copy_payload(source_archive: Path, entry: WorldPackEntry, output) -> None:
    digest = hashlib.sha256()
    remaining = entry.payload_bytes
    with source_archive.open("rb") as source:
        source.seek(entry.payload_offset)
        while remaining:
            block = source.read(min(1024 * 1024, remaining))
            if not block:
                raise ValueError("source WorldPack payload is truncated")
            output.write(block)
            digest.update(block)
            remaining -= len(block)
    if digest.hexdigest() != entry.payload_sha256:
        raise ValueError("source WorldPack payload SHA-256 changed")


def _write_chunk_header(output, entry: WorldPackEntry) -> tuple[int, int]:
    path_bytes = _validate_relative_path(entry.path)
    codec_bytes = _validate_codec_id(entry.codec_id)
    variable = path_bytes + codec_bytes
    header_bytes = _CHUNK_HEADER.size + len(variable)
    chunk_offset = output.tell()
    fixed_zero_crc = _CHUNK_HEADER.pack(
        _CHUNK_MAGIC,
        header_bytes,
        len(codec_bytes),
        0,
        entry.dependency_index,
        entry.original_bytes,
        entry.payload_bytes,
        bytes.fromhex(entry.original_sha256),
        bytes.fromhex(entry.payload_sha256),
        len(path_bytes),
        0,
        0,
    )
    header_crc = zlib.crc32(fixed_zero_crc + variable) & 0xFFFFFFFF
    output.write(
        _CHUNK_HEADER.pack(
            _CHUNK_MAGIC,
            header_bytes,
            len(codec_bytes),
            0,
            entry.dependency_index,
            entry.original_bytes,
            entry.payload_bytes,
            bytes.fromhex(entry.original_sha256),
            bytes.fromhex(entry.payload_sha256),
            len(path_bytes),
            0,
            header_crc,
        )
    )
    output.write(variable)
    return chunk_offset, output.tell()


def rewrite_drop_add_raw_members(
    source_archive: Path,
    destination_archive: Path,
    *,
    codecs: list[FileCodec],
    manifest_sha256: str,
    drop_paths: set[str],
    additions: tuple[RawAddition, ...],
) -> WorldPackWriteResult:
    """Reuse retained payloads byte-for-byte and append exact raw semantic members."""
    source_archive = source_archive.resolve()
    destination_archive = destination_archive.resolve()
    if source_archive == destination_archive:
        raise ValueError("semantic rewrite destination must be a new path")
    manifest_digest = _validate_hex_sha256(manifest_sha256, "manifest SHA-256")
    reader = WorldPackReader(source_archive, codecs=codecs)
    existing_paths = set(reader.paths)
    if not drop_paths or not drop_paths.issubset(existing_paths):
        raise ValueError("semantic rewrite drop set is empty or unknown")
    addition_paths = [addition.relative_path for addition in additions]
    if not additions or len(addition_paths) != len(set(addition_paths)):
        raise ValueError("semantic rewrite additions are empty or duplicated")
    retained_paths = existing_paths - drop_paths
    if retained_paths.intersection(addition_paths):
        raise ValueError("semantic addition collides with a retained member")
    for addition in additions:
        _validate_relative_path(addition.relative_path)
        if not addition.source_path.is_file() or addition.source_path.is_symlink():
            raise ValueError("semantic addition must be a regular file")

    old_to_new: dict[int, int] = {}
    retained: list[WorldPackEntry] = []
    for entry in reader.entries:
        if entry.path in drop_paths:
            continue
        old_to_new[entry.chunk_index] = len(retained)
        retained.append(entry)
    for entry in retained:
        if entry.dependency_index >= 0 and entry.dependency_index not in old_to_new:
            raise ValueError("retained reference depends on a dropped member")

    destination_archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination_archive.with_name(
        f".{destination_archive.name}.tmp-{uuid.uuid4().hex}"
    )
    new_entries: list[WorldPackEntry] = []
    try:
        with temporary.open("xb") as output:
            output.write(
                _FILE_HEADER.pack(
                    _FILE_MAGIC,
                    _VERSION,
                    _FILE_HEADER.size,
                    manifest_digest,
                    bytes(16),
                )
            )
            for old in retained:
                new_index = len(new_entries)
                dependency = (
                    old_to_new[old.dependency_index]
                    if old.dependency_index >= 0
                    else -1
                )
                prepared = WorldPackEntry(
                    path=old.path,
                    chunk_index=new_index,
                    chunk_offset=0,
                    payload_offset=0,
                    codec_id=old.codec_id,
                    dependency_index=dependency,
                    original_bytes=old.original_bytes,
                    payload_bytes=old.payload_bytes,
                    original_sha256=old.original_sha256,
                    payload_sha256=old.payload_sha256,
                    candidate_bytes=old.candidate_bytes,
                    rejected_candidates=old.rejected_candidates,
                )
                chunk_offset, payload_offset = _write_chunk_header(output, prepared)
                if old.payload_bytes:
                    _copy_payload(source_archive, old, output)
                new_entries.append(
                    WorldPackEntry(
                        **{
                            **asdict(prepared),
                            "chunk_offset": chunk_offset,
                            "payload_offset": payload_offset,
                        }
                    )
                )
            for addition in additions:
                source = addition.source_path.resolve()
                source_bytes = source.stat().st_size
                source_sha = _sha256_file(source)
                prepared = WorldPackEntry(
                    path=addition.relative_path,
                    chunk_index=len(new_entries),
                    chunk_offset=0,
                    payload_offset=0,
                    codec_id="raw",
                    dependency_index=-1,
                    original_bytes=source_bytes,
                    payload_bytes=source_bytes,
                    original_sha256=source_sha,
                    payload_sha256=source_sha,
                    candidate_bytes=(("raw", source_bytes),),
                    rejected_candidates=(),
                )
                chunk_offset, payload_offset = _write_chunk_header(output, prepared)
                with source.open("rb") as payload:
                    shutil.copyfileobj(payload, output, length=1024 * 1024)
                if _sha256_file(source) != source_sha:
                    raise RuntimeError("semantic addition changed while copying")
                new_entries.append(
                    WorldPackEntry(
                        **{
                            **asdict(prepared),
                            "chunk_offset": chunk_offset,
                            "payload_offset": payload_offset,
                        }
                    )
                )
            index_offset = output.tell()
            index_encoded = json.dumps(
                {
                    "schema": "pw_worldpack_index_v1",
                    "manifest_sha256": manifest_sha256,
                    "entries": [asdict(entry) for entry in new_entries],
                },
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            index_sha = hashlib.sha256(index_encoded).digest()
            output.write(index_encoded)
            footer_zero_crc = _FOOTER.pack(
                _FOOTER_MAGIC, index_offset, len(index_encoded), index_sha, 0
            )
            footer_crc = zlib.crc32(footer_zero_crc) & 0xFFFFFFFF
            output.write(
                _FOOTER.pack(
                    _FOOTER_MAGIC,
                    index_offset,
                    len(index_encoded),
                    index_sha,
                    footer_crc,
                )
            )
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, destination_archive)
        _fsync_directory(destination_archive.parent)
    except Exception:
        temporary.unlink(missing_ok=True)
        raise
    return WorldPackWriteResult(
        complete_persisted_bytes=destination_archive.stat().st_size,
        manifest_sha256=manifest_sha256,
        archive_sha256=_sha256_file(destination_archive),
        header_bytes=_FILE_HEADER.size,
        chunk_header_bytes=sum(
            entry.payload_offset - entry.chunk_offset for entry in new_entries
        ),
        payload_bytes=sum(entry.payload_bytes for entry in new_entries),
        index_bytes=len(index_encoded),
        footer_bytes=_FOOTER.size,
        entries=tuple(new_entries),
    )

