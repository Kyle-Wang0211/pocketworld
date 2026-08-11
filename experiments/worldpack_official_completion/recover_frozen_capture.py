#!/usr/bin/env python3
"""Recover the frozen capture after temporary backup loss without mutating iPhone data."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess


EPHEMERAL_SHM = "official_sfm_live.db-shm"
PHOTO_ARCHIVE = "official_photo_archive.json"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def rebuild_photo_archive_manifest(
    current: dict[str, object], frozen_sources: set[str]
) -> dict[str, object]:
    entries = current.get("entries")
    if not isinstance(entries, dict):
        raise ValueError("photo archive manifest does not contain an entry map")
    rebuilt = dict(current)
    rebuilt["entries"] = {
        name: value for name, value in entries.items() if name in frozen_sources
    }
    if set(rebuilt["entries"]) != frozen_sources:
        missing = sorted(frozen_sources - set(rebuilt["entries"]))
        raise ValueError(f"current archive manifest is missing frozen entries: {missing}")
    return rebuilt


def recover(
    manifest_path: Path,
    current_root: Path,
    output_root: Path,
    djxl: Path,
    recovered_manifest_path: Path,
    report_path: Path,
    allow_ephemeral_shm_deviation: bool,
) -> None:
    manifest = json.loads(manifest_path.read_text())
    entries = manifest["entries"]
    if output_root.exists():
        raise FileExistsError(f"recovery output already exists: {output_root}")
    output_root.mkdir(parents=True)
    frozen_sources = {
        PurePosixPath(entry["path"]).name[: -len(".jxl")]
        for entry in entries
        if entry["path"].endswith(".jpg.jxl")
    }
    exact_entries = 0
    deviations: list[dict[str, object]] = []
    for entry in entries:
        relative = PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"non-canonical manifest path: {relative}")
        source = current_root.joinpath(*relative.parts)
        destination = output_root.joinpath(*relative.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)

        if source.is_file() and source.stat().st_size == entry["bytes"]:
            current_sha = sha256_file(source)
            if current_sha == entry["sha256"]:
                shutil.copy2(source, destination)
                exact_entries += 1
                continue
            if (
                relative.as_posix() == EPHEMERAL_SHM
                and allow_ephemeral_shm_deviation
            ):
                shutil.copy2(source, destination)
                deviations.append(
                    {
                        "path": relative.as_posix(),
                        "bytes": entry["bytes"],
                        "frozen_sha256": entry["sha256"],
                        "recovered_sha256": current_sha,
                        "classification": "sqlite_wal_index_ephemeral_same_length",
                    }
                )
                continue

        if relative.as_posix() == PHOTO_ARCHIVE:
            current = json.loads(source.read_text())
            rebuilt = rebuild_photo_archive_manifest(current, frozen_sources)
            encoded = json.dumps(rebuilt, indent=2).encode()
            destination.write_bytes(encoded)
        elif relative.as_posix().endswith(".jpg") and not source.exists():
            archive = Path(f"{source}.jxl")
            if not archive.is_file():
                raise FileNotFoundError(f"missing exact JPEG and JXL source: {relative}")
            subprocess.run(
                [str(djxl), str(archive), str(destination)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        else:
            raise ValueError(f"cannot recover frozen entry exactly: {relative}")

        if (
            destination.stat().st_size != entry["bytes"]
            or sha256_file(destination) != entry["sha256"]
        ):
            raise ValueError(f"recovered entry identity mismatch: {relative}")
        exact_entries += 1

    actual_paths = sorted(
        path.relative_to(output_root).as_posix()
        for path in output_root.rglob("*")
        if path.is_file()
    )
    expected_paths = [entry["path"] for entry in entries]
    if actual_paths != expected_paths:
        raise ValueError("recovered path set differs from frozen manifest")
    recovered_entries = [
        {
            "path": path,
            "bytes": (output_root / path).stat().st_size,
            "sha256": sha256_file(output_root / path),
        }
        for path in actual_paths
    ]
    recovered_manifest = {
        "schema": "pw_worldpack_recovered_input_manifest_v1",
        "capture_id": manifest["capture_id"],
        "ordering": manifest["ordering"],
        "entry_count": len(recovered_entries),
        "source_bytes": sum(entry["bytes"] for entry in recovered_entries),
        "entries": recovered_entries,
    }
    encoded_manifest = (json.dumps(recovered_manifest, indent=2) + "\n").encode()
    recovered_manifest_path.write_bytes(encoded_manifest)
    report = {
        "schema": "pw_worldpack_frozen_capture_recovery_v1",
        "frozen_manifest_sha256": sha256_file(manifest_path),
        "recovered_manifest_sha256": hashlib.sha256(encoded_manifest).hexdigest(),
        "entry_count": len(recovered_entries),
        "source_bytes": recovered_manifest["source_bytes"],
        "exact_frozen_entries": exact_entries,
        "deviation_count": len(deviations),
        "deviations": deviations,
        "jpeg_reconstruction_exact": 1,
        "photo_archive_manifest_reconstructed_exact": 1,
        "phone_mutated": False,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--current-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--djxl", type=Path, required=True)
    parser.add_argument("--recovered-manifest", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--allow-ephemeral-shm-deviation", action="store_true")
    arguments = parser.parse_args()
    recover(
        arguments.manifest,
        arguments.current_root,
        arguments.output_root,
        arguments.djxl,
        arguments.recovered_manifest,
        arguments.report,
        arguments.allow_ephemeral_shm_deviation,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

