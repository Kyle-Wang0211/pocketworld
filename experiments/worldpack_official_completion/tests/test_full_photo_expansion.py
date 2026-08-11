from __future__ import annotations

from full_photo_expansion import (
    learned_member_paths,
    phase4_allows_full_project,
)


def test_full_project_runs_for_formal_winner_or_reachable_current_scope() -> None:
    winner = {
        "source_unchanged": True,
        "strictly_smaller_than_jxl_at_96": True,
        "stream_headroom_before_model_accounting": 1,
        "minimum_scope_break_even": 96,
    }
    assert phase4_allows_full_project(winner, photo_count=155) is True

    reachable = {
        **winner,
        "strictly_smaller_than_jxl_at_96": False,
        "minimum_scope_break_even": 140,
    }
    assert phase4_allows_full_project(reachable, photo_count=155) is True
    assert phase4_allows_full_project(reachable, photo_count=139) is False


def test_full_project_does_not_run_without_stream_headroom_or_exact_source() -> None:
    evidence = {
        "source_unchanged": True,
        "strictly_smaller_than_jxl_at_96": False,
        "stream_headroom_before_model_accounting": 0,
        "minimum_scope_break_even": None,
    }
    assert phase4_allows_full_project(evidence, photo_count=155) is False
    assert phase4_allows_full_project(
        {**evidence, "source_unchanged": False}, photo_count=155
    ) is False


def test_learned_member_paths_are_deterministic_and_path_safe() -> None:
    first = learned_member_paths("photos_highres/cell 1/slot#2.jpg")
    second = learned_member_paths("photos_highres/cell 1/slot#2.jpg")
    other = learned_member_paths("photos_highres/cell 1/slot#3.jpg")

    assert first == second
    assert first != other
    assert first.photo_archive.startswith("__semantic__/photos/")
    assert first.photo_archive.endswith(".pwpa")
    assert first.side.endswith(".pwbs")
    assert " " not in first.photo_archive and "#" not in first.photo_archive
