"""Experiment-only append-only WorldPack container with strict exactness gates."""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import tempfile
from typing import Callable, Iterable, Sequence
import uuid
import zlib


_FILE_MAGIC = b"PWWPK1\x00\x00"
_CHUNK_MAGIC = b"PWCHN1\x00\x00"
_FOOTER_MAGIC = b"PWFTR1\x00\x00"
_FILE_HEADER = struct.Struct("<8sII32s16s")
_CHUNK_HEADER = struct.Struct("<8sIHHqQQ32s32sIII")
_FOOTER = struct.Struct("<8sQQ32sI")
_VERSION = 1


class WorldPackCorruption(ValueError):
    """Raised before any damaged member bytes are returned."""


@dataclass(frozen=True)
class FileCodec:
    codec_id: str
    encode_file: Callable[[Path, Path], None]
    decode_file: Callable[[Path, Path], None]


@dataclass(frozen=True)
class MemberSpec:
    relative_path: str
    source_path: Path
    candidate_codec_ids: tuple[str, ...]


@dataclass(frozen=True)
class WorldPackEntry:
    path: str
    chunk_index: int
    chunk_offset: int
    payload_offset: int
    codec_id: str
    dependency_index: int
    original_bytes: int
    payload_bytes: int
    original_sha256: str
    payload_sha256: str
    candidate_bytes: tuple[tuple[str, int], ...]
    rejected_candidates: tuple[str, ...]


@dataclass(frozen=True)
class WorldPackWriteResult:
    complete_persisted_bytes: int
    manifest_sha256: str
    archive_sha256: str
    header_bytes: int
    chunk_header_bytes: int
    payload_bytes: int
    index_bytes: int
    footer_bytes: int
    entries: tuple[WorldPackEntry, ...]


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _copy_exact(source: Path, destination: Path) -> None:
    with source.open("rb") as reader, destination.open("wb") as writer:
        shutil.copyfileobj(reader, writer, length=1024 * 1024)


def _validate_hex_sha256(value: str, label: str) -> bytes:
    try:
        decoded = bytes.fromhex(value)
    except ValueError as error:
        raise ValueError(f"{label} is not hexadecimal") from error
    if len(decoded) != 32:
        raise ValueError(f"{label} must contain exactly 32 bytes")
    return decoded


def _validate_relative_path(value: str) -> bytes:
    path = PurePosixPath(value)
    if (
        not value
        or path.is_absolute()
        or ".." in path.parts
        or "." in path.parts
        or path.as_posix() != value
        or "\\" in value
    ):
        raise ValueError(f"non-canonical WorldPack path: {value!r}")
    encoded = value.encode("utf-8")
    if len(encoded) > 0xFFFFFFFF:
        raise ValueError("WorldPack path is too long")
    return encoded


