import pytest

from pw_plr.exact_entropy import (
    cdf_trace_sha256,
    decode_with_cdf_trace,
    encode_with_cdf_trace,
)


def test_rans_round_trip_uses_the_exact_registered_cdf_trace() -> None:
    symbols = [0, 1, -1, 2, -2]
    cdfs = [[0, 13107, 26214, 39321, 52428, 65536]] * len(symbols)
    offsets = [-2] * len(symbols)

    encoded = encode_with_cdf_trace(symbols, cdfs, offsets)
    decoded = decode_with_cdf_trace(encoded, cdfs, offsets)

    assert decoded == symbols
    assert cdf_trace_sha256(cdfs, offsets) == cdf_trace_sha256(cdfs, offsets)
    changed = [list(cdf) for cdf in cdfs]
    changed[0][1] += 1
    assert cdf_trace_sha256(changed, offsets) != cdf_trace_sha256(cdfs, offsets)


def test_rans_rejects_invalid_cdf_or_out_of_range_symbol() -> None:
    with pytest.raises(ValueError, match="end at 65536"):
        encode_with_cdf_trace([0], [[0, 1, 2]], [0])
    with pytest.raises(ValueError, match="outside CDF support"):
        encode_with_cdf_trace([3], [[0, 32768, 65536]], [0])
