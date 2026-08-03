from array import array
import hashlib
import os
from pathlib import Path
import sys

import torch

from pw_plr.dct_training import DctComponent, TrainingCoefficients
from pw_plr.model_photo_codec import decode_photo_with_model, encode_photo_with_model


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def _coefficients() -> TrainingCoefficients:
    generator = torch.Generator().manual_seed(20260803)

    def component(
        component_id: int,
        h_samp: int,
        v_samp: int,
        width: int,
        height: int,
    ) -> DctComponent:
        values = torch.randint(
            -12,
            13,
            (height * width * 64,),
            generator=generator,
            dtype=torch.int16,
        )
        return DctComponent(
            component_id=component_id,
            h_samp_factor=h_samp,
            v_samp_factor=v_samp,
            quant_idx=component_id - 1,
            width_in_blocks=width,
            height_in_blocks=height,
            coefficients=array("h", values.tolist()),
        )

    source_sha = hashlib.sha256(b"synthetic exact JPEG identity").hexdigest()
    return TrainingCoefficients(
        width=256,
        height=256,
        max_h_samp_factor=2,
        max_v_samp_factor=2,
        source_bytes=123456,
        source_sha256=source_sha,
        components=(
            component(1, 2, 2, 32, 32),
            component(2, 1, 1, 16, 16),
            component(3, 1, 1, 16, 16),
        ),
    )


def test_photo_model_codec_is_exact_and_all_tile_cdf_traces_match() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    model.update(force=True)
    coefficients = _coefficients()

    with torch.no_grad():
        encoded = encode_photo_with_model(model, coefficients)
        decoded = decode_photo_with_model(model, encoded.archive)

    assert len(decoded.tiles) == 1
    assert encoded.trace["tile_count"] == 1
    assert encoded.trace == decoded.trace
    assert torch.equal(decoded.tiles[0].Y, encoded.source_tiles[0].Y.int())
    assert torch.equal(decoded.tiles[0].Cb, encoded.source_tiles[0].Cb.int())
    assert torch.equal(decoded.tiles[0].Cr, encoded.source_tiles[0].Cr.int())