def _validate_codec_id(value: str) -> bytes:
    if not value or len(value) > 255 or not all(
        character.islower() or character.isdigit() or character in "_.-"
        for character in value
    ):
        raise ValueError(f"invalid WorldPack codec identity: {value!r}")
    return value.encode("ascii")


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class WorldPackWriter:
    def __init__(
        self,
        output_path: Path,
        *,
        manifest_sha256: str,
        scratch_root: Path,
        codecs: Iterable[FileCodec],
    ) -> None:
        self.output_path = output_path.resolve()
        self.manifest_sha256 = manifest_sha256
        self._manifest_digest = _validate_hex_sha256(
            manifest_sha256, "manifest SHA-256"
        )
        self.scratch_root = scratch_root.resolve()
        codec_values = tuple(codecs)
        self.codecs = {codec.codec_id: codec for codec in codec_values}
        if len(self.codecs) != len(codec_values):
            raise ValueError("duplicate codec identity")
        if "raw" in self.codecs or "reference" in self.codecs:
            raise ValueError("raw and reference are reserved codec identities")
        for codec_id in self.codecs:
            _validate_codec_id(codec_id)

    def _select_candidate(
        self,
        spec: MemberSpec,
        temporary: Path,
        source_bytes: int,
        source_sha256: str,
    ) -> tuple[str, Path, tuple[tuple[str, int], ...], tuple[str, ...]]:
        if not spec.candidate_codec_ids:
            raise ValueError(f"{spec.relative_path} has no registered candidate")
        if len(set(spec.candidate_codec_ids)) != len(spec.candidate_codec_ids):
            raise ValueError(f"{spec.relative_path} repeats a candidate codec")
        valid: list[tuple[str, Path, int]] = []
        rejected: list[str] = []
        for ordinal, codec_id in enumerate(spec.candidate_codec_ids):
            _validate_codec_id(codec_id)
            if codec_id == "reference":
                raise ValueError("reference is selected only by content identity")
            if codec_id == "raw":
                valid.append((codec_id, spec.source_path, source_bytes))
                continue
            codec = self.codecs.get(codec_id)
            if codec is None:
                raise ValueError(f"unknown candidate codec: {codec_id}")
            encoded = temporary / f"candidate-{ordinal}.encoded"
            restored = temporary / f"candidate-{ordinal}.restored"
            try:
                codec.encode_file(spec.source_path, encoded)
                if not encoded.is_file():
                    raise ValueError("encoder did not create an artifact")
                codec.decode_file(encoded, restored)
                if (
                    not restored.is_file()
                    or restored.stat().st_size != source_bytes
                    or _sha256_file(restored) != source_sha256
                ):
                    raise ValueError("candidate did not restore exact source bytes")
            except Exception as error:  # codec failure is evidence, never a winner
                rejected.append(f"{codec_id}:{type(error).__name__}:{error}")
                encoded.unlink(missing_ok=True)
                restored.unlink(missing_ok=True)
                continue
            valid.append((codec_id, encoded, encoded.stat().st_size))
            restored.unlink(missing_ok=True)
        if not valid:
            detail = "; ".join(rejected) or "no valid artifact"
            raise ValueError(
                f"no exact candidate remains for {spec.relative_path}: {detail}"
            )
        selected = min(enumerate(valid), key=lambda item: (item[1][2], item[0]))[1]
        candidate_bytes = tuple((codec_id, size) for codec_id, _, size in valid)
        return selected[0], selected[1], candidate_bytes, tuple(rejected)

    def write(self, members: Sequence[MemberSpec]) -> WorldPackWriteResult:
        if not members:
            raise ValueError("WorldPack requires at least one member")
        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        self.scratch_root.mkdir(parents=True, exist_ok=True)
        temporary_output = self.output_path.with_name(
            f".{self.output_path.name}.tmp-{uuid.uuid4().hex}"
        )
        entries: list[WorldPackEntry] = []
        seen_paths: set[str] = set()
        content_owner: dict[tuple[int, str], int] = {}
        try:
            with tempfile.TemporaryDirectory(
                prefix="worldpack-writer-", dir=self.scratch_root
            ) as scratch_name, temporary_output.open("xb") as output:
                scratch = Path(scratch_name)
                output.write(
                    _FILE_HEADER.pack(
                        _FILE_MAGIC,
                        _VERSION,
                        _FILE_HEADER.size,
                        self._manifest_digest,
                        bytes(16),
                    )
                )
                for index, spec in enumerate(members):
                    path_bytes = _validate_relative_path(spec.relative_path)
                    if spec.relative_path in seen_paths:
                        raise ValueError(f"duplicate WorldPack path: {spec.relative_path}")
                    seen_paths.add(spec.relative_path)
                    source_path = spec.source_path.resolve()
                    if not source_path.is_file() or source_path.is_symlink():
                        raise ValueError(f"source is not a regular file: {source_path}")
                    source_before = source_path.stat()
                    source_sha = _sha256_file(source_path)
                    source_bytes = source_before.st_size
                    source_after = source_path.stat()
                    if (source_before.st_size, source_before.st_mtime_ns) != (
                        source_after.st_size,
                        source_after.st_mtime_ns,
                    ):
                        raise RuntimeError(f"source changed while hashing: {source_path}")
                    owner = content_owner.get((source_bytes, source_sha))
                    member_scratch = scratch / f"member-{index}"
                    member_scratch.mkdir()
                    if owner is not None:
                        codec_id = "reference"
                        dependency_index = owner
                        payload_path: Path | None = None
                        payload_bytes = 0
                        payload_sha = hashlib.sha256(b"").hexdigest()
                        candidates = (("reference", 0),)
                        rejected: tuple[str, ...] = ()
                    else:
                        (
                            codec_id,
                            payload_path,
                            candidates,
                            rejected,
                        ) = self._select_candidate(
                            MemberSpec(
                                spec.relative_path,
                                source_path,
                                spec.candidate_codec_ids,
                            ),
                            member_scratch,
                            source_bytes,
                            source_sha,
                        )
                        dependency_index = -1
                        payload_bytes = payload_path.stat().st_size
                        payload_sha = _sha256_file(payload_path)
                        content_owner[(source_bytes, source_sha)] = index
                    if _sha256_file(source_path) != source_sha:
                        raise RuntimeError(f"codec mutated source: {source_path}")
                    codec_bytes = _validate_codec_id(codec_id)
                    variable = path_bytes + codec_bytes
                    header_bytes = _CHUNK_HEADER.size + len(variable)
                    if header_bytes > 0xFFFFFFFF or len(codec_bytes) > 0xFFFF:
                        raise ValueError("WorldPack chunk header is too large")
                    chunk_offset = output.tell()
                    fixed_zero_crc = _CHUNK_HEADER.pack(
                        _CHUNK_MAGIC,
                        header_bytes,
                        len(codec_bytes),
                        0,
                        dependency_index,
                        source_bytes,
                        payload_bytes,
                        bytes.fromhex(source_sha),
                        bytes.fromhex(payload_sha),
                        len(path_bytes),
                        0,
                        0,
                    )
                    header_crc = zlib.crc32(fixed_zero_crc + variable) & 0xFFFFFFFF
                    fixed = _CHUNK_HEADER.pack(
                        _CHUNK_MAGIC,
                        header_bytes,
                        len(codec_bytes),
                        0,
                        dependency_index,
                        source_bytes,
                        payload_bytes,
                        bytes.fromhex(source_sha),
                        bytes.fromhex(payload_sha),
                        len(path_bytes),
                        0,
                        header_crc,
                    )
                    output.write(fixed)
                    output.write(variable)
                    payload_offset = output.tell()
                    if payload_path is not None:
                        with payload_path.open("rb") as payload:
                            shutil.copyfileobj(payload, output, length=1024 * 1024)
                    entries.append(
                        WorldPackEntry(
                            path=spec.relative_path,
                            chunk_index=index,
                            chunk_offset=chunk_offset,
                            payload_offset=payload_offset,
                            codec_id=codec_id,
                            dependency_index=dependency_index,
                            original_bytes=source_bytes,
                            payload_bytes=payload_bytes,
                            original_sha256=source_sha,
                            payload_sha256=payload_sha,
                            candidate_bytes=candidates,
                            rejected_candidates=rejected,
                        )
                    )
                index_offset = output.tell()
                index_value = {
                    "schema": "pw_worldpack_index_v1",
                    "manifest_sha256": self.manifest_sha256,
                    "entries": [asdict(entry) for entry in entries],
                }
                index_encoded = json.dumps(
                    index_value,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
                index_sha = hashlib.sha256(index_encoded).digest()
                output.write(index_encoded)
                footer_zero_crc = _FOOTER.pack(
                    _FOOTER_MAGIC,
                    index_offset,
                    len(index_encoded),
                    index_sha,
                    0,
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
            os.replace(temporary_output, self.output_path)
            _fsync_directory(self.output_path.parent)
        except Exception:
            temporary_output.unlink(missing_ok=True)
            raise
        complete_bytes = self.output_path.stat().st_size
        chunk_header_bytes = sum(
            entry.payload_offset - entry.chunk_offset for entry in entries
        )
        payload_bytes = sum(entry.payload_bytes for entry in entries)
        return WorldPackWriteResult(
            complete_persisted_bytes=complete_bytes,
            manifest_sha256=self.manifest_sha256,
            archive_sha256=_sha256_file(self.output_path),
            header_bytes=_FILE_HEADER.size,
            chunk_header_bytes=chunk_header_bytes,
            payload_bytes=payload_bytes,
            index_bytes=len(index_encoded),
            footer_bytes=_FOOTER.size,
            entries=tuple(entries),
        )


class WorldPackReader:
    def __init__(self, archive_path: Path, *, codecs: Iterable[FileCodec]) -> None:
        self.archive_path = archive_path.resolve()
        codec_values = tuple(codecs)
        self.codecs = {codec.codec_id: codec for codec in codec_values}
        if len(self.codecs) != len(codec_values):
            raise ValueError("duplicate codec identity")
        self.entries: tuple[WorldPackEntry, ...]
        self.manifest_sha256: str
        self._validate_and_load_index()

    def _corrupt(self, message: str) -> WorldPackCorruption:
        return WorldPackCorruption(f"WorldPack corruption: {message}")

    def _validate_and_load_index(self) -> None:
        file_bytes = self.archive_path.stat().st_size
        if file_bytes < _FILE_HEADER.size + _FOOTER.size:
            raise self._corrupt("file is truncated")
        with self.archive_path.open("rb") as source:
            file_header = source.read(_FILE_HEADER.size)
            magic, version, header_bytes, manifest_digest, reserved = (
                _FILE_HEADER.unpack(file_header)
            )
            if (
                magic != _FILE_MAGIC
                or version != _VERSION
                or header_bytes != _FILE_HEADER.size
                or reserved != bytes(16)
            ):
                raise self._corrupt("invalid fixed header")
            source.seek(file_bytes - _FOOTER.size)
            footer = source.read(_FOOTER.size)
            footer_magic, index_offset, index_bytes, index_sha, footer_crc = (
                _FOOTER.unpack(footer)
            )
            footer_zero_crc = _FOOTER.pack(
                footer_magic, index_offset, index_bytes, index_sha, 0
            )
            if (
                footer_magic != _FOOTER_MAGIC
                or zlib.crc32(footer_zero_crc) & 0xFFFFFFFF != footer_crc
            ):
                raise self._corrupt("footer CRC or identity mismatch")
            if (
                index_offset < _FILE_HEADER.size
                or index_offset + index_bytes != file_bytes - _FOOTER.size
            ):
                raise self._corrupt("footer index bounds mismatch")
            source.seek(index_offset)
            index_encoded = source.read(index_bytes)
            if hashlib.sha256(index_encoded).digest() != index_sha:
                raise self._corrupt("footer index SHA-256 mismatch")
            try:
                index = json.loads(index_encoded)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise self._corrupt("footer index is not canonical JSON") from error
            if index.get("schema") != "pw_worldpack_index_v1":
                raise self._corrupt("unknown footer index schema")
            self.manifest_sha256 = str(index.get("manifest_sha256", ""))
            try:
                index_manifest = _validate_hex_sha256(
                    self.manifest_sha256, "index manifest SHA-256"
                )
            except ValueError as error:
                raise self._corrupt(str(error)) from error
            if index_manifest != manifest_digest:
                raise self._corrupt("header and index manifest identity differ")
            entries: list[WorldPackEntry] = []
            seen_paths: set[str] = set()
            cursor = _FILE_HEADER.size
            for ordinal, raw_entry in enumerate(index.get("entries", [])):
                try:
                    raw_entry["candidate_bytes"] = tuple(
                        tuple(candidate) for candidate in raw_entry["candidate_bytes"]
                    )
                    raw_entry["rejected_candidates"] = tuple(
                        raw_entry["rejected_candidates"]
                    )
                    entry = WorldPackEntry(**raw_entry)
                except (KeyError, TypeError, ValueError) as error:
                    raise self._corrupt("invalid index entry") from error
                try:
                    _validate_relative_path(entry.path)
                except ValueError as error:
                    raise self._corrupt(str(error)) from error
                if entry.path in seen_paths or entry.chunk_index != ordinal:
                    raise self._corrupt("duplicate path or non-canonical chunk order")
                seen_paths.add(entry.path)
                if entry.dependency_index >= ordinal or entry.dependency_index < -1:
                    raise self._corrupt("forward or out-of-range dependency")
                if entry.codec_id == "reference":
                    if (
                        entry.dependency_index < 0
                        or entry.payload_bytes != 0
                        or entry.payload_sha256 != hashlib.sha256(b"").hexdigest()
                    ):
                        raise self._corrupt("invalid reference chunk")
                elif entry.dependency_index != -1:
                    raise self._corrupt("non-reference chunk has a dependency")
                if (
                    entry.codec_id not in {"raw", "reference"}
                    and entry.codec_id not in self.codecs
                ):
                    raise self._corrupt(f"unknown codec identity {entry.codec_id}")
                if entry.chunk_offset != cursor:
                    raise self._corrupt("chunk stream is not contiguous")
                source.seek(entry.chunk_offset)
                fixed = source.read(_CHUNK_HEADER.size)
                if len(fixed) != _CHUNK_HEADER.size:
                    raise self._corrupt("chunk header is truncated")
                (
                    chunk_magic,
                    chunk_header_bytes,
                    codec_bytes,
                    flags,
                    dependency,
                    original_bytes,
                    payload_bytes,
                    original_sha,
                    payload_sha,
                    path_bytes,
                    metadata_bytes,
                    header_crc,
                ) = _CHUNK_HEADER.unpack(fixed)
                variable_bytes = chunk_header_bytes - _CHUNK_HEADER.size
                if (
                    chunk_magic != _CHUNK_MAGIC
                    or flags != 0
                    or metadata_bytes != 0
                    or variable_bytes != path_bytes + codec_bytes
                    or chunk_header_bytes < _CHUNK_HEADER.size
                ):
                    raise self._corrupt("invalid chunk header dimensions")
                variable = source.read(variable_bytes)
                zero_crc = _CHUNK_HEADER.pack(
                    chunk_magic,
                    chunk_header_bytes,
                    codec_bytes,
                    flags,
                    dependency,
                    original_bytes,
                    payload_bytes,
                    original_sha,
                    payload_sha,
                    path_bytes,
                    metadata_bytes,
                    0,
                )
                if zlib.crc32(zero_crc + variable) & 0xFFFFFFFF != header_crc:
                    raise self._corrupt("chunk header CRC mismatch")
                try:
                    physical_path = variable[:path_bytes].decode("utf-8")
                    physical_codec = variable[path_bytes:].decode("ascii")
                except UnicodeDecodeError as error:
                    raise self._corrupt("chunk path or codec encoding is invalid") from error
                physical = (
                    physical_path,
                    physical_codec,
                    dependency,
                    original_bytes,
                    payload_bytes,
                    original_sha.hex(),
                    payload_sha.hex(),
                    entry.chunk_offset + chunk_header_bytes,
                )
                indexed = (
                    entry.path,
                    entry.codec_id,
                    entry.dependency_index,
                    entry.original_bytes,
                    entry.payload_bytes,
                    entry.original_sha256,
                    entry.payload_sha256,
                    entry.payload_offset,
                )
                if physical != indexed:
                    raise self._corrupt("physical chunk and footer index differ")
                if entry.codec_id == "reference":
                    dependency_entry = entries[entry.dependency_index]
                    if (
                        entry.original_bytes != dependency_entry.original_bytes
                        or entry.original_sha256 != dependency_entry.original_sha256
                    ):
                        raise self._corrupt("reference identity differs from dependency")
                cursor = entry.payload_offset + entry.payload_bytes
                if cursor > index_offset:
                    raise self._corrupt("chunk payload exceeds index boundary")
                entries.append(entry)
            if not entries or cursor != index_offset:
                raise self._corrupt("empty archive or unindexed chunk bytes")
        self.entries = tuple(entries)
        self._path_to_index = {
            entry.path: entry.chunk_index for entry in self.entries
        }

    @property
    def paths(self) -> tuple[str, ...]:
        return tuple(entry.path for entry in self.entries)

    def reconstructed_write_result(self) -> WorldPackWriteResult:
        """Recover the writer's persisted-size accounting from a valid archive."""
        first = self.entries[0]
        last = self.entries[-1]
        complete_bytes = self.archive_path.stat().st_size
        index_offset = last.payload_offset + last.payload_bytes
        index_bytes = complete_bytes - index_offset - _FOOTER.size
        if index_bytes < 0:
            raise self._corrupt("negative footer index size")
        return WorldPackWriteResult(
            complete_persisted_bytes=complete_bytes,
            manifest_sha256=self.manifest_sha256,
            archive_sha256=_sha256_file(self.archive_path),
            header_bytes=first.chunk_offset,
            chunk_header_bytes=sum(
                entry.payload_offset - entry.chunk_offset for entry in self.entries
            ),
            payload_bytes=sum(entry.payload_bytes for entry in self.entries),
            index_bytes=index_bytes,
            footer_bytes=_FOOTER.size,
            entries=self.entries,
        )

    def _copy_payload(self, entry: WorldPackEntry, destination: Path) -> None:
        digest = hashlib.sha256()
        remaining = entry.payload_bytes
        with self.archive_path.open("rb") as source, destination.open("wb") as output:
            source.seek(entry.payload_offset)
            while remaining:
                block = source.read(min(1024 * 1024, remaining))
                if not block:
                    raise self._corrupt("payload is truncated")
                digest.update(block)
                output.write(block)
                remaining -= len(block)
        if digest.hexdigest() != entry.payload_sha256:
            destination.unlink(missing_ok=True)
            raise self._corrupt("payload SHA-256 mismatch")

    def _extract_index(
        self,
        index: int,
        destination: Path,
        scratch: Path,
        touched: list[int],
    ) -> None:
        entry = self.entries[index]
        touched.append(index)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if entry.codec_id == "reference":
            self._extract_index(entry.dependency_index, destination, scratch, touched)
        elif entry.codec_id == "raw":
            self._copy_payload(entry, destination)
        else:
            encoded = scratch / f"chunk-{index}.encoded"
            encoded.unlink(missing_ok=True)
            destination.unlink(missing_ok=True)
            self._copy_payload(entry, encoded)
            try:
                self.codecs[entry.codec_id].decode_file(encoded, destination)
            except Exception as error:
                destination.unlink(missing_ok=True)
                raise self._corrupt(
                    f"codec {entry.codec_id} rejected its verified payload"
                ) from error
        if (
            not destination.is_file()
            or destination.stat().st_size != entry.original_bytes
            or _sha256_file(destination) != entry.original_sha256
        ):
            destination.unlink(missing_ok=True)
            raise self._corrupt("restored member length or SHA-256 mismatch")

    def extract_member(self, path: str, destination: Path) -> tuple[int, ...]:
        try:
            index = self._path_to_index[path]
        except KeyError as error:
            raise KeyError(f"WorldPack does not contain {path!r}") from error
        with tempfile.TemporaryDirectory(prefix="worldpack-reader-") as scratch_name:
            touched: list[int] = []
            self._extract_index(
                index,
                destination.resolve(),
                Path(scratch_name),
                touched,
            )
        return tuple(touched)

    def read_member_with_trace(self, path: str) -> tuple[bytes, tuple[int, ...]]:
        with tempfile.TemporaryDirectory(prefix="worldpack-read-") as temporary:
            destination = Path(temporary) / "member"
            touched = self.extract_member(path, destination)
            return destination.read_bytes(), touched

    def read_member(self, path: str) -> bytes:
        return self.read_member_with_trace(path)[0]

    def extract_all(self, destination_root: Path) -> None:
        root = destination_root.resolve()
        root.mkdir(parents=True, exist_ok=True)
        for entry in self.entries:
            destination = (root / PurePosixPath(entry.path)).resolve()
            if root not in destination.parents:
                raise self._corrupt("member path escapes extraction root")
            self.extract_member(entry.path, destination)
