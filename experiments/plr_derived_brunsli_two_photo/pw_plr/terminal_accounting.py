"""Integer-only full-cost accounting for the frozen two-photo decision."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class TerminalPairAccounting:
    photo_stream_bytes: int
    accounted_model_bytes: int
    total_accounted_bytes: int


@dataclass(frozen=True)
class TerminalPairDecision:
    state: str
    jxl_pair_bytes: int
    stream_headroom_bytes: int
    formal_total_accounted_bytes: int
    minimum_scope_break_even: int | None


def account_terminal_pair(
    *,
    photo_archive_bytes: list[int],
    side_bytes: list[int],
    complete_model_storage_bytes: int,
    scope_photo_count: int,
) -> TerminalPairAccounting:
    if len(photo_archive_bytes) != 2 or len(side_bytes) != 2:
        raise ValueError("terminal accounting requires exactly two photos")
    values = [*photo_archive_bytes, *side_bytes, complete_model_storage_bytes]
    if any(value < 0 for value in values):
        raise ValueError("terminal byte counts must be non-negative")
    if complete_model_storage_bytes == 0:
        raise ValueError("terminal model storage must not be empty")
    if scope_photo_count <= 0:
        raise ValueError("scope photo count must be positive")
    stream_bytes = sum(photo_archive_bytes) + sum(side_bytes)
    model_bytes = (
        2 * complete_model_storage_bytes + scope_photo_count - 1
    ) // scope_photo_count
    return TerminalPairAccounting(
        photo_stream_bytes=stream_bytes,
        accounted_model_bytes=model_bytes,
        total_accounted_bytes=stream_bytes + model_bytes,
    )


def minimum_scope_break_even(
    *,
    model_bytes: int,
    stream_headroom_bytes: int,
) -> int | None:
    """Return minimum N satisfying B + ceil(2M/N) < J, or no solution."""
    if model_bytes <= 0:
        raise ValueError("model byte count must be positive")
    if stream_headroom_bytes <= 1:
        return None
    denominator = stream_headroom_bytes - 1
    return (2 * model_bytes + denominator - 1) // denominator


def decide_terminal_pair(
    *,
    jxl_pair_bytes: int,
    photo_stream_bytes: int,
    complete_model_storage_bytes: int,
    formal_scope_photo_count: int,
    approved_scope_max: int,
) -> TerminalPairDecision:
    if (
        jxl_pair_bytes <= 0
        or photo_stream_bytes <= 0
        or complete_model_storage_bytes <= 0
        or formal_scope_photo_count <= 0
        or approved_scope_max < formal_scope_photo_count
    ):
        raise ValueError("terminal decision inputs are outside the approved scope")
    accounted_model = (
        2 * complete_model_storage_bytes + formal_scope_photo_count - 1
    ) // formal_scope_photo_count
    formal_total = photo_stream_bytes + accounted_model
    headroom = jxl_pair_bytes - photo_stream_bytes
    break_even = minimum_scope_break_even(
        model_bytes=complete_model_storage_bytes,
        stream_headroom_bytes=headroom,
    )
    if formal_total < jxl_pair_bytes:
        state = f"winner_at_{formal_scope_photo_count}"
    elif break_even is not None and break_even <= approved_scope_max:
        state = (
            f"loser_at_{formal_scope_photo_count}_but_reachable_within_scope2"
        )
    else:
        state = (
            f"loser_at_{formal_scope_photo_count}_break_even_unreachable_scope2"
        )
    return TerminalPairDecision(
        state=state,
        jxl_pair_bytes=jxl_pair_bytes,
        stream_headroom_bytes=headroom,
        formal_total_accounted_bytes=formal_total,
        minimum_scope_break_even=break_even,
    )
