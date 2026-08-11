"""Pure expansion gates and member identities for full-project photo research."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from typing import Mapping


@dataclass(frozen=True)
class LearnedMemberPaths:
    photo_archive: str
    side: str


def learned_member_paths(logical_path: str) -> LearnedMemberPaths:
    if not logical_path:
        raise ValueError("logical photo path is empty")
    identity = hashlib.sha256(logical_path.encode("utf-8")).hexdigest()[:24]
    prefix = f"__semantic__/photos/{identity}"
    return LearnedMemberPaths(
        photo_archive=f"{prefix}.pwpa",
        side=f"{prefix}.pwbs",
    )


def phase4_allows_full_project(
    phase4: Mapping[str, object],
    *,
    photo_count: int,
) -> bool:
    if photo_count <= 0 or phase4.get("source_unchanged") is not True:
        return False
    if int(phase4.get("stream_headroom_before_model_accounting", 0)) <= 0:
        return False
    if phase4.get("strictly_smaller_than_jxl_at_96") is True:
        return True
    break_even = phase4.get("minimum_scope_break_even")
    return break_even is not None and int(break_even) <= photo_count
