import numpy as np
import pytest

from hybrid_predictor import (
    GeometryCandidates,
    PredictorError,
    apply_affine_q20,
    decode_component,
    encode_component,
)


def geometry(blocks: int, width: int) -> GeometryCandidates:
    indexes = np.arange(blocks, dtype=np.int32)
    return GeometryCandidates(
        global_parent_indexes=indexes,
        local_parent_indexes=indexes,
        parent_width=width,
        parent_height=blocks // width,
        child_width=width,
        child_height=blocks // width,
    )


def test_residual_restores_every_coefficient_bit() -> None:
    parent = np.tile(np.arange(64, dtype=np.int16), (4, 1))
    child = parent.copy()
    child[1, 5] = -17
    child[2, 33] = 1024

    encoded = encode_component(parent, child, geometry(4, 2), search_radius=1)
    restored = decode_component(parent, encoded)

    assert restored.dtype == np.int16
    assert restored.tobytes() == child.tobytes()


def test_zero_prediction_wins_stable_ties() -> None:
    parent = np.zeros((4, 64), dtype=np.int16)
    child = np.zeros((4, 64), dtype=np.int16)

    encoded = encode_component(parent, child, geometry(4, 2), search_radius=1)

    assert encoded.modes == bytes([0, 0, 0, 0])


def test_fixed_point_affine_rounding_is_integer_and_symmetric() -> None:
    values = np.array([[-3, -2, -1, 0, 1, 2, 3]], dtype=np.int16)
    scale = np.full(7, 3 << 19, dtype=np.int64)
    bias = np.full(7, 1 << 19, dtype=np.int64)

    predicted = apply_affine_q20(values, scale, bias)

    assert predicted.tolist() == [[-4, -2, -1, 1, 2, 4, 5]]


def test_bounded_search_records_motion_and_restores() -> None:
    parent = np.zeros((9, 64), dtype=np.int16)
    parent[4, :10] = 20
    child = np.zeros((9, 64), dtype=np.int16)
    child[3, :10] = 20
    base = np.arange(9, dtype=np.int32)
    local = base.copy()
    local[3] = 3
    candidates = GeometryCandidates(base, local, 3, 3, 3, 3)

    encoded = encode_component(parent, child, candidates, search_radius=1)

    assert encoded.modes[3] == 2
    assert (encoded.motion_dx[3], encoded.motion_dy[3]) == (1, 0)
    assert decode_component(parent, encoded).tobytes() == child.tobytes()


def test_reconstructed_left_context_can_win() -> None:
    parent = np.zeros((4, 64), dtype=np.int16)
    child = np.zeros((4, 64), dtype=np.int16)
    child[0, :10] = 7
    child[1, :10] = 7

    encoded = encode_component(parent, child, geometry(4, 2), search_radius=0)

    assert encoded.modes[1] == 3
    assert decode_component(parent, encoded).tobytes() == child.tobytes()


def test_decoder_rejects_corrupt_mode() -> None:
    parent = np.zeros((4, 64), dtype=np.int16)
    child = np.zeros((4, 64), dtype=np.int16)
    encoded = encode_component(parent, child, geometry(4, 2), search_radius=0)
    damaged = encoded.with_modes(bytes([255, 0, 0, 0]))

    with pytest.raises(PredictorError, match="mode"):
        decode_component(parent, damaged)

