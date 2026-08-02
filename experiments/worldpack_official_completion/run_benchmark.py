#!/usr/bin/env python3
"""Strict-lossless benchmark orchestrator; Task 1 freezes input identity only."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import tempfile

import yaml


EXPERIMENT_ROOT = Path(__file__).resolve().parent
CONTRACT_PATH = EXPERIMENT_ROOT / "experiment-contract.yaml"
MANIFEST_PATH = EXPERIMENT_ROOT / "input-manifest.yaml"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def build_manifest(capture_root: Path, capture_id: str) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    paths = [path for path in capture_root.rglob("*") if path.is_file()]
    paths.sort(key=lambda path: path.relative_to(capture_root).as_posix().encode("utf-8"))
    for path in paths:
        if path.is_symlink():
            raise ValueError(f"symbolic links are not valid frozen inputs: {path}")
        relative_path = path.relative_to(capture_root).as_posix()
        if PurePosixPath(relative_path).is_absolute() or ".." in PurePosixPath(relative_path).parts:
            raise ValueError(f"non-canonical relative path: {relative_path}")
        stat_before = path.stat()
        digest = sha256_file(path)
        stat_after = path.stat()
        if (stat_before.st_size, stat_before.st_mtime_ns) != (
            stat_after.st_size,
            stat_after.st_mtime_ns,
        ):
            raise RuntimeError(f"input changed while hashing: {relative_path}")
        entries.append(
            {
                "path": relative_path,
                "bytes": stat_after.st_size,
                "sha256": digest,
            }
        )
    return {
        "schema": "pw_worldpack_input_manifest_v1",
        "capture_id": capture_id,
        "ordering": "normalized_relative_path_utf8",
        "entry_count": len(entries),
        "source_bytes": sum(int(entry["bytes"]) for entry in entries),
        "entries": entries,
    }


def write_manifest() -> None:
    contract = yaml.safe_load(CONTRACT_PATH.read_text())
    capture_root = Path(contract["input"]["capture_root"])
    if not capture_root.is_dir():
        raise FileNotFoundError(f"frozen capture is unavailable: {capture_root}")
    manifest = build_manifest(capture_root, contract["input"]["capture_id"])
    encoded = (json.dumps(manifest, indent=2, sort_keys=False) + "\n").encode("utf-8")
    with tempfile.NamedTemporaryFile(
        dir=EXPERIMENT_ROOT,
        prefix=".input-manifest.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        temporary.write(encoded)
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, MANIFEST_PATH)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write-manifest", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.write_manifest:
        raise SystemExit("Task 1 supports only --write-manifest")
    write_manifest()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
