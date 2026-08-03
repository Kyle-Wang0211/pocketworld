import struct

import numpy as np

from jpeg_collection_model import (
    decode_child_frame,
    encode_child_frames,
    fit_homography_q32,
)
from jpeg_exact import make_exact_jpeg_frame


def _frame(component: np.ndarray, source_tag: str):
    coefficients = np.asarray(component, dtype="<i2").reshape(-1)
    payload = coefficients.tobytes()
    return make_exact_jpeg_frame(
        source_bytes=len(payload),
        source_sha256=source_tag * 64,
        tool_sha256="f" * 64,
        restart_interval=0,
        header=b"\xff\xd8synthetic\xff\xda",
        component_shapes=((2, 2),),
        coefficient_payload=payload,
    )


def test_homography_fit_is_preregistered_fixed_point_and_deterministic():
    child = np.array(
        [[0, 0], [8, 0], [0, 8], [8, 8], [16, 0], [0, 16], [16, 16], [24, 8]],
        dtype=np.float64,
    )
    root = child + np.array([16.0, 8.0])
    first, first_inliers = fit_homography_q32(child, root)
    second, second_inliers = fit_homography_q32(child, root)
    assert first == second
    assert first_inliers == second_inliers == len(child)
    assert first[8] == 1 << 32


def test_prediction_is_exact_and_uses_bounded_backward_state():
    root_coefficients = np.arange(4 * 64, dtype=np.int16).reshape(4, 64)
    child_coefficients = root_coefficients + np.int16(3)
    root = _frame(root_coefficients, "a")
    child = _frame(child_coefficients, "b")
    identity_q32 = (
        1 << 32,
        0,
        0,
        0,
        1 << 32,
        0,
        0,
        0,
        1 << 32,
    )

    encoded = encode_child_frames(
        parent_ordinal=0,
        child_ordinal=1,
        root=root,
        child=child,
        child_to_root_homography_q32=identity_q32,
        homography_inlier_count=8,
    )
    restored = decode_child_frame(root, encoded)

    assert restored.serialized == child.serialized
    assert encoded.parent_ordinal < encoded.child_ordinal
    assert set(encoded.frequency_selectors).issubset({0, 1})
    assert set(encoded.local_block_selectors).issubset(set(range(26)))
    assert encoded.residual_count == child.coefficient_count
    assert encoded.canonical_bytes() == encoded.canonical_bytes()
    assert len(encoded.residual_int32_le) == child.coefficient_count * 4
    assert struct.unpack_from("<i", encoded.residual_int32_le)[0] == 3

