"""Rewrite one verified WorldPack member without rerunning unrelated codecs."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
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
class PreverifiedPayloadEvidence:
    payload_sha256: str
    source_bytes: int
    source_sha256: str
    byte_equal: bool
    sha256_equal: bool
    corruption_rejected: bool


def _copy_registered_payload(
    source_archive: Path,
    entry: WorldPackEntry,
    output,
) -> None:
    digest = hashlib.sha256()
    remaining = entry.payload_bytes
    with source_archive.open("rb") as source:
        source.seek(entry.payload_offset)
        while remaining:
            block = source.read(min(1024 * 1024, remaining))
            if not block:
                raise ValueError("source WorldPack payload is truncated")
            digest.update(block)
            output.write(block)
            remaining -= len(block)
    if digest.hexdigest() != entry.payload_sha256:
        raise ValueError("source WorldPack payload SHA-256 changed")


def rewrite_member_payload(
    source_archive: Path,
    destination_archive: Path,
    *,
    codecs: list[FileCodec],
    member_path: str,
    expected_source_path: Path,
    replacement_codec_id: str,
    replacement_payload: Path,
    preverified: PreverifiedPayloadEvidence | None = None,
) -> WorldPackWriteResult:
    """Replace one payload after decoding it against the registered source."""
    source_archive = source_archive.resolve()
    destination_archive = destination_archive.resolve()
    if source_archive == destination_archive:
        raise ValueError("WorldPack rewrite destination must be a new path")
    codec_map = {codec.codec_id: codec for codec in codecs}
    if len(codec_map) != len(codecs):
        raise ValueError("duplicate codec identity")
    replacement_codec = codec_map.get(replacement_codec_id)
    if replacement_codec is None:
        raise ValueError("replacement codec is not registered")
    _validate_codec_id(replacement_codec_id)
    reader = WorldPackReader(source_archive, codecs=codecs)
    try:
        replaced_index = reader.paths.index(member_path)
    except ValueError as error:
        raise KeyError(f"source WorldPack does not contain {member_path!r}") from error
    replaced = reader.entries[replaced_index]
    if (
        not expected_source_path.is_file()
        or expected_source_path.stat().st_size != replaced.original_bytes
        or _sha256_file(expected_source_path) != replaced.original_sha256
    ):
        raise ValueError("replacement source identity differs from WorldPack member")
    replacement_sha = _sha256_file(replacement_payload)
    replacement_bytes = replacement_payload.stat().st_size
    if preverified is not None:
        if (
            preverified.payload_sha256 != replacement_sha
            or preverified.source_bytes != replaced.original_bytes
            or preverified.source_sha256 != replaced.original_sha256
            or not preverified.byte_equal
            or not preverified.sha256_equal
            or not preverified.corruption_rejected
        ):
            raise ValueError("prior replacement evidence does not bind exact identities")
    else:
        with tempfile.TemporaryDirectory(
            prefix="worldpack-rewrite-verify-"
        ) as directory:
            restored = Path(directory) / "restored"
            replacement_codec.decode_file(replacement_payload, restored)
            if (
                not restored.is_file()
                or restored.stat().st_size != replaced.original_bytes
                or _sha256_file(restored) != replaced.original_sha256
            ):
                raise ValueError(
                    "replacement payload does not restore the source member"
                )
    if _sha256_file(replacement_payload) != replacement_sha:
        raise RuntimeError("replacement decoder mutated its encoded payload")

    destination_archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination_archive.with_name(
        f".{destination_archive.name}.tmp-{uuid.uuid4().hex}"
    )
    manifest_digest = _validate_hex_sha256(
        reader.manifest_sha256, "manifest SHA-256"
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
            for entry in reader.entries:
                path_bytes = _validate_relative_path(entry.path)
                if entry.chunk_index == replaced_index:
                    codec_id = replacement_codec_id
                    codec_bytes = _validate_codec_id(codec_id)
                    payload_bytes = replacement_bytes
                    payload_sha = replacement_sha
                    candidate_bytes = (
                        (replacement_codec_id, replacement_bytes),
                        *tuple(
                            candidate
                            for candidate in entry.candidate_bytes
                            if candidate[0] != replacement_codec_id
                        ),
                    )
                else:
                    codec_id = entry.codec_id
                    codec_bytes = _validate_codec_id(codec_id)
                    payload_bytes = entry.payload_bytes
                    payload_sha = entry.payload_sha256
                    candidate_bytes = entry.candidate_bytes
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
                    payload_bytes,
                    bytes.fromhex(entry.original_sha256),
                    bytes.fromhex(payload_sha),
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
                        payload_bytes,
                        bytes.fromhex(entry.original_sha256),
                        bytes.fromhex(payload_sha),
                        len(path_bytes),
                        0,
                        header_crc,
                    )
                )
                output.write(variable)
                payload_offset = output.tell()
                if entry.chunk_index == replaced_index:
                    with replacement_payload.open("rb") as payload:
                        shutil.copyfileobj(payload, output, length=1024 * 1024)
                else:
                    _copy_registered_payload(source_archive, entry, output)
                new_entries.append(
                    WorldPackEntry(
                        path=entry.path,
                        chunk_index=entry.chunk_index,
                        chunk_offset=chunk_offset,
                        payload_offset=payload_offset,
                        codec_id=codec_id,
                        dependency_index=entry.dependency_index,
                        original_bytes=entry.original_bytes,
                        payload_bytes=payload_bytes,
                        original_sha256=entry.original_sha256,
                        payload_sha256=payload_sha,
                        candidate_bytes=tuple(candidate_bytes),
                        rejected_candidates=entry.rejected_candidates,
                    )
                )
            index_offset = output.tell()
            index_encoded = json.dumps(
                {
                    "schema": "pw_worldpack_index_v1",
                    "manifest_sha256": reader.manifest_sha256,
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
    complete_bytes = destination_archive.stat().st_size
    return WorldPackWriteResult(
        complete_persisted_bytes=complete_bytes,
        manifest_sha256=reader.manifest_sha256,
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
