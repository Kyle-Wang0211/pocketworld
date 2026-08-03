import pytest

from pw_plr.model_accounting import (
    choose_final_model_storage,
    evaluate_break_even,
    provisional_raw_upper_bound,
)


def test_provisional_upper_bound_uses_raw_not_untrained_compressed_size() -> None:
    assert (
        provisional_raw_upper_bound(
            raw_complete_bytes=60_000_000,
            zstd_complete_bytes=58_000_000,
            zpaq_complete_bytes=57_000_000,
        )
        == 60_000_000
    )


def test_final_m_selects_smallest_exact_registered_candidate() -> None:
    result = choose_final_model_storage(
        {
            "raw": (60_000_000, True),
            "zstd-1.5.7-level-22": (57_000_000, True),
            "zpaq-7.15-method-5": (55_000_000, True),
        }
    )

    assert result.codec == "zpaq-7.15-method-5"
    assert result.complete_persisted_bytes == 55_000_000


def test_non_exact_model_storage_candidate_is_ineligible() -> None:
    result = choose_final_model_storage(
        {
            "raw": (60_000_000, True),
            "zstd-1.5.7-level-22": (10_000_000, False),
            "zpaq-7.15-method-5": (55_000_000, True),
        }
    )

    assert result.codec == "zpaq-7.15-method-5"


def test_unregistered_model_storage_candidate_is_rejected() -> None:
    with pytest.raises(ValueError, match="registered candidate set"):
        choose_final_model_storage(
            {
                "raw": (60_000_000, True),
                "zstd-1.5.7-level-22": (57_000_000, True),
                "zpaq-7.15-method-5": (55_000_000, True),
                "lzma2": (1, True),
            }
        )


def test_break_even_is_verified_and_reachable_at_300() -> None:
    result = evaluate_break_even(
        jxl_bytes=1_000,
        stream_bytes=600,
        final_model_bytes=59_800,
        formal_photo_count=141,
        approved_max_photo_count=300,
    )

    assert result.break_even_photo_count == 300
    assert result.reachable_under_approved_scope is True
    assert result.wins_at_formal_count is False
    assert result.verdict == "loser_at_141_but_reachable_within_scope2"


def test_break_even_above_300_is_an_unreachable_loss() -> None:
    result = evaluate_break_even(
        jxl_bytes=1_000,
        stream_bytes=600,
        final_model_bytes=60_000,
        formal_photo_count=141,
        approved_max_photo_count=300,
    )

    assert result.break_even_photo_count == 301
    assert result.reachable_under_approved_scope is False
    assert result.verdict == "loser_at_141_break_even_unreachable_scope2"


def test_nonpositive_stream_headroom_can_never_be_rescued() -> None:
    result = evaluate_break_even(
        jxl_bytes=1_000,
        stream_bytes=1_000,
        final_model_bytes=1,
        formal_photo_count=141,
        approved_max_photo_count=300,
    )

    assert result.break_even_photo_count is None
    assert result.reachable_under_approved_scope is False
    assert result.verdict == "loser_stream_before_model_accounting"


def test_formal_winner_uses_strict_inequality() -> None:
    result = evaluate_break_even(
        jxl_bytes=1_000,
        stream_bytes=500,
        final_model_bytes=100,
        formal_photo_count=141,
        approved_max_photo_count=300,
    )

    assert result.effective_bytes_at_formal_count == 502
    assert result.wins_at_formal_count is True
    assert result.verdict == "winner_at_141_pending_lepton_diagnostic"
