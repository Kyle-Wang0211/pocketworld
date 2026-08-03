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
