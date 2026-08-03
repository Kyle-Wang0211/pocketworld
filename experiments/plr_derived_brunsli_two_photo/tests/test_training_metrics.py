import torch

from pw_plr.training_metrics import (
    RawModelBytes,
    accounted_validation_bytes,
    raw_state_dict_bytes,
)


class TinyModel(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.weight = torch.nn.Parameter(torch.zeros(3, dtype=torch.float32))
        self.register_buffer("counter", torch.zeros(2, dtype=torch.int64))


def test_raw_state_dict_bytes_counts_parameters_and_required_buffers() -> None:
    result = raw_state_dict_bytes(TinyModel())

    assert result == RawModelBytes(
        parameter_bytes=12,
        buffer_bytes=16,
        complete_tensor_bytes=28,
    )


def test_validation_accounting_scales_equal_tile_groups_and_model_scope() -> None:
    result = accounted_validation_bytes(
        groups=[
            {"photo_count": 2, "tile_count": 10, "total_patch_bits": 160.0},
            {"photo_count": 1, "tile_count": 2, "total_patch_bits": 40.0},
        ],
        raw_model_bytes=1000,
        scope_photo_count=96,
    )

    assert result.estimated_entropy_bytes == 210
    assert result.accounted_model_bytes == 32
    assert result.total_accounted_bytes == 242
    assert result.photo_count == 3
