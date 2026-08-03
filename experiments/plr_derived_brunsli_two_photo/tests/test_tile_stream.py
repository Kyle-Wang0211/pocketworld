import os
from pathlib import Path
import sys

import pytest
import torch

from pw_plr.tile_stream import decode_tile_document, encode_tile_document


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def test_tile_document_preserves_all_22_streams_and_exact_coefficients() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    model.update(force=True)
    y = torch.randint(-8, 9, (1, 32, 32, 64)).float()
    cb = torch.randint(-8, 9, (1, 1, 128, 128)).float()
    cr = torch.randint(-8, 9, (1, 1, 128, 128)).float()

    with torch.no_grad():
        encoded = model.compress(y, cb, cr)
        document = encode_tile_document(encoded)
        rebuilt = decode_tile_document(document)
        decoded_y, decoded_cb, decoded_cr = model.decompress(rebuilt)

    assert torch.equal(decoded_y, y.int())
    assert torch.equal(decoded_cb, cb.int())
    assert torch.equal(decoded_cr, cr.int())
    assert document.startswith(b"PWTL1\0\0\0")


def test_tile_document_rejects_corruption_before_entropy_decode() -> None:
    streams = [bytes([index]) for index in range(22)]
    document = encode_tile_document(streams)
    corrupted = bytearray(document)
    corrupted[-1] ^= 1

    with pytest.raises(ValueError, match="SHA-256"):
        decode_tile_document(bytes(corrupted))
