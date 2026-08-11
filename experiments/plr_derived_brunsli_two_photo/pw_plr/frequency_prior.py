"""Registered per-frequency scale prior for the PLR-derived entropy heads.

Why this exists
---------------
Quantized DCT coefficients span roughly three orders of magnitude across the 64
frequency positions (measured Y DC sigma ~490 down to ~0.17 at the highest
frequency). The registered training input transform is
``exact_float32_cast_without_normalization``, so every scale head had to learn
that whole range from a default initialisation. Epoch-2 evidence put the model
at 11.82 bits per coefficient, which is *worse* than the 8.02 bits a single
pooled Gaussian would achieve, i.e. predicted scales were systematically far too
wide.

Exactness contract
------------------
Nothing here touches the symbols that get entropy coded. ``GaussianConditional``
receives the untouched target tensor ``y``; this module only affects

1. the *context* tensors fed to ``entropy_parameters``, and
2. the *initial bias* of the scale half of each entropy-parameter head.

Both are conditioning-only. The coded alphabet, the integer CDF construction and
the reconstructed coefficients are bit-identical in definition to before.

The prior table is part of the decoder model artifact and is therefore charged
in ``M`` like any other weight. It is 192 float32 values (768 bytes).
"""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

import torch
from torch import nn

#: Floor applied to every measured sigma. Matches CompressAI's SCALES_MIN so a
#: prior can never initialise a head below the value the codec would clamp to.
SCALES_MIN = 0.11

PRIOR_SCHEMA = "pw_plr_frequency_prior_v1"


@dataclass(frozen=True)
class FrequencyPrior:
    """Per-frequency coefficient scales measured on the training split only.

    ``luma`` is ordered to match ``PLR_HIGH_TO_LOW_INDICES``, i.e. the channel
    axis of the ``(b, 64, h, w)`` luma tensor the model consumes. ``chroma`` is a
    single scalar because Cb/Cr arrive as spatial planes whose channel axis is
    not the frequency axis, and because chroma contributes far less rate (0.318
    and 0.289 bits per coefficient against 2.055 for luma).
    """

    luma: tuple[float, ...]
    chroma: float
    sample_count: int
    corpus_content_identity_sha256: str

    def __post_init__(self) -> None:
        if len(self.luma) != 64:
            raise ValueError("luma prior must hold exactly 64 frequency scales")
        if any(value < SCALES_MIN for value in self.luma):
            raise ValueError(f"luma prior must be floored at {SCALES_MIN}")
        if self.chroma < SCALES_MIN:
            raise ValueError(f"chroma prior must be floored at {SCALES_MIN}")
        if self.sample_count <= 0:
            raise ValueError("prior must be measured on at least one sample")

    def luma_tensor(self, device: torch.device | None = None) -> torch.Tensor:
        """Return the luma prior shaped for broadcasting over ``(b, 64, h, w)``."""
        return torch.tensor(self.luma, dtype=torch.float32, device=device).view(1, 64, 1, 1)

    def to_json(self) -> dict[str, object]:
        return {
            "schema": PRIOR_SCHEMA,
            "luma": list(self.luma),
            "chroma": self.chroma,
            "sample_count": self.sample_count,
            "corpus_content_identity_sha256": self.corpus_content_identity_sha256,
            "scales_min": SCALES_MIN,
        }

    @classmethod
    def from_json(cls, payload: dict[str, object]) -> "FrequencyPrior":
        if payload.get("schema") != PRIOR_SCHEMA:
            raise ValueError(f"unexpected frequency prior schema: {payload.get('schema')}")
        return cls(
            luma=tuple(float(value) for value in payload["luma"]),  # type: ignore[arg-type]
            chroma=float(payload["chroma"]),  # type: ignore[arg-type]
            sample_count=int(payload["sample_count"]),  # type: ignore[arg-type]
            corpus_content_identity_sha256=str(payload["corpus_content_identity_sha256"]),
        )

    @classmethod
    def read(cls, path: Path) -> "FrequencyPrior":
        return cls.from_json(json.loads(path.read_text()))

    def write(self, path: Path) -> None:
        path.write_text(json.dumps(self.to_json(), indent=2, sort_keys=True) + "\n")


def measure_frequency_prior(
    luma_patches: list[torch.Tensor],
    chroma_patches: list[torch.Tensor],
    *,
    corpus_content_identity_sha256: str,
) -> FrequencyPrior:
    """Measure per-frequency standard deviations from training-split patches.

    ``luma_patches`` are ``(blocks, blocks, 64)`` tensors exactly as
    ``extract_mlcc_patch`` returns them, so the last axis is already in PLR
    high-to-low order. ``chroma_patches`` are the ``(1, h, w)`` planes.
    """
    if not luma_patches:
        raise ValueError("frequency prior needs at least one luma patch")
    if not chroma_patches:
        raise ValueError("frequency prior needs at least one chroma patch")
    luma = torch.cat([patch.reshape(-1, 64) for patch in luma_patches], dim=0)
    chroma = torch.cat([patch.reshape(-1) for patch in chroma_patches], dim=0)
    luma_sigma = luma.to(torch.float64).std(dim=0).clamp_min(SCALES_MIN)
    chroma_sigma = float(chroma.to(torch.float64).std().clamp_min(SCALES_MIN))
    return FrequencyPrior(
        luma=tuple(float(value) for value in luma_sigma),
        chroma=chroma_sigma,
        sample_count=len(luma_patches),
        corpus_content_identity_sha256=corpus_content_identity_sha256,
    )


