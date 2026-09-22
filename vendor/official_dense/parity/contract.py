#!/usr/bin/env python3
"""Fail-closed contract shared by the CUDA golden and Vulkan parity tools."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from typing import Any, Iterable


ROOT = pathlib.Path(__file__).resolve().parent
COLMAP_VERSION = "4.1.1"
COLMAP_COMMIT = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
PTX_ARCH = "compute_90"
FORBIDDEN_SASS_ARCHES = ("sm_100", "sm_120")
ARTIFACT_CONTRACT_PATH = ROOT / "artifact_contract.json"
DEFAULT_PARAMETERS_PATH = ROOT / "official_patch_match_defaults.json"


class ContractError(RuntimeError):
    pass


def fail(message: str) -> "None":
    raise ContractError(message)


def load_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read valid JSON {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"expected a JSON object in {path}")
    return value


def write_json_atomic(path: pathlib.Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp-{os.getpid()}")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as exc:
        fail(f"cannot hash {path}: {exc}")
    return digest.hexdigest()


def require_tool(name: str) -> str:
    resolved = shutil.which(name)
    if resolved is None:
        fail(f"required executable is unavailable: {name}")
    return resolved


def run_checked(command: list[str], *, cwd: pathlib.Path | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError as exc:
        fail(f"cannot execute {command[0]}: {exc}")
    if result.returncode != 0:
        fail(
            f"command failed ({result.returncode}): {' '.join(command)}\n"
            f"{result.stdout.strip()}"
        )
    return result.stdout


def validate_default_parameters(path: pathlib.Path) -> dict[str, Any]:
    expected = load_json(DEFAULT_PARAMETERS_PATH)
    actual = load_json(path)
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        extra = sorted(set(actual) - set(expected))
        changed = sorted(
            key for key in set(expected) & set(actual) if expected[key] != actual[key]
        )
        fail(
            "PatchMatch parameters differ from frozen COLMAP 4.1.1 defaults; "
            f"missing={missing}, extra={extra}, changed={changed}"
        )
    return actual


def validate_input_manifest(
    path: pathlib.Path, expected_sha256: str
) -> dict[str, Any]:
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256.lower():
        fail(
            "input manifest SHA-256 mismatch: "
            f"expected {expected_sha256.lower()}, got {actual_sha256}"
        )
    manifest = load_json(path)
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        fail("input manifest must contain a non-empty files list")
    manifest_dir = path.resolve().parent
    seen: set[str] = set()
    ordered_paths: list[str] = []
    for index, entry in enumerate(files):
        if not isinstance(entry, dict):
            fail(f"input manifest files[{index}] must be an object")
        rel = entry.get("path")
        digest = entry.get("sha256")
        size = entry.get("size_bytes")
        if not isinstance(rel, str) or not rel:
            fail(f"input manifest files[{index}].path is invalid")
        rel_path = pathlib.PurePosixPath(rel)
        if rel_path.is_absolute() or ".." in rel_path.parts:
            fail(f"input manifest path must stay relative: {rel}")
        if rel in seen:
            fail(f"duplicate input manifest path: {rel}")
        if not isinstance(digest, str) or len(digest) != 64:
            fail(f"input manifest SHA-256 is invalid for {rel}")
        if not isinstance(size, int) or size < 0:
            fail(f"input manifest size is invalid for {rel}")
        source = manifest_dir.joinpath(*rel_path.parts)
        if not source.is_file():
            fail(f"input manifest file is missing: {source}")
        if source.stat().st_size != size:
            fail(f"input file size mismatch: {rel}")
        if sha256_file(source) != digest.lower():
            fail(f"input file SHA-256 mismatch: {rel}")
        seen.add(rel)
        ordered_paths.append(rel)
    if ordered_paths != sorted(ordered_paths):
        fail("input manifest files must be sorted by path")
    return manifest


def validate_relative_artifact_path(value: Any) -> pathlib.PurePosixPath:
    if not isinstance(value, str) or not value:
        fail("artifact path must be a non-empty string")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts:
        fail(f"artifact path must stay relative: {value}")
    return path


def artifact_identity(entry: dict[str, Any]) -> tuple[Any, ...]:
    return (
        entry.get("kind"),
        entry.get("reference_id"),
        entry.get("iteration"),
        entry.get("sweep"),
    )


def validate_run_structure(run_dir: pathlib.Path) -> dict[str, Any]:
    contract = load_json(ARTIFACT_CONTRACT_PATH)
    manifest_path = run_dir / "artifact_manifest.json"
    manifest = load_json(manifest_path)
    if manifest.get("schema_version") != contract["schema_version"]:
        fail(f"artifact schema mismatch in {manifest_path}")
    references = manifest.get("reference_ids")
    if not isinstance(references, list) or not references:
        fail(f"reference_ids must be non-empty in {manifest_path}")
    if any(not isinstance(value, str) or not value for value in references):
        fail(f"reference_ids contains an invalid identifier in {manifest_path}")
    if len(set(references)) != len(references):
        fail(f"reference_ids contains duplicates in {manifest_path}")
    if references != sorted(references):
        fail(f"reference_ids must be sorted in {manifest_path}")
    if manifest.get("default_num_iterations") != contract["default_num_iterations"]:
        fail(f"num_iterations differs from the official default in {manifest_path}")
    if manifest.get("sweeps_per_iteration") != contract["sweeps_per_iteration"]:
        fail(f"sweep count differs from the official kernel in {manifest_path}")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        fail(f"artifacts must be a list in {manifest_path}")

    by_identity: dict[tuple[Any, ...], dict[str, Any]] = {}
    allowed_kinds = set(contract["per_reference_artifacts"]) | set(
        contract["global_artifacts"]
    )
    for index, entry in enumerate(artifacts):
        if not isinstance(entry, dict):
            fail(f"artifacts[{index}] must be an object in {manifest_path}")
        kind = entry.get("kind")
        if kind not in allowed_kinds:
            fail(f"unknown artifact kind {kind!r} in {manifest_path}")
        rel = validate_relative_artifact_path(entry.get("path"))
        dtype = entry.get("dtype")
        shape = entry.get("shape")
        digest = entry.get("sha256")
        size = entry.get("size_bytes")
        if not isinstance(dtype, str) or not dtype:
            fail(f"artifact dtype is missing for {rel}")
        if not isinstance(shape, list) or any(
            not isinstance(dim, int) or dim < 0 for dim in shape
        ):
            fail(f"artifact shape is invalid for {rel}")
        if not isinstance(digest, str) or len(digest) != 64:
            fail(f"artifact SHA-256 is invalid for {rel}")
        if not isinstance(size, int) or size < 0:
            fail(f"artifact size is invalid for {rel}")
        artifact_path = run_dir.joinpath(*rel.parts)
        if not artifact_path.is_file():
            fail(f"artifact is missing: {artifact_path}")
        if artifact_path.stat().st_size != size:
            fail(f"artifact size mismatch: {artifact_path}")
        if sha256_file(artifact_path) != digest.lower():
            fail(f"artifact SHA-256 mismatch: {artifact_path}")
        identity = artifact_identity(entry)
        if identity in by_identity:
            fail(f"duplicate artifact identity {identity} in {manifest_path}")
        by_identity[identity] = entry

    non_sweep = {"ref_filter", "initial_cost", "final_consistency_graph"}
    sweep_kinds = set(contract["per_sweep_artifacts"])
    for reference in references:
        for kind in non_sweep:
            identity = (kind, reference, None, None)
            if identity not in by_identity:
                fail(f"missing {identity} in {manifest_path}")
        for iteration in range(contract["default_num_iterations"]):
            for sweep in range(contract["sweeps_per_iteration"]):
                for kind in sweep_kinds:
                    identity = (kind, reference, iteration, sweep)
                    if identity not in by_identity:
                        fail(f"missing {identity} in {manifest_path}")
    for kind in contract["global_artifacts"]:
        identity = (kind, None, None, None)
        if identity not in by_identity:
            fail(f"missing global artifact {kind} in {manifest_path}")
    expected_count = len(references) * (
        len(non_sweep)
        + contract["default_num_iterations"]
        * contract["sweeps_per_iteration"]
        * len(sweep_kinds)
    ) + len(contract["global_artifacts"])
    if len(by_identity) != expected_count:
        fail(
            f"unexpected artifact count in {manifest_path}: "
            f"expected {expected_count}, got {len(by_identity)}"
        )
    return manifest


def same_structure(
    left: dict[str, Any], right: dict[str, Any]
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    if left.get("reference_ids") != right.get("reference_ids"):
        fail("reference_ids differ between parity runs")
    left_map = {artifact_identity(entry): entry for entry in left["artifacts"]}
    right_map = {artifact_identity(entry): entry for entry in right["artifacts"]}
    if set(left_map) != set(right_map):
        fail("artifact identities differ between parity runs")
    pairs: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for identity in sorted(left_map, key=str):
        lhs = left_map[identity]
        rhs = right_map[identity]
        for field in ("dtype", "shape", "size_bytes"):
            if lhs.get(field) != rhs.get(field):
                fail(f"artifact {identity} differs in structural field {field}")
        pairs.append((lhs, rhs))
    return pairs


def require_keys(value: dict[str, Any], keys: Iterable[str], label: str) -> None:
    missing = sorted(key for key in keys if key not in value)
    if missing:
        fail(f"{label} is missing keys: {missing}")
