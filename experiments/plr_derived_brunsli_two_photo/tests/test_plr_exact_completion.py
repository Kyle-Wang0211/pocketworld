import os
from pathlib import Path
import sys

import torch


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def test_official_22_stage_sibling_round_trips_integer_coefficients() -> None:
    torch.set_num_threads(1)
    generator = torch.Generator().manual_seed(20260803)
    y = torch.randint(-8, 9, (1, 32, 32, 64), generator=generator).float()
    cb = torch.randint(-8, 9, (1, 1, 128, 128), generator=generator).float()
    cr = torch.randint(-8, 9, (1, 1, 128, 128), generator=generator).float()
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    model.update(force=True)

    with torch.no_grad():
        encoded = model.compress(y, cb, cr)
        decoded_y, decoded_cb, decoded_cr = model.decompress(encoded)

    assert torch.equal(decoded_y, y.int())
    assert torch.equal(decoded_cb, cb.int())
    assert torch.equal(decoded_cr, cr.int())
