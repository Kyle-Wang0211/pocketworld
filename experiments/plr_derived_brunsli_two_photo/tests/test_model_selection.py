import pytest

from pw_plr.model_selection import select_registered_arm


def test_select_registered_arm_uses_validation_then_size_then_id() -> None:
    winner = select_registered_arm(
        {
            "official_width": {
                "validation_total_accounted_bytes": 1_000,
                "raw_model_tensor_bytes": 80_000_000,
                "checkpoint_sha256": "a" * 64,
            },
            "scope2_compact": {
                "validation_total_accounted_bytes": 900,
                "raw_model_tensor_bytes": 22_000_000,
                "checkpoint_sha256": "b" * 64,
            },
        },
        registered_arm_ids={"official_width", "scope2_compact"},
    )

    assert winner.arm_id == "scope2_compact"
    assert winner.validation_total_accounted_bytes == 900


def test_select_registered_arm_rejects_missing_or_extra_arm() -> None:
    with pytest.raises(ValueError, match="exactly the preregistered arms"):
        select_registered_arm(
            {"only": {}},
            registered_arm_ids={"official_width", "scope2_compact"},
        )
