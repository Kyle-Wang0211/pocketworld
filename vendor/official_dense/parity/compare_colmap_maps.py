#!/usr/bin/env python3
"""Compare two diagnostic COLMAP float matrices without guessing tolerances."""

from __future__ import annotations

import argparse
import array
import json
import math
import pathlib
import sys
from typing import Any, BinaryIO

from contract import ContractError, fail, sha256_file


VALUES_PER_CHUNK = 256 * 1024


def _read_dimension(stream: BinaryIO) -> int:
    digits = bytearray()
    while len(digits) <= 20:
        value = stream.read(1)
        if value == b"&":
            break
        if len(value) != 1 or value < b"0" or value > b"9":
            fail("invalid COLMAP float matrix header")
        digits.extend(value)
    if not digits or len(digits) > 20:
        fail("invalid COLMAP float matrix dimension")
    dimension = int(digits.decode("ascii"))
    if dimension <= 0:
        fail("COLMAP float matrix dimensions must be positive")
    return dimension


def _read_header(stream: BinaryIO) -> tuple[int, int, int]:
    return (
        _read_dimension(stream),
        _read_dimension(stream),
        _read_dimension(stream),
    )


def _read_values(stream: BinaryIO, count: int) -> array.array[float]:
    payload = stream.read(count * 4)
    if len(payload) != count * 4:
        fail("truncated COLMAP float matrix payload")
    values = array.array("f")
    values.frombytes(payload)
    if sys.byteorder != "little":
        values.byteswap()
    return values


def inspect_float_matrix_range(
    path: pathlib.Path, minimum: float, maximum: float
) -> dict[str, Any]:
    """Measure a COLMAP float matrix against its frozen depth interval."""

    if (
        not math.isfinite(minimum)
        or not math.isfinite(maximum)
        or minimum >= maximum
    ):
        fail("invalid frozen depth interval")
    path = pathlib.Path(path)
    try:
        stream = path.open("rb")
    except OSError as error:
        fail(f"cannot open COLMAP float matrix: {error}")
    with stream:
        shape = _read_header(stream)
        total_values = math.prod(shape)
        remaining = total_values
        finite_count = 0
        nonfinite_count = 0
        within_range_count = 0
        below_min_count = 0
        positive_below_min_count = 0
        above_max_count = 0
        zero_or_negative_count = 0
        min_finite = math.inf
        max_finite = -math.inf
        while remaining > 0:
            chunk_count = min(remaining, VALUES_PER_CHUNK)
            for value in _read_values(stream, chunk_count):
                if not math.isfinite(value):
                    nonfinite_count += 1
                    continue
                finite_count += 1
                min_finite = min(min_finite, value)
                max_finite = max(max_finite, value)
                if value <= 0.0:
                    zero_or_negative_count += 1
                if value < minimum:
                    below_min_count += 1
                    if value > 0.0:
                        positive_below_min_count += 1
                elif value > maximum:
                    above_max_count += 1
                else:
                    within_range_count += 1
            remaining -= chunk_count
        if stream.read(1):
            fail("COLMAP float matrix contains trailing payload bytes")
    return {
        "shape": list(shape),
        "value_count": total_values,
        "finite_count": finite_count,
        "nonfinite_count": nonfinite_count,
        "within_range_count": within_range_count,
        "below_min_count": below_min_count,
        "positive_below_min_count": positive_below_min_count,
        "above_max_count": above_max_count,
        "zero_or_negative_count": zero_or_negative_count,
        "min_finite": None if finite_count == 0 else min_finite,
        "max_finite": None if finite_count == 0 else max_finite,
    }


def compare_float_matrix_files(
    reference: pathlib.Path, candidate: pathlib.Path
) -> dict[str, Any]:
    """Return structural and numerical deltas for two COLMAP Mat<float> files."""

    reference = pathlib.Path(reference)
    candidate = pathlib.Path(candidate)
    try:
        left_stream = reference.open("rb")
    except OSError as error:
        fail(f"cannot open COLMAP float matrix: {error}")
    try:
        right_stream = candidate.open("rb")
    except OSError as error:
        left_stream.close()
        fail(f"cannot open COLMAP float matrix: {error}")

    with left_stream, right_stream:
        left_shape = _read_header(left_stream)
        right_shape = _read_header(right_stream)
        if left_shape != right_shape:
            fail(
                "COLMAP float matrix shapes differ: "
                f"{left_shape} vs {right_shape}"
            )
        total_values = math.prod(left_shape)
        remaining = total_values
        mismatched_values = 0
        nonfinite_mismatches = 0
        squared_error = 0.0
        max_abs = 0.0
        payload_bitwise_identical = True
        while remaining > 0:
            chunk_count = min(remaining, VALUES_PER_CHUNK)
            left_values = _read_values(left_stream, chunk_count)
            right_values = _read_values(right_stream, chunk_count)
            if left_values.tobytes() != right_values.tobytes():
                payload_bitwise_identical = False
            for left, right in zip(left_values, right_values):
                if left == right or (math.isnan(left) and math.isnan(right)):
                    continue
                mismatched_values += 1
                if not math.isfinite(left) or not math.isfinite(right):
                    nonfinite_mismatches += 1
                    max_abs = math.inf
                    squared_error = math.inf
                    continue
                delta = abs(left - right)
                max_abs = max(max_abs, delta)
                squared_error += delta * delta
            remaining -= chunk_count
        if left_stream.read(1) or right_stream.read(1):
            fail("COLMAP float matrix contains trailing payload bytes")

    reference_sha256 = sha256_file(reference)
    candidate_sha256 = sha256_file(candidate)
    bitwise_identical = (
        payload_bitwise_identical and reference_sha256 == candidate_sha256
    )
    numerical_max_abs: float | None = max_abs
    numerical_rms: float | None = math.sqrt(squared_error / total_values)
    if nonfinite_mismatches != 0:
        numerical_max_abs = None
        numerical_rms = None
    return {
        "reference": str(reference.resolve()),
        "candidate": str(candidate.resolve()),
        "reference_sha256": reference_sha256,
        "candidate_sha256": candidate_sha256,
        "shape": list(left_shape),
        "value_count": total_values,
        "bitwise_identical": bitwise_identical,
        "mismatched_values": mismatched_values,
        "mismatch_fraction": mismatched_values / total_values,
        "nonfinite_mismatches": nonfinite_mismatches,
        "max_abs": numerical_max_abs,
        "rms": numerical_rms,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Measure two COLMAP float matrices. Numerical acceptance still "
            "requires the separately measured CUDA noise-floor contract."
        )
    )
    parser.add_argument("--reference", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--require-bitwise-identical", action="store_true")
    args = parser.parse_args()
    try:
        result = compare_float_matrix_files(args.reference, args.candidate)
    except ContractError as error:
        print(f"FAIL-CLOSED: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    if args.require_bitwise_identical and not result["bitwise_identical"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
