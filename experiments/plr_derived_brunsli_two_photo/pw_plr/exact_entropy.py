"""Exact rANS bridge using the pinned CompressAI/ryg_rans extension."""

from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys
from typing import Sequence


def _ans_module():
    try:
        from compressai import ans
    except ModuleNotFoundError:
        upstream = Path(__file__).resolve().parent.parent / "build" / "plr-upstream"
        if not upstream.is_dir():
            raise RuntimeError("pinned PLR build is missing; run fetch_build_plr.sh")
        sys.path.insert(0, str(upstream))
        from compressai import ans
    return ans


def _validate_trace(
    cdfs: Sequence[Sequence[int]],
    offsets: Sequence[int],
) -> None:
    if len(cdfs) != len(offsets):
        raise ValueError("CDF and offset counts differ")
    for index, cdf in enumerate(cdfs):
        if len(cdf) < 3 or cdf[0] != 0 or cdf[-1] != 65536:
            raise ValueError(f"CDF {index} must start at 0 and end at 65536")
        if any(left >= right for left, right in zip(cdf, cdf[1:])):
            raise ValueError(f"CDF {index} must be strictly increasing")


def cdf_trace_sha256(
    cdfs: Sequence[Sequence[int]],
    offsets: Sequence[int],
) -> str:
    """Hash every integer decision consumed by the entropy coder."""
    _validate_trace(cdfs, offsets)
    digest = hashlib.sha256()
    digest.update(struct.pack("<Q", len(cdfs)))
    for cdf, offset in zip(cdfs, offsets):
        digest.update(struct.pack("<qQ", int(offset), len(cdf)))
        digest.update(struct.pack(f"<{len(cdf)}I", *cdf))
    return digest.hexdigest()


def encode_with_cdf_trace(
    symbols: Sequence[int],
    cdfs: Sequence[Sequence[int]],
    offsets: Sequence[int],
) -> bytes:
    """Encode one symbol per registered CDF without hidden model state."""
    _validate_trace(cdfs, offsets)
    if len(symbols) != len(cdfs):
        raise ValueError("symbol and CDF counts differ")
    for index, (symbol, cdf, offset) in enumerate(zip(symbols, cdfs, offsets)):
        maximum = int(offset) + len(cdf) - 2
        if not int(offset) <= int(symbol) <= maximum:
            raise ValueError(f"symbol {index} lies outside CDF support")
    indexes = list(range(len(symbols)))
    sizes = [len(cdf) for cdf in cdfs]
    return _ans_module().RansEncoder().encode_with_indexes(
        [int(symbol) for symbol in symbols],
        indexes,
        [list(cdf) for cdf in cdfs],
        sizes,
        [int(offset) for offset in offsets],
    )


def decode_with_cdf_trace(
    stream: bytes,
    cdfs: Sequence[Sequence[int]],
    offsets: Sequence[int],
) -> list[int]:
    """Decode using an independently regenerated integer CDF trace."""
    _validate_trace(cdfs, offsets)
    indexes = list(range(len(cdfs)))
    sizes = [len(cdf) for cdf in cdfs]
    return _ans_module().RansDecoder().decode_with_indexes(
        stream,
        indexes,
        [list(cdf) for cdf in cdfs],
        sizes,
        [int(offset) for offset in offsets],
    )
