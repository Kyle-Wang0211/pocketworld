from __future__ import annotations

from photo_semantic_selection import PhotoStreamCandidate, select_photo_streams


def test_shared_model_is_selected_only_when_aggregate_savings_pay_for_it() -> None:
    result = select_photo_streams(
        (
            PhotoStreamCandidate("photos/a.jpg", "photos/a.jpg.jxl", 80, 50, 5),
            PhotoStreamCandidate("photos/b.jpg", "photos/b.jpg", 90, 60, 5),
            PhotoStreamCandidate("photos/c.jpg", "photos/c.jpg.jxl", 70, 75, 5),
        ),
        model_storage_bytes=20,
    )

    assert result.use_shared_model is True
    assert result.selected_logical_paths == ("photos/a.jpg", "photos/b.jpg")
    assert result.retained_logical_paths == ("photos/c.jpg",)
    assert result.incumbent_payload_bytes == 240
    assert result.candidate_payload_bytes == 210
    assert result.payload_savings_bytes == 30


def test_shared_model_is_rejected_when_stream_gain_does_not_cover_model() -> None:
    result = select_photo_streams(
        (
            PhotoStreamCandidate("photos/a.jpg", "photos/a.jpg.jxl", 80, 50, 5),
            PhotoStreamCandidate("photos/b.jpg", "photos/b.jpg", 90, 60, 5),
        ),
        model_storage_bytes=51,
    )

    assert result.use_shared_model is False
    assert result.selected_logical_paths == ()
    assert result.retained_logical_paths == ("photos/a.jpg", "photos/b.jpg")
    assert result.candidate_payload_bytes == result.incumbent_payload_bytes == 170
    assert result.payload_savings_bytes == 0


def test_equal_size_is_not_a_strict_winner() -> None:
    result = select_photo_streams(
        (PhotoStreamCandidate("photos/a.jpg", "photos/a.jpg.jxl", 80, 50, 5),),
        model_storage_bytes=25,
    )

    assert result.use_shared_model is False


def test_selection_is_order_independent_and_validates_unique_logical_paths() -> None:
    candidates = (
        PhotoStreamCandidate("photos/b.jpg", "photos/b.jpg", 90, 60, 5),
        PhotoStreamCandidate("photos/a.jpg", "photos/a.jpg.jxl", 80, 50, 5),
    )
    result = select_photo_streams(candidates, model_storage_bytes=20)
    assert result.selected_logical_paths == ("photos/a.jpg", "photos/b.jpg")

    try:
        select_photo_streams((candidates[0], candidates[0]), model_storage_bytes=0)
    except ValueError as error:
        assert "duplicate logical photo path" in str(error)
    else:
        raise AssertionError("duplicate logical paths must fail closed")
