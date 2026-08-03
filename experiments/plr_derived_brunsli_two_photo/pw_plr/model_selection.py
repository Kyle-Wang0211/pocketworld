"""Validation-only selection of the preregistered Phase 2 model arm."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


@dataclass(frozen=True)
class SelectedArm:
    arm_id: str
    validation_total_accounted_bytes: int
    raw_model_tensor_bytes: int
    checkpoint_sha256: str


def select_registered_arm(
    candidates: Mapping[str, Mapping[str, object]],
    *,
    registered_arm_ids: set[str],
) -> SelectedArm:
    """Apply the frozen validation, model-size, then arm-ID ordering."""
    if set(candidates) != registered_arm_ids:
        raise ValueError("selection must contain exactly the preregistered arms")
    eligible: list[SelectedArm] = []
    for arm_id, candidate in candidates.items():
        validation_bytes = int(candidate["validation_total_accounted_bytes"])
        model_bytes = int(candidate["raw_model_tensor_bytes"])
        checkpoint_sha256 = str(candidate["checkpoint_sha256"])
        if validation_bytes <= 0 or model_bytes <= 0 or len(checkpoint_sha256) != 64:
            raise ValueError(f"invalid selection evidence for arm {arm_id}")
        eligible.append(
            SelectedArm(
                arm_id=arm_id,
                validation_total_accounted_bytes=validation_bytes,
                raw_model_tensor_bytes=model_bytes,
                checkpoint_sha256=checkpoint_sha256,
            )
        )
    return min(
        eligible,
        key=lambda arm: (
            arm.validation_total_accounted_bytes,
            arm.raw_model_tensor_bytes,
            arm.arm_id,
        ),
    )
