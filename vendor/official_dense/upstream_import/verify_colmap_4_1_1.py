#!/usr/bin/env python3
"""Fail-closed, read-only verifier for the pinned COLMAP source closure."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any


EXPECTED_SCOPES = (
    "mvs_direct_sources",
    "known_local_differences",
    "cuda_reference_only",
)
EXPECTED_EXCLUSIONS = {"SiftGPU", "LSD", "Qt", "CUDA"}
EXPECTED_LICENSES = {"COPYING.txt", "src/thirdparty/VLFeat/LICENSE"}


def _git_blob_sha(data: bytes) -> str:
    header = f"blob {len(data)}\0".encode("ascii")
    return hashlib.sha1(header + data).hexdigest()  # noqa: S324: Git object ID.


def _run_git(source_root: Path, revision: str) -> tuple[str | None, str | None]:
    try:
        result = subprocess.run(
            ["git", "-C", str(source_root), "rev-parse", "--verify", revision],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
    except subprocess.TimeoutExpired:
        return None, "git identity check timed out"
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "git failed"
        return None, detail
    return result.stdout.strip(), None


def _load_manifest(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise ValueError("manifest root must be an object")
    return value


def _validate_manifest(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if manifest.get("schema_version") != 1:
        errors.append("manifest: unsupported schema_version")

    scopes = manifest.get("scopes")
    if not isinstance(scopes, dict):
        errors.append("manifest: scopes must be an object")
        scopes = {}
    for scope in EXPECTED_SCOPES:
        if not isinstance(scopes.get(scope), list):
            errors.append(f"manifest: missing scope {scope}")

    exclusions = manifest.get("excluded_build_components")
    if not isinstance(exclusions, list) or set(exclusions) != EXPECTED_EXCLUSIONS:
        errors.append(
            "manifest: excluded_build_components must be exactly "
            "SiftGPU, LSD, Qt, CUDA"
        )

    licenses = manifest.get("licenses")
    if not isinstance(licenses, list):
        errors.append("manifest: licenses must be a list")
        licenses = []
    license_paths = {
        entry.get("path") for entry in licenses if isinstance(entry, dict)
    }
    if license_paths != EXPECTED_LICENSES:
        errors.append("manifest: COLMAP BSD and VLFeat BSD notices are mandatory")

    seen: set[str] = set()
    groups: list[tuple[str, Any]] = [("licenses", licenses)]
    groups.extend((scope, scopes.get(scope, [])) for scope in EXPECTED_SCOPES)
    for group, entries in groups:
        for index, entry in enumerate(entries):
            if not isinstance(entry, dict):
                errors.append(f"manifest: {group}[{index}] must be an object")
                continue
            path = entry.get("path")
            git_blob = entry.get("git_blob")
            sha256 = entry.get("sha256")
            if not isinstance(path, str) or not path:
                errors.append(f"manifest: {group}[{index}] has invalid path")
                continue
            pure = PurePosixPath(path)
            if pure.is_absolute() or ".." in pure.parts or str(pure) != path:
                errors.append(f"manifest: unsafe path {path}")
            if path in seen:
                errors.append(f"manifest: duplicate path {path}")
            seen.add(path)
            if not isinstance(git_blob, str) or len(git_blob) != 40:
                errors.append(f"manifest: invalid Git blob ID for {path}")
            if not isinstance(sha256, str) or len(sha256) != 64:
                errors.append(f"manifest: invalid SHA-256 for {path}")
    return errors


def _all_entries(manifest: dict[str, Any]) -> list[dict[str, str]]:
    scopes = manifest["scopes"]
    entries: list[dict[str, str]] = []
    for scope in EXPECTED_SCOPES:
        entries.extend(scopes[scope])
    entries.extend(manifest["licenses"])
    return entries


def _candidate_for_layout(root: Path, relative: str) -> Path:
    parts = PurePosixPath(relative).parts
    direct = root.joinpath(*parts)
    if direct.exists() or not parts or parts[0] != "src":
        return direct
    # Some existing vendored snapshots copied the contents of upstream src/
    # as their root. Supporting that embedded src layout lets this verifier
    # diagnose the precise official-file drift without treating it as official.
    return root.joinpath(*parts[1:])


def verify(source_root: Path, manifest: dict[str, Any]) -> list[str]:
    errors = _validate_manifest(manifest)
    if errors:
        return errors

    try:
        root = source_root.resolve(strict=True)
    except FileNotFoundError:
        return [f"source root missing: {source_root}"]
    if not root.is_dir():
        return [f"source root is not a directory: {root}"]

    if manifest.get("require_git_identity", True):
        if not root.joinpath(".git").exists():
            actual_commit = None
            actual_tree = None
            commit_error = "source root has no .git identity"
            tree_error = "source root has no .git identity"
        else:
            actual_commit, commit_error = _run_git(root, "HEAD^{commit}")
            actual_tree, tree_error = _run_git(root, "HEAD^{tree}")
        if commit_error is not None:
            errors.append(f"repository identity unavailable: {commit_error}")
        elif actual_commit != manifest.get("commit"):
            errors.append(
                f"repository commit mismatch: expected {manifest.get('commit')}, "
                f"got {actual_commit}"
            )
        if tree_error is not None:
            errors.append(f"repository tree unavailable: {tree_error}")
        elif actual_tree != manifest.get("tree"):
            errors.append(
                f"repository tree mismatch: expected {manifest.get('tree')}, "
                f"got {actual_tree}"
            )

    for entry in _all_entries(manifest):
        relative = entry["path"]
        candidate = _candidate_for_layout(root, relative)
        try:
            resolved = candidate.resolve(strict=True)
        except FileNotFoundError:
            errors.append(f"missing: {relative}")
            continue
        try:
            resolved.relative_to(root)
        except ValueError:
            errors.append(f"path escapes source root: {relative}")
            continue
        if not resolved.is_file():
            errors.append(f"not a regular file: {relative}")
            continue

        data = resolved.read_bytes()
        actual_blob = _git_blob_sha(data)
        actual_sha256 = hashlib.sha256(data).hexdigest()
        if actual_blob != entry["git_blob"] or actual_sha256 != entry["sha256"]:
            errors.append(
                f"hash mismatch: {relative}: expected blob {entry['git_blob']} "
                f"and sha256 {entry['sha256']}, got blob {actual_blob} "
                f"and sha256 {actual_sha256}"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify a local source tree against a pinned COLMAP manifest."
    )
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("colmap_4_1_1_manifest.json"),
    )
    parser.add_argument("--json", action="store_true", dest="as_json")
    args = parser.parse_args()

    try:
        manifest = _load_manifest(args.manifest)
        errors = verify(args.source_root, manifest)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        errors = [f"manifest error: {error}"]

    if args.as_json:
        print(json.dumps({"ok": not errors, "errors": errors}, indent=2))
    elif errors:
        print("COLMAP source verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
    else:
        print("COLMAP source verification passed")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
