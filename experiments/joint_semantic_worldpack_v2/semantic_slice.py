from __future__ import annotations

import hashlib
import io
import json
import shutil
import sqlite3
import struct
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


COLMAP_MAX_IMAGE_ID = 2_147_483_647


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _float64_bits(values: Iterable[float]) -> tuple[int, ...]:
    return tuple(struct.unpack("<Q", struct.pack("<d", float(value)))[0] for value in values)


def _colmap_pair_id(first_image_id: int, second_image_id: int) -> int:
    low, high = sorted((first_image_id, second_image_id))
    return low * COLMAP_MAX_IMAGE_ID + high


def _write_field(output: io.BytesIO, name: str, payload: bytes) -> None:
    encoded_name = name.encode("utf-8")
    output.write(struct.pack("<I", len(encoded_name)))
    output.write(encoded_name)
    output.write(struct.pack("<Q", len(payload)))
    output.write(payload)


def _pack_u64s(values: Iterable[int]) -> bytes:
    values = tuple(values)
    return struct.pack(f"<{len(values)}Q", *values) if values else b""


@dataclass(frozen=True)
class ExactPhoto:
    capture_ordinal: int
    frame_id: int
    database_image_id: int
    name: str
    jpeg_bytes: int
    jpeg_sha256: str
    incumbent_path: Path
    incumbent_bytes: int
    incumbent_sha256: str
    metadata_path: Path
    metadata_sha256: str


