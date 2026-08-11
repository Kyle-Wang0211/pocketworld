import os
from pathlib import Path
import sys

import pytest
import torch

from pw_plr.trainer import (
    build_optimizers,
    equal_tile_batches,
    train_accumulated_batch,
    train_batch,
    validation_patch_bits,
    validation_patch_bits_microbatched,
)


UPSTREAM = Path(
    os.environ.get(
        "PW_PLR_SOURCE_ROOT",
        Path(__file__).resolve().parent.parent / "build" / "plr-upstream",
    )
)
sys.path.insert(0, str(UPSTREAM))

from compressai.models.base_eff import EfficientJPEGRecompression


class DeterministicRateModel(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.weight = torch.nn.Parameter(torch.tensor(0.1))
        self.entropy = torch.nn.Module()
        self.entropy.register_parameter(
            "quantiles", torch.nn.Parameter(torch.tensor([0.25]))
        )

    def forward(
        self, y: torch.Tensor, cb: torch.Tensor, cr: torch.Tensor
    ) -> dict[str, torch.Tensor]:
        score = (
            y.flatten(1).mean(1)
            + cb.flatten(1).mean(1)
            + cr.flatten(1).mean(1)
        )
        return {"bpp_loss": -(score * self.weight + 5.0)}

    def aux_loss(self) -> torch.Tensor:
        return self.entropy.quantiles.square()


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


def test_gradient_accumulation_preserves_one_effective_batch_update() -> None:
    torch.manual_seed(20260803)
    full_model = DeterministicRateModel().train()
    accumulated_model = DeterministicRateModel().train()
    accumulated_model.load_state_dict(full_model.state_dict())
    full_optimizers = build_optimizers(
        full_model,
        main_learning_rate=1e-4,
        auxiliary_learning_rate=1e-3,
    )
    accumulated_optimizers = build_optimizers(
        accumulated_model,
        main_learning_rate=1e-4,
        auxiliary_learning_rate=1e-3,
    )
    batch = {
        "Y": torch.randint(-4, 5, (4, 32, 32, 64)).float(),
        "Cb": torch.randint(-4, 5, (4, 1, 128, 128)).float(),
        "Cr": torch.randint(-4, 5, (4, 1, 128, 128)).float(),
    }

    full = train_batch(
        full_model,
        batch,
        *full_optimizers,
        gradient_clip_max_norm=1.0,
    )
    accumulated = train_accumulated_batch(
        accumulated_model,
        batch,
        *accumulated_optimizers,
        microbatch_size=2,
        gradient_clip_max_norm=1.0,
    )

    assert accumulated.loss_bits_per_pixel == pytest.approx(
        full.loss_bits_per_pixel, rel=1e-6
    )
    assert accumulated.auxiliary_loss == pytest.approx(
        full.auxiliary_loss, rel=1e-6
    )
    for full_parameter, accumulated_parameter in zip(
        full_model.parameters(), accumulated_model.parameters(), strict=True
    ):
        assert torch.allclose(full_parameter, accumulated_parameter, atol=2e-6)


def test_microbatched_validation_preserves_total_patch_bits() -> None:
    torch.manual_seed(20260803)
    model = EfficientJPEGRecompression(N=8, M=12).eval()
    batch = {
        "Y": torch.randint(-4, 5, (4, 32, 32, 64)).float(),
        "Cb": torch.randint(-4, 5, (4, 1, 128, 128)).float(),
        "Cr": torch.randint(-4, 5, (4, 1, 128, 128)).float(),
    }

    assert validation_patch_bits_microbatched(
        model, batch, microbatch_size=2
    ) == pytest.approx(validation_patch_bits(model, batch), rel=1e-6)


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
