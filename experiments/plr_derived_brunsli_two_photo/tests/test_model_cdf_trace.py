import os
from pathlib import Path
import sys

import torch

from pw_plr.cdf_trace import collect_model_decision_trace


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def test_all_22_entropy_stage_decisions_match_between_encode_and_decode() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    model.update(force=True)
    y = torch.randint(-8, 9, (1, 32, 32, 64)).float()
    cb = torch.randint(-8, 9, (1, 1, 128, 128)).float()
    cr = torch.randint(-8, 9, (1, 1, 128, 128)).float()

    with torch.no_grad():
        encoded = model.compress(y, cb, cr)
        encoder_trace = collect_model_decision_trace(model)
        model.decompress(encoded)
        decoder_trace = collect_model_decision_trace(model)

    assert encoder_trace["stage_count"] == 22
    assert decoder_trace["stage_count"] == 22
    assert encoder_trace["trace_sha256"] == decoder_trace["trace_sha256"]
    assert encoder_trace["stages"] == decoder_trace["stages"]
