import os
from pathlib import Path
import sys

import pytest
import torch

from pw_plr.model_artifact import decode_model_artifact, encode_model_artifact
from pw_plr.tile_stream import encode_tile_document


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def test_model_artifact_round_trips_every_tensor_bit_exactly() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    model.update(force=True)
    identity = {
        "arm": "test",
        "N": 8,
        "M": 12,
        "upstream_commit": "8a65e4d0d3daa9292e40df0541e8f43fcaada2d7",
    }

    document = encode_model_artifact(model.state_dict(), identity)
    decoded = decode_model_artifact(document)

    assert decoded.identity == identity
    assert decoded.state_dict.keys() == model.state_dict().keys()
    for name, expected in model.state_dict().items():
        assert decoded.state_dict[name].dtype == expected.dtype
        assert torch.equal(decoded.state_dict[name], expected.cpu())
    restored = EfficientJPEGRecompression(N=8, M=12).eval()
    restored.load_state_dict(decoded.state_dict)
    y = torch.randint(-4, 5, (1, 32, 32, 64)).float()
    cb = torch.randint(-4, 5, (1, 1, 128, 128)).float()
    cr = torch.randint(-4, 5, (1, 1, 128, 128)).float()
    with torch.no_grad():
        assert encode_tile_document(restored.compress(y, cb, cr)) == (
            encode_tile_document(model.compress(y, cb, cr))
        )


def test_model_artifact_rejects_corruption() -> None:
    document = bytearray(
        encode_model_artifact(
            {"weight": torch.arange(8, dtype=torch.float32)},
            {"arm": "test"},
        )
    )
    document[-1] ^= 1

    with pytest.raises(ValueError, match="SHA-256"):
        decode_model_artifact(bytes(document))
