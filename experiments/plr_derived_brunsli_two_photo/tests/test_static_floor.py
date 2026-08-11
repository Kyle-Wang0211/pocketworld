"""Guard the static-histogram early-stop verdict."""

from __future__ import annotations

import pytest
import yaml

from pw_plr.training_metrics import COEFFICIENTS_PER_LUMA_POSITION, evaluate_static_floor

FLOOR = 1.471


def _verdict(bits_per_pixel: float, epoch: int, patience: int = 20):
    return evaluate_static_floor(
        train_loss_bits_per_pixel=bits_per_pixel,
        epoch=epoch,
        floor_bits_per_coefficient=FLOOR,
        patience_epochs=patience,
    )


def test_converts_per_pixel_metric_to_per_coefficient() -> None:
    verdict = _verdict(3.0, epoch=0)
    assert verdict.bits_per_coefficient == pytest.approx(3.0 / COEFFICIENTS_PER_LUMA_POSITION)


def test_does_not_stop_before_patience_even_when_far_above_floor() -> None:
    verdict = _verdict(17.73, epoch=2)
    assert not verdict.below_floor
    assert not verdict.patience_exhausted
    assert not verdict.should_stop


def test_stops_when_patience_exhausted_and_still_above_floor() -> None:
    verdict = _verdict(17.73, epoch=20)
    assert not verdict.below_floor
    assert verdict.should_stop


def test_never_stops_once_below_floor() -> None:
    # 2.2 bits per pixel is 1.467 per coefficient, just inside the floor.
    verdict = _verdict(2.2, epoch=99)
    assert verdict.below_floor
    assert not verdict.should_stop


def test_floor_is_strict_so_matching_it_exactly_does_not_pass() -> None:
    verdict = _verdict(FLOOR * COEFFICIENTS_PER_LUMA_POSITION, epoch=20)
    assert not verdict.below_floor
    assert verdict.should_stop


def test_rejects_nonsensical_configuration() -> None:
    with pytest.raises(ValueError):
        _verdict(1.0, epoch=0, patience=-1)
    with pytest.raises(ValueError):
        evaluate_static_floor(
            train_loss_bits_per_pixel=1.0,
            epoch=0,
            floor_bits_per_coefficient=0.0,
            patience_epochs=1,
        )


def test_registered_config_matches_the_measured_floor() -> None:
    config = yaml.safe_load(open("phase2-model-config.yaml"))
    registered = config["training"]["static_floor_early_stop"]
    assert registered["floor_bits_per_coefficient"] == FLOOR
    assert registered["coefficients_per_luma_position"] == COEFFICIENTS_PER_LUMA_POSITION
    assert registered["floor_bits_per_pixel_equivalent"] == pytest.approx(
        FLOOR * COEFFICIENTS_PER_LUMA_POSITION
    )
