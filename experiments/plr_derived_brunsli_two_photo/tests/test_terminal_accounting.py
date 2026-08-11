import pytest

from pw_plr.terminal_accounting import (
    account_terminal_pair,
    decide_terminal_pair,
    minimum_scope_break_even,
)


def test_terminal_pair_counts_both_complete_photo_streams_and_scope2_model() -> None:
    accounting = account_terminal_pair(
        photo_archive_bytes=[2_000_000, 2_100_000],
        side_bytes=[598, 598],
        complete_model_storage_bytes=30_000_001,
        scope_photo_count=96,
    )
    assert accounting.photo_stream_bytes == 4_101_196
    assert accounting.accounted_model_bytes == 625_001
    assert accounting.total_accounted_bytes == 4_726_197


def test_terminal_pair_rejects_missing_photo_or_nonpositive_scope() -> None:
    with pytest.raises(ValueError, match="exactly two"):
        account_terminal_pair(
            photo_archive_bytes=[1],
            side_bytes=[1],
            complete_model_storage_bytes=1,
            scope_photo_count=96,
        )
    with pytest.raises(ValueError, match="scope"):
        account_terminal_pair(
            photo_archive_bytes=[1, 1],
            side_bytes=[1, 1],
            complete_model_storage_bytes=1,
            scope_photo_count=0,
        )


def test_break_even_is_the_smallest_integer_scope_that_wins() -> None:
    # B + ceil(2M/N) < J, with H = J - B = 11.
    assert minimum_scope_break_even(model_bytes=50, stream_headroom_bytes=11) == 10
    assert 100 // 9 > 10
    assert 100 // 10 == 10


@pytest.mark.parametrize("headroom", [0, -1])
def test_break_even_is_undefined_without_positive_stream_headroom(
    headroom: int,
) -> None:
    assert minimum_scope_break_even(
        model_bytes=50, stream_headroom_bytes=headroom
    ) is None


def test_terminal_decision_distinguishes_current_win_and_reachable_scale() -> None:
    winner = decide_terminal_pair(
        jxl_pair_bytes=5_000_000,
        photo_stream_bytes=4_000_000,
        complete_model_storage_bytes=30_000_000,
        formal_scope_photo_count=96,
        approved_scope_max=300,
    )
    assert winner.state == "winner_at_96"
    assert winner.minimum_scope_break_even == 61

    reachable = decide_terminal_pair(
        jxl_pair_bytes=5_000_000,
        photo_stream_bytes=4_500_000,
        complete_model_storage_bytes=30_000_000,
        formal_scope_photo_count=96,
        approved_scope_max=300,
    )
    assert reachable.state == "loser_at_96_but_reachable_within_scope2"
    assert reachable.minimum_scope_break_even == 121

    unreachable = decide_terminal_pair(
        jxl_pair_bytes=5_000_000,
        photo_stream_bytes=4_900_000,
        complete_model_storage_bytes=30_000_000,
        formal_scope_photo_count=96,
        approved_scope_max=300,
    )
    assert unreachable.state == "loser_at_96_break_even_unreachable_scope2"
    assert unreachable.minimum_scope_break_even == 601
