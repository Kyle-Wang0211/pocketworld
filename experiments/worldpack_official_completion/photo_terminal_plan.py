"""Validate and assemble the terminal learned-photo WorldPack rewrite plan."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
from typing import Mapping, Any

from worldpack_semantic_rewrite import RawAddition


SEMANTIC_MANIFEST_PATH = "__semantic__/manifest.json"
MODEL_MEMBER_PATH = "__semantic__/photos/model.pwmst"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while block := source.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


@dataclass(frozen=True)
class TerminalPhotoRewritePlan:
    drop_paths: set[str]
    additions: tuple[RawAddition, ...]
    learned_records: dict[str, dict[str, object]]
    shared_model: dict[str, object]


def build_terminal_photo_rewrite_plan(
    logical_document: Mapping[str, Any],
    *,
    progress_records: Mapping[str, Mapping[str, Any]],
    selected_logical_paths: tuple[str, ...],
    model_storage_path: Path,
    model_storage_codec: str,
) -> TerminalPhotoRewritePlan:
    if not selected_logical_paths or len(selected_logical_paths) != len(
        set(selected_logical_paths)
    ):
        raise ValueError("terminal photo selection is empty or duplicated")
    photos = {
        str(photo["logical_path"]): photo for photo in logical_document["photos"]
    }
    if len(photos) != len(logical_document["photos"]):
        raise ValueError("duplicate logical photo path")
    unknown = set(selected_logical_paths) - set(photos)
    if unknown:
        raise ValueError(f"unknown logical photo selection: {min(unknown)}")
    if not model_storage_path.is_file() or model_storage_path.is_symlink():
        raise ValueError("model storage is not a regular file")
    if not model_storage_codec:
        raise ValueError("model storage codec identity is empty")

    model = {
        "path": MODEL_MEMBER_PATH,
        "bytes": model_storage_path.stat().st_size,
        "sha256": _sha256(model_storage_path),
        "codec": model_storage_codec,
    }
    additions: list[RawAddition] = [
        RawAddition(MODEL_MEMBER_PATH, model_storage_path)
    ]
    drops = {SEMANTIC_MANIFEST_PATH}
    learned: dict[str, dict[str, object]] = {}
    member_paths = {MODEL_MEMBER_PATH}
    for logical_path in sorted(selected_logical_paths, key=lambda value: value.encode()):
        record = progress_records.get(logical_path)
        if record is None:
            raise ValueError(f"selected photo has no completed record: {logical_path}")
        if (
            record.get("byte_equal") is not True
            or record.get("sha256_equal") is not True
            or record.get("integer_cdf_trace_equal") is not True
        ):
            raise ValueError(f"selected photo lacks exactness evidence: {logical_path}")
        archive = Path(str(record["photo_archive_path"]))
        side = Path(str(record["side_path"]))
        archive_member = str(record["photo_archive_member_path"])
        side_member = str(record["side_member_path"])
        for label, path, expected_bytes, expected_sha in (
            (
                "photo archive",
                archive,
                int(record["photo_archive_bytes"]),
                str(record["photo_archive_sha256"]),
            ),
            (
                "exact side",
                side,
                int(record["side_bytes"]),
                str(record["side_sha256"]),
            ),
        ):
            if (
                not path.is_file()
                or path.is_symlink()
                or path.stat().st_size != expected_bytes
                or _sha256(path) != expected_sha
            ):
                raise ValueError(f"{label} identity changed: {logical_path}")
        if archive_member in member_paths or side_member in member_paths:
            raise ValueError("duplicate learned photo member path")
        member_paths.update((archive_member, side_member))
        additions.extend(
            (RawAddition(archive_member, archive), RawAddition(side_member, side))
        )
        drops.add(str(photos[logical_path]["storage_path"]))
        learned[logical_path] = {
            "photo_archive_path": archive_member,
            "photo_archive_bytes": archive.stat().st_size,
            "photo_archive_sha256": _sha256(archive),
            "side_path": side_member,
            "side_bytes": side.stat().st_size,
            "side_sha256": _sha256(side),
        }
    return TerminalPhotoRewritePlan(
        drop_paths=drops,
        additions=tuple(additions),
        learned_records=learned,
        shared_model=model,
    )
