import os
from pathlib import Path
import sys

import torch

from pw_plr.trainer import (
    build_optimizers,
    equal_tile_batches,
    train_batch,
    validation_patch_bits,
)


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


def test_train_batch_updates_the_exact_rate_model_with_finite_metrics() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).train()
    main_optimizer, auxiliary_optimizer = build_optimizers(
        model,
        main_learning_rate=1e-4,
        auxiliary_learning_rate=1e-3,
    )
    y = torch.randint(-4, 5, (2, 32, 32, 64)).float()
    cb = torch.randint(-4, 5, (2, 1, 128, 128)).float()
    cr = torch.randint(-4, 5, (2, 1, 128, 128)).float()
    before = next(model.parameters()).detach().clone()

    metrics = train_batch(
        model,
        {"Y": y, "Cb": cb, "Cr": cr},
        main_optimizer,
        auxiliary_optimizer,
        gradient_clip_max_norm=1.0,
    )

    assert metrics.loss_bits_per_pixel > 0
    assert metrics.auxiliary_loss >= 0
    assert metrics.gradient_norm >= 0
    assert not torch.equal(before, next(model.parameters()).detach())


def test_validation_patch_bits_reports_the_models_total_likelihood_cost() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    batch = {
        "Y": torch.zeros(2, 32, 32, 64),
        "Cb": torch.zeros(2, 1, 128, 128),
        "Cr": torch.zeros(2, 1, 128, 128),
    }

    bits = validation_patch_bits(model, batch)

    assert bits > 0


def test_equal_tile_batches_never_mix_full_photo_geometry() -> None:
    images = [
        {"full_photo_tile_count": 10},
        {"full_photo_tile_count": 20},
        {"full_photo_tile_count": 10},
        {"full_photo_tile_count": 10},
    ]

    batches = equal_tile_batches(images, batch_size=2)

    assert batches == [[0, 2], [3], [1]]
    assert all(
        len({images[index]["full_photo_tile_count"] for index in batch}) == 1
        for batch in batches
    )
