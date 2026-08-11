"""Registered validation and raw-model accounting for Phase 2."""

from __future__ import annotations

from dataclasses import dataclass
import math
from typing import Iterable, Mapping

import torch

from .model_accounting import ceil_div


@dataclass(frozen=True)
class RawModelBytes:
    parameter_bytes: int
    buffer_bytes: int
    complete_tensor_bytes: int


@dataclass(frozen=True)
class ValidationAccounting:
    estimated_entropy_bytes: int
    accounted_model_bytes: int
    total_accounted_bytes: int
    photo_count: int


def raw_state_dict_bytes(model: torch.nn.Module) -> RawModelBytes:
    """Count every tensor required to restore the model state."""
    parameter_names = set(dict(model.named_parameters()))
    parameter_bytes = 0
    buffer_bytes = 0
    for name, tensor in model.state_dict().items():
        byte_count = tensor.numel() * tensor.element_size()
        if name in parameter_names:
            parameter_bytes += byte_count
        else:
            buffer_bytes += byte_count
    return RawModelBytes(
        parameter_bytes=parameter_bytes,
        buffer_bytes=buffer_bytes,
        complete_tensor_bytes=parameter_bytes + buffer_bytes,
    )


def accounted_validation_bytes(
    *,
    groups: Iterable[Mapping[str, int | float]],
    raw_model_bytes: int,
    scope_photo_count: int,
) -> ValidationAccounting:
    """Apply the preregistered equal-tile validation estimator."""
    if raw_model_bytes <= 0 or scope_photo_count <= 0:
        raise ValueError("model bytes and scope photo count must be positive")
    entropy_bytes = 0
    photo_count = 0
    for group in groups:
        group_photos = int(group["photo_count"])
        tile_count = int(group["tile_count"])
        patch_bits = float(group["total_patch_bits"])
        if group_photos <= 0 or tile_count <= 0 or patch_bits < 0:
            raise ValueError("invalid validation accounting group")
        photo_count += group_photos
        entropy_bytes += math.ceil(patch_bits * tile_count / 8.0)
    if photo_count <= 0:
        raise ValueError("validation accounting requires at least one photo")
    model_bytes = ceil_div(raw_model_bytes * photo_count, scope_photo_count)
    return ValidationAccounting(
        estimated_entropy_bytes=entropy_bytes,
        accounted_model_bytes=model_bytes,
        total_accounted_bytes=entropy_bytes + model_bytes,
        photo_count=photo_count,
    )


#: A 4:2:0 patch carries 1.5 coefficients per luma position, so the registered
#: ``train_loss_bits_per_pixel`` must be divided by this to compare against a
#: per-coefficient reference.
COEFFICIENTS_PER_LUMA_POSITION = 1.5


@dataclass(frozen=True)
class StaticFloorVerdict:
    bits_per_coefficient: float
    floor_bits_per_coefficient: float
    below_floor: bool
    patience_exhausted: bool
    should_stop: bool


def evaluate_static_floor(
    *,
    train_loss_bits_per_pixel: float,
    epoch: int,
    floor_bits_per_coefficient: float,
    patience_epochs: int,
) -> StaticFloorVerdict:
    """Decide whether an arm has failed the static-histogram sanity floor.

    A table of 192 static per-(component, frequency-position) histograms reaches
    1.471 bits per coefficient on real PocketWorld JPEGs while costing under a
    kilobyte and modelling no context at all. An arm that still sits above that
    line after its patience window is spending megabytes of model budget to do
    worse than a free baseline, so there is nothing left to learn from letting it
    run to the registered epoch limit.

    ``patience_epochs`` is counted from epoch zero, so a value of 20 means the
    verdict first bites when the epoch-20 record is written.
    """
    if floor_bits_per_coefficient <= 0:
        raise ValueError("static floor must be positive")
    if patience_epochs < 0:
        raise ValueError("patience must be non-negative")
    bits_per_coefficient = train_loss_bits_per_pixel / COEFFICIENTS_PER_LUMA_POSITION
    below_floor = bits_per_coefficient < floor_bits_per_coefficient
    patience_exhausted = epoch >= patience_epochs
    return StaticFloorVerdict(
        bits_per_coefficient=bits_per_coefficient,
        floor_bits_per_coefficient=floor_bits_per_coefficient,
        below_floor=below_floor,
        patience_exhausted=patience_exhausted,
        should_stop=patience_exhausted and not below_floor,
    )
