"""Normalize current JPEG/JXL storage paths into logical original-JPEG paths."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Mapping


@dataclass(frozen=True)
class LogicalPhotoPlanEntry:
    logical_path: str
    storage_path: str
    storage_codec: str
    storage_bytes: int
    storage_sha256: str


def build_logical_photo_plan(
    entries: Iterable[Mapping[str, object]],
) -> tuple[LogicalPhotoPlanEntry, ...]:
    planned: list[LogicalPhotoPlanEntry] = []
    seen: set[str] = set()
    for entry in entries:
        storage_path = str(entry["path"])
        if not storage_path.startswith("photos_highres/"):
            continue
        if storage_path.lower().endswith(".jpg.jxl"):
            logical_path = storage_path[:-4]
            codec = "jxl_0_12_0_exact_jpeg"
        elif storage_path.lower().endswith(".jpg"):
            logical_path = storage_path
            codec = "jpeg_original"
        else:
            continue
        if logical_path in seen:
            raise ValueError(f"duplicate logical photo path: {logical_path}")
        seen.add(logical_path)
        planned.append(
            LogicalPhotoPlanEntry(
                logical_path=logical_path,
                storage_path=storage_path,
                storage_codec=codec,
                storage_bytes=int(entry["bytes"]),
                storage_sha256=str(entry["sha256"]),
            )
        )
    if not planned:
        raise ValueError("logical photo plan is empty")
    return tuple(sorted(planned, key=lambda item: item.logical_path.encode("utf-8")))

