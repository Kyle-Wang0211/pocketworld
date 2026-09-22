#!/usr/bin/env python3
"""Streaming, dependency-free artifact delta measurements."""

from __future__ import annotations

import array
import math
import pathlib
import sys
from typing import Any

from contract import ContractError, fail


CHUNK_BYTES = 1024 * 1024


def _float32_max_abs(left: bytes, right: bytes) -> float:
    if len(left) != len(right) or len(left) % 4 != 0:
        fail("float32 artifacts must have equal sizes divisible by four")
    if left == right:
        return 0.0
    lhs = array.array("f")
    rhs = array.array("f")
    lhs.frombytes(left)
    rhs.frombytes(right)
    if sys.byteorder != "little":
        lhs.byteswap()
        rhs.byteswap()
    maximum = 0.0
    for first, second in zip(lhs, rhs):
        if first == second:
            continue
        if math.isnan(first) or math.isnan(second):
            if math.isnan(first) and math.isnan(second):
                continue
            return math.inf
        delta = abs(first - second)
        if math.isnan(delta):
            return math.inf
        maximum = max(maximum, delta)
    return maximum


def compare_artifact_files(
    left: pathlib.Path, right: pathlib.Path, dtype: str
) -> dict[str, Any]:
    if left.stat().st_size != right.stat().st_size:
        fail(f"artifact byte sizes differ: {left} vs {right}")
    total_bytes = left.stat().st_size
    mismatched_bytes = 0
    max_abs = 0.0
    with left.open("rb") as lhs, right.open("rb") as rhs:
        while True:
            left_chunk = lhs.read(CHUNK_BYTES)
            right_chunk = rhs.read(CHUNK_BYTES)
            if not left_chunk and not right_chunk:
                break
            if len(left_chunk) != len(right_chunk):
                fail(f"artifact stream lengths differ: {left} vs {right}")
            mismatched_bytes += sum(
                first != second for first, second in zip(left_chunk, right_chunk)
            )
            if dtype == "float32":
                max_abs = max(max_abs, _float32_max_abs(left_chunk, right_chunk))
    result: dict[str, Any] = {
        "byte_mismatch_fraction": (
            mismatched_bytes / total_bytes if total_bytes else 0.0
        ),
        "mismatched_bytes": mismatched_bytes,
        "total_bytes": total_bytes,
    }
    if dtype == "float32":
        result["max_abs"] = max_abs
    return result