@dataclass(frozen=True)
class SemanticSlice:
    root: ExactPhoto
    child: ExactPhoto
    arkit_intrinsics_bits: tuple[tuple[int, ...], tuple[int, ...]]
    arkit_extrinsics_bits: tuple[tuple[int, ...], tuple[int, ...]]
    sfm_pose_bits: tuple[tuple[int, ...], tuple[int, ...]]
    descriptor_shape: tuple[tuple[int, int], tuple[int, int]]
    descriptor_blobs: tuple[bytes, bytes]
    keypoint_shape: tuple[tuple[int, int], tuple[int, int]]
    keypoint_blobs: tuple[bytes, bytes]
    raw_match_count: int
    match_records_blob: bytes
    verified_match_count: int
    verified_match_blob: bytes
    two_view_config: int
    two_view_model_blobs: tuple[bytes, bytes, bytes, bytes, bytes]
    shared_anchor_ids: tuple[int, ...]
    shared_anchor_world_bits: tuple[tuple[int, ...], tuple[int, ...]]
    metadata_json_bytes: tuple[bytes, bytes]
    capture_root: Path
    identity_sha256: str

    def _canonical_bytes(self) -> bytes:
        output = io.BytesIO()
        output.write(b"PWSEMANTICSLICE\x01")
        for label, photo in (("root", self.root), ("child", self.child)):
            _write_field(
                output,
                f"{label}.identity",
                json.dumps(
                    {
                        "capture_ordinal": photo.capture_ordinal,
                        "frame_id": photo.frame_id,
                        "database_image_id": photo.database_image_id,
                        "name": photo.name,
                        "jpeg_bytes": photo.jpeg_bytes,
                        "jpeg_sha256": photo.jpeg_sha256,
                        "incumbent_bytes": photo.incumbent_bytes,
                        "incumbent_sha256": photo.incumbent_sha256,
                        "metadata_sha256": photo.metadata_sha256,
                    },
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8"),
            )
        for index in range(2):
            _write_field(output, f"metadata.{index}", self.metadata_json_bytes[index])
            _write_field(output, f"arkit.intrinsics.{index}", _pack_u64s(self.arkit_intrinsics_bits[index]))
            _write_field(output, f"arkit.extrinsics.{index}", _pack_u64s(self.arkit_extrinsics_bits[index]))
            _write_field(output, f"sfm.pose.{index}", _pack_u64s(self.sfm_pose_bits[index]))
            _write_field(output, f"descriptors.{index}", self.descriptor_blobs[index])
            _write_field(output, f"keypoints.{index}", self.keypoint_blobs[index])
        _write_field(output, "descriptor_shape", json.dumps(self.descriptor_shape).encode("ascii"))
        _write_field(output, "keypoint_shape", json.dumps(self.keypoint_shape).encode("ascii"))
        _write_field(output, "matches.raw", self.match_records_blob)
        _write_field(output, "matches.verified", self.verified_match_blob)
        _write_field(output, "matches.counts", struct.pack("<QQI", self.raw_match_count, self.verified_match_count, self.two_view_config))
        for label, blob in zip(("F", "E", "H", "qvec", "tvec"), self.two_view_model_blobs, strict=True):
            _write_field(output, f"two_view.{label}", blob)
        _write_field(output, "anchors.ids", _pack_u64s(self.shared_anchor_ids))
        for index, bits in enumerate(self.shared_anchor_world_bits):
            _write_field(output, f"anchors.world.{index}", _pack_u64s(bits))
        return output.getvalue()

    def logical_roundtrip_sha256(self) -> str:
        return hashlib.sha256(self._canonical_bytes()).hexdigest()

    def restore_original_jpegs(self, scratch: Path) -> tuple[Path, Path]:
        decoder = shutil.which("djxl")
        if decoder is None:
            raise RuntimeError("the pinned host diagnostic requires djxl on PATH")
        scratch.mkdir(parents=True, exist_ok=True)
        restored: list[Path] = []
        for photo in (self.root, self.child):
            destination = scratch / photo.name
            subprocess.run(
                [decoder, str(photo.incumbent_path), str(destination), "--quiet"],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            if destination.stat().st_size != photo.jpeg_bytes:
                raise ValueError(f"restored JPEG length mismatch: {photo.name}")
            if _sha256_file(destination) != photo.jpeg_sha256:
                raise ValueError(f"restored JPEG SHA-256 mismatch: {photo.name}")
            restored.append(destination)
        return restored[0], restored[1]


def _load_photo(
    capture_root: Path,
    archive: dict[str, Any],
    bundle_entry: dict[str, Any],
    capture_ordinal: int,
) -> tuple[ExactPhoto, bytes, dict[str, Any]]:
    name = str(bundle_entry["highresFilename"])
    archived = archive["entries"][name]
    metadata_path = capture_root / "photos_highres" / name.replace(".jpg", ".json")
    metadata_bytes = metadata_path.read_bytes()
    metadata = json.loads(metadata_bytes)
    incumbent_path = capture_root / archived["archive_relative_path"]
    photo = ExactPhoto(
        capture_ordinal=capture_ordinal,
        frame_id=capture_ordinal,
        database_image_id=capture_ordinal + 1,
        name=name,
        jpeg_bytes=int(archived["source_bytes"]),
        jpeg_sha256=str(archived["source_sha256"]),
        incumbent_path=incumbent_path,
        incumbent_bytes=int(archived["archive_bytes"]),
        incumbent_sha256=str(archived["archive_sha256"]),
        metadata_path=metadata_path,
        metadata_sha256=hashlib.sha256(metadata_bytes).hexdigest(),
    )
    if photo.incumbent_path.stat().st_size != photo.incumbent_bytes:
        raise ValueError(f"incumbent length mismatch: {photo.name}")
    if _sha256_file(photo.incumbent_path) != photo.incumbent_sha256:
        raise ValueError(f"incumbent SHA-256 mismatch: {photo.name}")
    return photo, metadata_bytes, metadata


def extract_minimum_slice(capture_root: Path) -> SemanticSlice:
    capture_root = Path(capture_root)
    bundle = json.loads((capture_root / "official_photo_bundle.json").read_bytes())
    archive = json.loads((capture_root / "official_photo_archive.json").read_bytes())
    sparse_meta = json.loads((capture_root / "official_sfm_sparse_meta.json").read_bytes())
    registered = {
        int(pose["frame_id"]): pose
        for pose in sparse_meta["poses"]
        if pose.get("registered") is True
    }

    database = capture_root / "official_sfm_live.db"
    connection = sqlite3.connect(f"file:{database}?mode=ro&immutable=1", uri=True)
    try:
        selected: tuple[int, int, int] | None = None
        frames = bundle["frames"]
        for root_ordinal in range(len(frames) - 1):
            child_ordinal = root_ordinal + 1
            if root_ordinal not in registered or child_ordinal not in registered:
                continue
            pair_id = _colmap_pair_id(root_ordinal + 1, child_ordinal + 1)
            row = connection.execute(
                "SELECT rows FROM two_view_geometries WHERE pair_id = ?",
                (pair_id,),
            ).fetchone()
            if row is not None and int(row[0]) > 0:
                selected = root_ordinal, child_ordinal, pair_id
                break
        if selected is None:
            raise ValueError("no adjacent registered pair with verified geometry")

        root_ordinal, child_ordinal, pair_id = selected
        root, root_metadata_bytes, root_metadata = _load_photo(
            capture_root, archive, frames[root_ordinal], root_ordinal
        )
        child, child_metadata_bytes, child_metadata = _load_photo(
            capture_root, archive, frames[child_ordinal], child_ordinal
        )

        descriptors = []
        descriptor_shape = []
        keypoints = []
        keypoint_shape = []
        for image_id in (root.database_image_id, child.database_image_id):
            descriptor_row = connection.execute(
                "SELECT rows, cols, data FROM descriptors WHERE image_id = ?",
                (image_id,),
            ).fetchone()
            keypoint_row = connection.execute(
                "SELECT rows, cols, data FROM keypoints WHERE image_id = ?",
                (image_id,),
            ).fetchone()
            if descriptor_row is None or keypoint_row is None:
                raise ValueError(f"missing feature data for image {image_id}")
            descriptor_shape.append((int(descriptor_row[0]), int(descriptor_row[1])))
            descriptors.append(bytes(descriptor_row[2]))
            keypoint_shape.append((int(keypoint_row[0]), int(keypoint_row[1])))
            keypoints.append(bytes(keypoint_row[2]))

        raw_match = connection.execute(
            "SELECT rows, data FROM matches WHERE pair_id = ?", (pair_id,)
        ).fetchone()
        verified = connection.execute(
            "SELECT rows, data, config, F, E, H, qvec, tvec "
            "FROM two_view_geometries WHERE pair_id = ?",
            (pair_id,),
        ).fetchone()
        if raw_match is None or verified is None:
            raise ValueError("selected pair lost its registered relationship")

        root_anchor_map = dict(zip(root_metadata["anchor_ids"], root_metadata["anchors_world"], strict=True))
        child_anchor_map = dict(zip(child_metadata["anchor_ids"], child_metadata["anchors_world"], strict=True))
        shared_anchor_ids = tuple(sorted(set(root_anchor_map) & set(child_anchor_map)))
        if not shared_anchor_ids:
            raise ValueError("selected pair has no shared ARKit sparse anchors")

        def anchor_bits(anchor_map: dict[int, list[float]]) -> tuple[int, ...]:
            flattened = (
                coordinate
                for anchor_id in shared_anchor_ids
                for coordinate in anchor_map[anchor_id]
            )
            return _float64_bits(flattened)

        sfm_pose_bits = tuple(
            _float64_bits((*registered[ordinal]["quat_wxyz"], *registered[ordinal]["t"]))
            for ordinal in (root_ordinal, child_ordinal)
        )
        arkit_intrinsics_bits = tuple(
            _float64_bits(metadata["intrinsics_fxfycxcy"])
            for metadata in (root_metadata, child_metadata)
        )
        arkit_extrinsics_bits = tuple(
            _float64_bits(metadata["extrinsic"])
            for metadata in (root_metadata, child_metadata)
        )

        provisional = SemanticSlice(
            root=root,
            child=child,
            arkit_intrinsics_bits=arkit_intrinsics_bits,
            arkit_extrinsics_bits=arkit_extrinsics_bits,
            sfm_pose_bits=sfm_pose_bits,
            descriptor_shape=(descriptor_shape[0], descriptor_shape[1]),
            descriptor_blobs=(descriptors[0], descriptors[1]),
            keypoint_shape=(keypoint_shape[0], keypoint_shape[1]),
            keypoint_blobs=(keypoints[0], keypoints[1]),
            raw_match_count=int(raw_match[0]),
            match_records_blob=bytes(raw_match[1]),
            verified_match_count=int(verified[0]),
            verified_match_blob=bytes(verified[1]),
            two_view_config=int(verified[2]),
            two_view_model_blobs=tuple(bytes(value or b"") for value in verified[3:8]),
            shared_anchor_ids=shared_anchor_ids,
            shared_anchor_world_bits=(anchor_bits(root_anchor_map), anchor_bits(child_anchor_map)),
            metadata_json_bytes=(root_metadata_bytes, child_metadata_bytes),
            capture_root=capture_root,
            identity_sha256="",
        )
        return SemanticSlice(
            **{
                **provisional.__dict__,
                "identity_sha256": hashlib.sha256(provisional._canonical_bytes()).hexdigest(),
            }
        )
    finally:
        connection.close()

