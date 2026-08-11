"""Choose an exact-JPEG semantic stream subset with one shared model cost."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable


@dataclass(frozen=True)
class PhotoStreamCandidate:
    logical_path: str
    incumbent_storage_path: str
    incumbent_bytes: int
    learned_photo_bytes: int
    exact_side_bytes: int

    @property
    def learned_stream_bytes(self) -> int:
        return self.learned_photo_bytes + self.exact_side_bytes


@dataclass(frozen=True)
class PhotoStreamSelection:
    use_shared_model: bool
    selected_logical_paths: tuple[str, ...]
    retained_logical_paths: tuple[str, ...]
    incumbent_payload_bytes: int
    candidate_payload_bytes: int
    payload_savings_bytes: int
    model_storage_bytes: int


def select_photo_streams(
    candidates: Iterable[PhotoStreamCandidate],
    *,
    model_storage_bytes: int,
) -> PhotoStreamSelection:
    """Return the globally minimal payload plan for one fixed shared model.

    For a fixed model, every photo whose learned stream is smaller can be
    selected independently.  The model is retained only when their aggregate
    strict savings also pays for the complete self-contained model artifact.
    WorldPack framing is intentionally excluded here and must be decided by the
    terminal full-archive byte comparison.
    """
    if model_storage_bytes < 0:
        raise ValueError("model storage bytes must not be negative")
    ordered = tuple(sorted(candidates, key=lambda item: item.logical_path.encode()))
    if not ordered:
        raise ValueError("photo candidate set is empty")
    logical_paths = [item.logical_path for item in ordered]
    if len(logical_paths) != len(set(logical_paths)):
        raise ValueError("duplicate logical photo path")
    storage_paths = [item.incumbent_storage_path for item in ordered]
    if len(storage_paths) != len(set(storage_paths)):
        raise ValueError("duplicate incumbent photo storage path")
    for item in ordered:
        if (
            not item.logical_path
            or not item.incumbent_storage_path
            or item.incumbent_bytes <= 0
            or item.learned_photo_bytes < 0
            or item.exact_side_bytes < 0
        ):
            raise ValueError("invalid photo stream candidate")

    incumbent_bytes = sum(item.incumbent_bytes for item in ordered)
    beneficial = tuple(
        item
        for item in ordered
        if item.learned_stream_bytes < item.incumbent_bytes
    )
    stream_savings = sum(
        item.incumbent_bytes - item.learned_stream_bytes for item in beneficial
    )
    use_model = bool(beneficial) and stream_savings > model_storage_bytes
    if use_model:
        selected = tuple(item.logical_path for item in beneficial)
        selected_set = set(selected)
        retained = tuple(
            item.logical_path
            for item in ordered
            if item.logical_path not in selected_set
        )
        candidate_bytes = incumbent_bytes - stream_savings + model_storage_bytes
    else:
        selected = ()
        retained = tuple(item.logical_path for item in ordered)
        candidate_bytes = incumbent_bytes
    return PhotoStreamSelection(
        use_shared_model=use_model,
        selected_logical_paths=selected,
        retained_logical_paths=retained,
        incumbent_payload_bytes=incumbent_bytes,
        candidate_payload_bytes=candidate_bytes,
        payload_savings_bytes=incumbent_bytes - candidate_bytes,
        model_storage_bytes=model_storage_bytes if use_model else 0,
    )
