#!/usr/bin/env python3
"""Fail closed unless every frozen upstream input matches its SHA-256 lock."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_manifest(path: Path) -> list[tuple[str, str]]:
    entries: list[tuple[str, str]] = []
    seen: set[str] = set()
    for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or len(parts[0]) != 64:
            raise RuntimeError(f"invalid manifest line {number}")
        digest, relative = parts
        if any(character not in "0123456789abcdef" for character in digest):
            raise RuntimeError(f"invalid SHA-256 at line {number}")
        relative_path = Path(relative)
        if relative_path.is_absolute() or ".." in relative_path.parts:
            raise RuntimeError(f"unsafe source path at line {number}")
        normalized = relative_path.as_posix()
        if normalized in seen:
            raise RuntimeError(f"duplicate source path: {normalized}")
        seen.add(normalized)
        entries.append((digest, normalized))
    if not entries:
        raise RuntimeError("source hash manifest is empty")
    return entries


def verify(source_root: Path, manifest: Path) -> int:
    source_root = source_root.resolve(strict=True)
    entries = parse_manifest(manifest)
    for expected, relative in entries:
        candidate = source_root / relative
        if candidate.is_symlink() or not candidate.is_file():
            raise RuntimeError(f"missing or non-regular source: {relative}")
        actual = sha256_file(candidate)
        if actual != expected:
            raise RuntimeError(
                f"SHA-256 mismatch for {relative}: expected {expected}, got {actual}"
            )
    return len(entries)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()
    try:
        count = verify(args.source_root, args.manifest)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"official CPU MVS source verification failed: {error}", file=sys.stderr)
        return 1
    print(f"verified {count} frozen upstream files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
