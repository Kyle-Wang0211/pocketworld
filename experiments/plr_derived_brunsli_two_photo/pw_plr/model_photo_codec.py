"""Exact full-photo model encoding with per-tile integer CDF evidence."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from typing import Any

import torch

from .cdf_trace import collect_model_decision_trace
from .coefficient_archive import MlccTile, extract_all_mlcc_tiles
from .dct_training import TrainingCoefficients
from .photo_archive import decode_photo_archive, encode_photo_archive
from .tile_stream import decode_tile_document, encode_tile_document


@dataclass(frozen=True)
class EncodedPhotoResult:
    archive: bytes
    source_tiles: tuple[MlccTile, ...]
    trace: dict[str, Any]


@dataclass(frozen=True)
class DecodedPhotoResult:
    coefficients: TrainingCoefficients
    tiles: tuple[MlccTile, ...]
    trace: dict[str, Any]


def _aggregate_trace(tile_traces: list[dict[str, Any]]) -> dict[str, Any]:
    hashes = [str(trace["trace_sha256"]) for trace in tile_traces]
    serialized = json.dumps(hashes, separators=(",", ":")).encode("utf-8")
    return {
        "schema": "pw_plr_photo_integer_cdf_trace_v1",
        "tile_count": len(hashes),
        "stage_count_per_tile": 22,
        "tile_trace_sha256": hashes,
        "trace_sha256": hashlib.sha256(serialized).hexdigest(),
    }


def encode_photo_with_model(
    model: torch.nn.Module,
    coefficients: TrainingCoefficients,
) -> EncodedPhotoResult:
    model.eval()
    tiles = extract_all_mlcc_tiles(coefficients)
    documents: list[bytes] = []
    traces: list[dict[str, Any]] = []
    for tile in tiles:
        encoded = model.compress(
            tile.Y.unsqueeze(0),
            tile.Cb.unsqueeze(0),
            tile.Cr.unsqueeze(0),
        )
        traces.append(collect_model_decision_trace(model))
        documents.append(encode_tile_document(encoded))
    return EncodedPhotoResult(
        archive=encode_photo_archive(coefficients, tiles, documents),
        source_tiles=tuple(tiles),
        trace=_aggregate_trace(traces),
    )


def decode_photo_with_model(
    model: torch.nn.Module,
    archive: bytes,
) -> DecodedPhotoResult:
    model.eval()
    decoded_archive = decode_photo_archive(archive)
    tiles: list[MlccTile] = []
    traces: list[dict[str, Any]] = []
    for tile in decoded_archive.tiles:
        y, cb, cr = model.decompress(decode_tile_document(tile.document))
        traces.append(collect_model_decision_trace(model))
        tiles.append(
            MlccTile(
                luma_top=tile.luma_top,
                luma_left=tile.luma_left,
                valid_luma_height=tile.valid_luma_height,
                valid_luma_width=tile.valid_luma_width,
                Y=y.squeeze(0),
                Cb=cb.squeeze(0),
                Cr=cr.squeeze(0),
            )
        )
    return DecodedPhotoResult(
        coefficients=decoded_archive.coefficients,
        tiles=tuple(tiles),
        trace=_aggregate_trace(traces),
    )
