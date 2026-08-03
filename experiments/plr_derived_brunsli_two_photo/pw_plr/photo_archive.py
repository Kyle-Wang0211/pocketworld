"""Self-contained, checksummed storage for one photo's exact coefficient tiles."""

from __future__ import annotations

from array import array
from dataclasses import dataclass
import hashlib
import json
import struct

from .coefficient_archive import MlccTile
from .dct_training import DctComponent, TrainingCoefficients
from .tile_stream import decode_tile_document


MAGIC = b"PWPA1\0\0\0"


@dataclass(frozen=True)
class EncodedPhotoTile:
    luma_top: int
    luma_left: int
    valid_luma_height: int
    valid_luma_width: int
    document: bytes


@dataclass(frozen=True)
class DecodedPhotoArchive:
    coefficients: TrainingCoefficients
    tiles: tuple[EncodedPhotoTile, ...]


def _metadata(coefficients: TrainingCoefficients) -> dict[str, object]:
    return {
        "schema": "pw_plr_photo_coefficient_archive_v1",
        "width": coefficients.width,
        "height": coefficients.height,
        "max_h_samp_factor": coefficients.max_h_samp_factor,
        "max_v_samp_factor": coefficients.max_v_samp_factor,
        "source_bytes": coefficients.source_bytes,
        "source_sha256": coefficients.source_sha256,
        "components": [
            {
                "component_id": component.component_id,
                "h_samp_factor": component.h_samp_factor,
                "v_samp_factor": component.v_samp_factor,
                "quant_idx": component.quant_idx,
                "width_in_blocks": component.width_in_blocks,
                "height_in_blocks": component.height_in_blocks,
            }
            for component in coefficients.components
        ],
    }


def encode_photo_archive(
    coefficients: TrainingCoefficients,
    tiles: list[MlccTile],
    tile_documents: list[bytes],
) -> bytes:
    if not tiles or len(tiles) != len(tile_documents):
        raise ValueError("photo archive tile/document count mismatch")
    metadata = json.dumps(
        _metadata(coefficients), sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    payload = bytearray(struct.pack("<I", len(metadata)))
    payload.extend(metadata)
    payload.extend(struct.pack("<I", len(tiles)))
    for tile, document in zip(tiles, tile_documents, strict=True):
        decode_tile_document(document)
        payload.extend(
            struct.pack(
                "<4IQ",
                tile.luma_top,
                tile.luma_left,
                tile.valid_luma_height,
                tile.valid_luma_width,
                len(document),
            )
        )
        payload.extend(document)
    payload_bytes = bytes(payload)
    return MAGIC + hashlib.sha256(payload_bytes).digest() + payload_bytes


def _take(payload: bytes, position: int, count: int) -> tuple[bytes, int]:
    if count < 0 or position > len(payload) or count > len(payload) - position:
        raise ValueError("truncated photo coefficient archive")
    return payload[position : position + count], position + count


def _template_from_metadata(metadata: dict[str, object]) -> TrainingCoefficients:
    if metadata.get("schema") != "pw_plr_photo_coefficient_archive_v1":
        raise ValueError("unsupported photo coefficient archive schema")
    source_sha256 = str(metadata["source_sha256"])
    try:
        digest = bytes.fromhex(source_sha256)
    except ValueError as error:
        raise ValueError("invalid archived source SHA-256") from error
    if len(digest) != 32:
        raise ValueError("invalid archived source SHA-256")
    components = tuple(
        DctComponent(
            component_id=int(component["component_id"]),
            h_samp_factor=int(component["h_samp_factor"]),
            v_samp_factor=int(component["v_samp_factor"]),
            quant_idx=int(component["quant_idx"]),
            width_in_blocks=int(component["width_in_blocks"]),
            height_in_blocks=int(component["height_in_blocks"]),
            coefficients=array("h"),
        )
        for component in metadata["components"]
    )
    return TrainingCoefficients(
        width=int(metadata["width"]),
        height=int(metadata["height"]),
        max_h_samp_factor=int(metadata["max_h_samp_factor"]),
        max_v_samp_factor=int(metadata["max_v_samp_factor"]),
        source_bytes=int(metadata["source_bytes"]),
        source_sha256=source_sha256,
        components=components,
    )


def decode_photo_archive(document: bytes) -> DecodedPhotoArchive:
    header_bytes = len(MAGIC) + 32
    if len(document) < header_bytes or not document.startswith(MAGIC):
        raise ValueError("invalid photo coefficient archive envelope")
    expected_sha256 = document[len(MAGIC) : header_bytes]
    payload = document[header_bytes:]
    if hashlib.sha256(payload).digest() != expected_sha256:
        raise ValueError("photo coefficient archive SHA-256 mismatch")
    position = 0
    metadata_length_bytes, position = _take(payload, position, 4)
    metadata_length = struct.unpack("<I", metadata_length_bytes)[0]
    metadata_bytes, position = _take(payload, position, metadata_length)
    try:
        metadata = json.loads(metadata_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError("invalid photo coefficient archive metadata") from error
    tile_count_bytes, position = _take(payload, position, 4)
    tile_count = struct.unpack("<I", tile_count_bytes)[0]
    if tile_count == 0:
        raise ValueError("photo coefficient archive has no tiles")
    tiles: list[EncodedPhotoTile] = []
    tile_header = struct.Struct("<4IQ")
    for _ in range(tile_count):
        header, position = _take(payload, position, tile_header.size)
        top, left, height, width, tile_bytes = tile_header.unpack(header)
        tile_document, position = _take(payload, position, tile_bytes)
        decode_tile_document(tile_document)
        tiles.append(
            EncodedPhotoTile(
                luma_top=top,
                luma_left=left,
                valid_luma_height=height,
                valid_luma_width=width,
                document=tile_document,
            )
        )
    if position != len(payload):
        raise ValueError("unexpected trailing photo coefficient archive bytes")
    return DecodedPhotoArchive(
        coefficients=_template_from_metadata(metadata),
        tiles=tuple(tiles),
    )
