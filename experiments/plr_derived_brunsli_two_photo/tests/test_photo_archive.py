from pathlib import Path

import pytest

from pw_plr.coefficient_archive import extract_all_mlcc_tiles
from pw_plr.dct_training import read_training_coefficients
from pw_plr.photo_archive import decode_photo_archive, encode_photo_archive
from pw_plr.tile_stream import encode_tile_document


def test_photo_archive_preserves_geometry_identity_and_every_tile() -> None:
    root = Path(__file__).resolve().parents[1]
    coefficients = read_training_coefficients(
        root / "results/work/training-coefficients/A.pwtj"
    )
    tiles = extract_all_mlcc_tiles(coefficients)
    documents = [
        encode_tile_document(
            [f"tile-{index}-stream-{stream}".encode() for stream in range(22)]
        )
        for index in range(len(tiles))
    ]

    archive = encode_photo_archive(coefficients, tiles, documents)
    decoded = decode_photo_archive(archive)

    assert decoded.coefficients.source_sha256 == coefficients.source_sha256
    assert decoded.coefficients.source_bytes == coefficients.source_bytes
    assert len(decoded.tiles) == 170
    assert decoded.tiles[-1].valid_luma_height == 10
    assert decoded.tiles[-1].valid_luma_width == 16
    assert [tile.document for tile in decoded.tiles] == documents


def test_photo_archive_rejects_corruption_before_tile_decode() -> None:
    root = Path(__file__).resolve().parents[1]
    coefficients = read_training_coefficients(
        root / "results/work/training-coefficients/A.pwtj"
    )
    tile = extract_all_mlcc_tiles(coefficients)[0]
    archive = bytearray(
        encode_photo_archive(
            coefficients,
            [tile],
            [encode_tile_document([b"x"] * 22)],
        )
    )
    archive[-1] ^= 1

    with pytest.raises(ValueError, match="SHA-256"):
        decode_photo_archive(bytes(archive))
