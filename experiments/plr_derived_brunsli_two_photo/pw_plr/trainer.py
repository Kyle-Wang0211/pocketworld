"""Minimal exact-rate training primitives for the frozen Phase 2 runner."""

from __future__ import annotations

from dataclasses import dataclass
from collections import defaultdict
import math
from typing import Mapping

import torch


@dataclass(frozen=True)
class TrainBatchMetrics:
    loss_bits_per_pixel: float
    auxiliary_loss: float
    gradient_norm: float


def equal_tile_batches(
    images: list[Mapping[str, object]],
    *,
    batch_size: int,
) -> list[list[int]]:
    """Return deterministic batches whose photos have one exact tile count."""
    if batch_size <= 0:
        raise ValueError("batch_size must be positive")
    buckets: dict[int, list[int]] = defaultdict(list)
    for index, image in enumerate(images):
        tile_count = int(image["full_photo_tile_count"])
        if tile_count <= 0:
            raise ValueError("full photo tile count must be positive")
        buckets[tile_count].append(index)
    batches: list[list[int]] = []
    for tile_count in sorted(buckets):
        indexes = buckets[tile_count]
        batches.extend(
            indexes[start : start + batch_size]
            for start in range(0, len(indexes), batch_size)
        )
    return batches


def build_optimizers(
    model: torch.nn.Module,
    *,
    main_learning_rate: float,
    auxiliary_learning_rate: float,
) -> tuple[torch.optim.Optimizer, torch.optim.Optimizer]:
    named = dict(model.named_parameters())
    auxiliary_names = {
        name
        for name, parameter in named.items()
        if parameter.requires_grad and name.endswith(".quantiles")
    }
    main_names = {
        name
        for name, parameter in named.items()
        if parameter.requires_grad and name not in auxiliary_names
    }
    if not main_names or not auxiliary_names:
        raise ValueError("model must expose disjoint main and quantile parameters")
    main = torch.optim.Adam(
        (named[name] for name in sorted(main_names)),
        lr=main_learning_rate,
    )
    auxiliary = torch.optim.Adam(
        (named[name] for name in sorted(auxiliary_names)),
        lr=auxiliary_learning_rate,
    )
    return main, auxiliary


def _device_batch(
    batch: Mapping[str, torch.Tensor],
    device: torch.device,
) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
    return (
        batch["Y"].to(device),
        batch["Cb"].to(device),
        batch["Cr"].to(device),
    )


def train_batch(
    model: torch.nn.Module,
    batch: Mapping[str, torch.Tensor],
    main_optimizer: torch.optim.Optimizer,
    auxiliary_optimizer: torch.optim.Optimizer,
    *,
    gradient_clip_max_norm: float,
) -> TrainBatchMetrics:
    model.train()
    device = next(model.parameters()).device
    y, cb, cr = _device_batch(batch, device)
    main_optimizer.zero_grad(set_to_none=True)
    auxiliary_optimizer.zero_grad(set_to_none=True)
    output = model(y, cb, cr)
    pixel_count = y.shape[0] * 256 * 256
    loss = output["bpp_loss"].sum() / (-math.log(2.0) * pixel_count)
    if not torch.isfinite(loss):
        raise FloatingPointError("non-finite training rate loss")
    loss.backward()
    if any(
        parameter.grad is not None and not torch.isfinite(parameter.grad).all()
        for parameter in model.parameters()
    ):
        raise FloatingPointError("non-finite training gradient")
    gradient_norm = torch.nn.utils.clip_grad_norm_(
        model.parameters(),
        gradient_clip_max_norm,
    )
    main_optimizer.step()

    auxiliary_loss = model.aux_loss().mean()
    if not torch.isfinite(auxiliary_loss):
        raise FloatingPointError("non-finite auxiliary loss")
    auxiliary_loss.backward()
    auxiliary_optimizer.step()
    return TrainBatchMetrics(
        loss_bits_per_pixel=float(loss.detach().cpu()),
        auxiliary_loss=float(auxiliary_loss.detach().cpu()),
        gradient_norm=float(gradient_norm.detach().cpu()),
    )


def train_accumulated_batch(
    model: torch.nn.Module,
    batch: Mapping[str, torch.Tensor],
    main_optimizer: torch.optim.Optimizer,
    auxiliary_optimizer: torch.optim.Optimizer,
    *,
    microbatch_size: int,
    gradient_clip_max_norm: float,
) -> TrainBatchMetrics:
    """Execute one effective batch through bounded-memory microbatches."""
    if microbatch_size <= 0:
        raise ValueError("microbatch_size must be positive")
    effective_batch_size = int(batch["Y"].shape[0])
    if effective_batch_size <= 0:
        raise ValueError("effective batch must not be empty")
    model.train()
    device = next(model.parameters()).device
    main_optimizer.zero_grad(set_to_none=True)
    auxiliary_optimizer.zero_grad(set_to_none=True)
    loss_value = 0.0
    denominator = -math.log(2.0) * effective_batch_size * 256 * 256
    for start in range(0, effective_batch_size, microbatch_size):
        stop = min(start + microbatch_size, effective_batch_size)
        microbatch = {
            name: value[start:stop]
            for name, value in batch.items()
            if isinstance(value, torch.Tensor)
        }
        y, cb, cr = _device_batch(microbatch, device)
        output = model(y, cb, cr)
        loss = output["bpp_loss"].sum() / denominator
        if not torch.isfinite(loss):
            raise FloatingPointError("non-finite training rate loss")
        loss.backward()
        loss_value += float(loss.detach().cpu())
    if any(
        parameter.grad is not None and not torch.isfinite(parameter.grad).all()
        for parameter in model.parameters()
    ):
        raise FloatingPointError("non-finite training gradient")
    gradient_norm = torch.nn.utils.clip_grad_norm_(
        model.parameters(), gradient_clip_max_norm
    )
    main_optimizer.step()

    auxiliary_loss = model.aux_loss().mean()
    if not torch.isfinite(auxiliary_loss):
        raise FloatingPointError("non-finite auxiliary loss")
    auxiliary_loss.backward()
    auxiliary_optimizer.step()
    return TrainBatchMetrics(
        loss_bits_per_pixel=loss_value,
        auxiliary_loss=float(auxiliary_loss.detach().cpu()),
        gradient_norm=float(gradient_norm.detach().cpu()),
    )


@torch.no_grad()
def validation_patch_bits(
    model: torch.nn.Module,
    batch: Mapping[str, torch.Tensor],
) -> float:
    model.eval()
    device = next(model.parameters()).device
    y, cb, cr = _device_batch(batch, device)
    output = model(y, cb, cr)
    total_bits = output["bpp_loss"].sum() / -math.log(2.0)
    if not torch.isfinite(total_bits):
        raise FloatingPointError("non-finite validation rate")
    return float(total_bits.cpu())


@torch.no_grad()
def validation_patch_bits_microbatched(
    model: torch.nn.Module,
    batch: Mapping[str, torch.Tensor],
    *,
    microbatch_size: int,
) -> float:
    """Sum the same validation likelihoods without a full device batch."""
    if microbatch_size <= 0:
        raise ValueError("microbatch_size must be positive")
    batch_size = int(batch["Y"].shape[0])
    total_bits = 0.0
    for start in range(0, batch_size, microbatch_size):
        stop = min(start + microbatch_size, batch_size)
        microbatch = {
            name: value[start:stop]
            for name, value in batch.items()
            if isinstance(value, torch.Tensor)
        }
        total_bits += validation_patch_bits(model, microbatch)
    return total_bits
