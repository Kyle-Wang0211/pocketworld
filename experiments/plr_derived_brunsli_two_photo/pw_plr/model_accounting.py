"""Exact integer accounting for the PLR-derived two-photo experiment."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping


REGISTERED_STORAGE_CANDIDATES = frozenset(
    {
        "raw",
        "zstd-1.5.7-level-22",
        "zpaq-7.15-method-5",
    }
)


@dataclass(frozen=True)
class ModelStorageChoice:
    codec: str
    complete_persisted_bytes: int


@dataclass(frozen=True)
class BreakEvenResult:
    formal_photo_count: int
    stream_headroom_bytes: int
    effective_bytes_at_formal_count: int
    wins_at_formal_count: bool
    break_even_photo_count: int | None
    reachable_under_approved_scope: bool
    verdict: str


def ceil_div(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise ValueError(
            "ceil_div requires numerator >= 0 and denominator > 0"
        )
    return (numerator + denominator - 1) // denominator


def provisional_raw_upper_bound(
    *,
    raw_complete_bytes: int,
    zstd_complete_bytes: int,
    zpaq_complete_bytes: int,
) -> int:
    for value in (
        raw_complete_bytes,
        zstd_complete_bytes,
        zpaq_complete_bytes,
    ):
        if value <= 0:
            raise ValueError("provisional model artifacts must be non-empty")
    return raw_complete_bytes


def choose_final_model_storage(
    candidates: Mapping[str, tuple[int, bool]],
) -> ModelStorageChoice:
    if set(candidates) != REGISTERED_STORAGE_CANDIDATES:
        raise ValueError("model storage keys must equal the registered candidate set")

    eligible: list[ModelStorageChoice] = []
    for codec, (complete_bytes, exact) in candidates.items():
        if complete_bytes <= 0:
            raise ValueError("model storage candidates must be non-empty")
        if exact:
            eligible.append(ModelStorageChoice(codec, complete_bytes))

    if not eligible:
        raise ValueError("no exact model storage candidate is eligible")
    return min(eligible, key=lambda candidate: (candidate.complete_persisted_bytes, candidate.codec))


def evaluate_break_even(
    *,
    jxl_bytes: int,
    stream_bytes: int,
    final_model_bytes: int,
    formal_photo_count: int,
    approved_max_photo_count: int,
) -> BreakEvenResult:
    if jxl_bytes <= 0:
        raise ValueError("JXL baseline must be non-empty")
    if stream_bytes < 0:
        raise ValueError("candidate stream bytes must be non-negative")
    if final_model_bytes <= 0:
        raise ValueError("final model must be non-empty")
    if formal_photo_count <= 0 or approved_max_photo_count <= 0:
        raise ValueError("photo counts must be positive")

    headroom = jxl_bytes - stream_bytes
    effective_formal = stream_bytes + ceil_div(
        2 * final_model_bytes, formal_photo_count
    )
    wins_formal = effective_formal < jxl_bytes

    if headroom <= 0 or headroom == 1:
        return BreakEvenResult(
            formal_photo_count=formal_photo_count,
            stream_headroom_bytes=headroom,
            effective_bytes_at_formal_count=effective_formal,
            wins_at_formal_count=wins_formal,
            break_even_photo_count=None,
            reachable_under_approved_scope=False,
            verdict="loser_stream_before_model_accounting",
        )

    break_even = ceil_div(2 * final_model_bytes, headroom - 1)
    if stream_bytes + ceil_div(2 * final_model_bytes, break_even) >= jxl_bytes:
        raise AssertionError("computed break-even point does not win")
    if break_even > 1 and (
        stream_bytes + ceil_div(2 * final_model_bytes, break_even - 1)
        < jxl_bytes
    ):
        raise AssertionError("computed break-even point is not minimal")

    reachable = break_even <= approved_max_photo_count
    if wins_formal:
        verdict = "winner_at_formal_count_pending_lepton_diagnostic"
    elif reachable:
        verdict = "loser_at_formal_count_but_reachable_within_scope2"
    else:
        verdict = "loser_at_formal_count_break_even_unreachable_scope2"

    return BreakEvenResult(
        formal_photo_count=formal_photo_count,
        stream_headroom_bytes=headroom,
        effective_bytes_at_formal_count=effective_formal,
        wins_at_formal_count=wins_formal,
        break_even_photo_count=break_even,
        reachable_under_approved_scope=reachable,
        verdict=verdict,
    )
