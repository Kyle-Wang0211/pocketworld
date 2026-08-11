"""Guard the frequency prior's exactness contract and head coverage."""

from __future__ import annotations

import json
from pathlib import Path
import sys

import pytest
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "build" / "plr-upstream"))

from pw_plr.frequency_prior import (  # noqa: E402
    SCALES_MIN,
    FrequencyPrior,
    apply_frequency_prior,
    measure_frequency_prior,
    normalise_chroma_context,
    normalise_luma_context,
)


def _prior(luma_value: float = 4.0, chroma: float = 2.0) -> FrequencyPrior:
    return FrequencyPrior(
        luma=tuple(float(luma_value + index) for index in range(64)),
        chroma=chroma,
        sample_count=3,
        corpus_content_identity_sha256="0" * 64,
    )


def _model():
    from compressai.models.base_eff import EfficientJPEGRecompression

    torch.manual_seed(20260803)
    return EfficientJPEGRecompression(N=32, M=48)


def test_prior_rejects_wrong_length_and_subfloor_values() -> None:
    with pytest.raises(ValueError):
        FrequencyPrior(luma=(1.0,), chroma=1.0, sample_count=1, corpus_content_identity_sha256="x")
    with pytest.raises(ValueError):
        FrequencyPrior(
            luma=tuple([SCALES_MIN / 2] * 64),
            chroma=1.0,
            sample_count=1,
            corpus_content_identity_sha256="x",
        )
    with pytest.raises(ValueError):
        FrequencyPrior(
            luma=tuple([1.0] * 64),
            chroma=SCALES_MIN / 2,
            sample_count=1,
            corpus_content_identity_sha256="x",
        )


def test_measured_prior_is_floored_and_round_trips(tmp_path: Path) -> None:
    luma = [torch.zeros(2, 2, 64)]
    chroma = [torch.zeros(1, 16, 16)]
    prior = measure_frequency_prior(luma, chroma, corpus_content_identity_sha256="a" * 64)
    assert min(prior.luma) >= SCALES_MIN
    assert prior.chroma >= SCALES_MIN

    path = tmp_path / "frequency-prior.json"
    prior.write(path)
    assert FrequencyPrior.read(path) == prior
    assert json.loads(path.read_text())["schema"] == "pw_plr_frequency_prior_v1"


def test_apply_prior_touches_only_entropy_parameter_heads() -> None:
    """The coding target never passes through entropy_parameters, so restricting
    every mutation to those stacks is what keeps reconstruction exact."""
    model = _model()
    before = {name: tensor.clone() for name, tensor in model.state_dict().items()}
    apply_frequency_prior(model, _prior())
    after = model.state_dict()

    changed = {name for name in before if not torch.equal(before[name], after[name])}
    assert changed, "prior must actually initialise something"
    assert all("entropy_parameters" in name for name in changed), sorted(changed)[:5]
    assert all(name.endswith((".weight", ".bias")) for name in changed)


def test_apply_prior_covers_every_registered_head() -> None:
    model = _model()
    report = apply_frequency_prior(model, _prior())
    assert report["luma_heads"] == len(model.frequency)
    assert report["luma_234_heads"] == len(model.frequency)
    assert report["chroma_heads"] == 2


def test_scale_half_of_head_receives_the_prior() -> None:
    model = _model()
    prior = _prior()
    apply_frequency_prior(model, prior)

    convolutions = [
        module
        for module in model.Gaussion_Ys[0].entropy_parameters.modules()
        if isinstance(module, torch.nn.Conv2d)
    ]
    bias = convolutions[-1].bias
    half = bias.numel() // 2
    group = model.frequency[0]
    assert torch.allclose(bias[:half], torch.tensor(prior.luma[:group]))
    assert torch.count_nonzero(bias[half:]) == 0


def test_y234_head_repeats_the_group_across_three_subbands() -> None:
    model = _model()
    prior = _prior()
    apply_frequency_prior(model, prior)

    convolutions = [
        module
        for module in model.Gaussion_Ys_234[1].entropy_parameters.modules()
        if isinstance(module, torch.nn.Conv2d)
    ]
    bias = convolutions[-1].bias
    half = bias.numel() // 2
    start = model.frequency[0]
    group = model.frequency[1]
    expected = torch.tensor(prior.luma[start : start + group]).repeat(3)
    assert torch.allclose(bias[:half], expected)


def test_luma_context_normalisation_rejects_partial_subbands() -> None:
    """A coding target is a frequency *group* (28, 8, 7 ... channels), never a
    whole 64-channel sub-band, so this check makes a target call fail loudly."""
    prior = _prior()
    with pytest.raises(ValueError):
        normalise_luma_context(torch.zeros(1, 28, 4, 4), prior)

    context = torch.ones(1, 128, 4, 4)
    scaled = normalise_luma_context(context, prior)
    assert scaled.shape == context.shape
    assert torch.allclose(scaled[0, 0], torch.full((4, 4), 1.0 / prior.luma[0]))
    assert torch.allclose(scaled[0, 64], torch.full((4, 4), 1.0 / prior.luma[0]))


def test_chroma_context_normalisation_divides_by_scalar() -> None:
    prior = _prior(chroma=8.0)
    context = torch.full((1, 2, 8, 8), 16.0)
    assert torch.allclose(normalise_chroma_context(context, prior), torch.full((1, 2, 8, 8), 2.0))