def _final_conv(entropy_parameters: nn.Module) -> nn.Conv2d:
    """Return the last convolution of an entropy-parameter stack."""
    convolutions = [module for module in entropy_parameters.modules() if isinstance(module, nn.Conv2d)]
    if not convolutions:
        raise ValueError("entropy parameter stack exposes no convolution to initialise")
    return convolutions[-1]


def _initialise_scale_head(
    entropy_parameters: nn.Module,
    scale_values: torch.Tensor,
    *,
    weight_damping: float,
) -> None:
    """Bias the scale half of a head towards ``scale_values`` at initialisation.

    ``GaussianConditionalLatentCodec`` splits its parameter tensor with
    ``params.chunk(2, 1)``, so the first half of the output channels carries the
    scales and the second half carries the means. Damping the final weights makes
    the initial prediction bias-dominated without freezing the head: gradients
    still flow and the network is free to learn any correction it wants.
    """
    convolution = _final_conv(entropy_parameters)
    out_channels = convolution.out_channels
    if out_channels % 2:
        raise ValueError("scales/means head must expose an even channel count")
    half = out_channels // 2
    if scale_values.numel() not in (1, half):
        raise ValueError(
            f"expected 1 or {half} scale values for this head, got {scale_values.numel()}"
        )
    with torch.no_grad():
        convolution.weight.mul_(weight_damping)
        if convolution.bias is None:
            raise ValueError("scale head must expose a bias to receive the prior")
        convolution.bias.zero_()
        convolution.bias[:half] = scale_values.to(convolution.bias.dtype).expand(half)


def apply_frequency_prior(
    model: nn.Module,
    prior: FrequencyPrior,
    *,
    weight_damping: float = 0.1,
) -> dict[str, int]:
    """Initialise every scale head of ``model`` from ``prior``.

    Returns a small report so the caller can persist exactly how many heads were
    touched. Raises if the model's head layout does not match the registered
    frequency groups, because a silent partial application would leave some
    heads at the default initialisation and make the arm uninterpretable.
    """
    luma = torch.tensor(prior.luma, dtype=torch.float32)
    chroma = torch.tensor([prior.chroma], dtype=torch.float32)
    frequency = list(model.frequency)
    if sum(frequency) != 64:
        raise ValueError("registered frequency groups must partition all 64 positions")
    report = {"luma_heads": 0, "luma_234_heads": 0, "chroma_heads": 0}

    offset = 0
    for index, group in enumerate(frequency):
        group_scales = luma[offset : offset + group]
        _initialise_scale_head(
            model.Gaussion_Ys[index].entropy_parameters,
            group_scales,
            weight_damping=weight_damping,
        )
        report["luma_heads"] += 1
        # Y2/Y3/Y4 share one head whose target is the concatenation of the same
        # frequency group from three sibling sub-bands, so the prior repeats.
        _initialise_scale_head(
            model.Gaussion_Ys_234[index].entropy_parameters,
            group_scales.repeat(3),
            weight_damping=weight_damping,
        )
        report["luma_234_heads"] += 1
        offset += group

    for head in (model.Guassian_cbcr_anchor, model.Guassian_cbcr_non_anchor):
        _initialise_scale_head(head.entropy_parameters, chroma, weight_damping=weight_damping)
        report["chroma_heads"] += 1

    return report


def normalise_luma_context(context: torch.Tensor, prior: FrequencyPrior) -> torch.Tensor:
    """Scale a ``(b, 64k, h, w)`` luma *context* tensor by the frequency prior.

    Only ever call this on tensors that feed ``entropy_parameters``. Passing a
    coding target through here would change the coded alphabet and break exact
    reconstruction, so the channel count is checked against whole 64-channel
    sub-bands to make an accidental target call fail loudly.
    """
    channels = context.shape[1]
    if channels % 64:
        raise ValueError(
            "luma context must be whole 64-channel sub-bands; refusing to scale "
            f"a {channels}-channel tensor that may be a coding target"
        )
    scale = prior.luma_tensor(context.device).repeat(1, channels // 64, 1, 1)
    return context / scale


def normalise_chroma_context(context: torch.Tensor, prior: FrequencyPrior) -> torch.Tensor:
    """Scale a chroma *context* plane by the scalar chroma prior."""
    return context / prior.chroma


def attach_context_normalisation(model: nn.Module, prior: FrequencyPrior) -> dict[str, object]:
    """Register the prior as decoder buffers so context tensors get normalised.

    The patched ``EfficientJPEGRecompression._ctx`` is a no-op until these
    buffers exist, so attaching them is the single variable that separates the
    ``scope2_normalised_context`` arm from its ``scope2_compact`` control.

    The buffers enter ``state_dict`` deliberately: they are required to decode
    the archive, so they belong in ``M`` like any other weight.
    """
    luma = prior.luma_tensor()
    chroma = torch.tensor(prior.chroma, dtype=torch.float32)
    if luma.shape != (1, 64, 1, 1):
        raise ValueError("luma context scale must broadcast over (b, 64, h, w)")
    model.register_buffer("_context_luma_scale", luma)
    model.register_buffer("_context_chroma_scale", chroma)
    model._context_normalisation = True
    return {
        "context_normalisation": True,
        "luma_scale_channels": int(luma.numel()),
        "chroma_scale": float(chroma),
        "buffer_bytes": int(luma.numel() * 4 + 4),
    }
