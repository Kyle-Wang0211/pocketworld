#!/usr/bin/env python3
"""Verify that a machine may produce the official COLMAP CUDA baseline."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys
from typing import Any

from contract import (
    COLMAP_COMMIT,
    COLMAP_VERSION,
    DEFAULT_PARAMETERS_PATH,
    FORBIDDEN_SASS_ARCHES,
    PTX_ARCH,
    ContractError,
    fail,
    load_json,
    require_keys,
    require_tool,
    run_checked,
    sha256_file,
    validate_default_parameters,
    validate_input_manifest,
    write_json_atomic,
)


def _required_path(value: str | None, option: str, *, directory: bool = False) -> pathlib.Path:
    if not value:
        fail(f"missing required option {option}")
    path = pathlib.Path(value).expanduser().resolve()
    exists = path.is_dir() if directory else path.is_file()
    if not exists:
        fail(f"{option} does not exist: {path}")
    return path


def _tree_diff(source: pathlib.Path, git: str) -> tuple[str, bool]:
    diff = run_checked([git, "-C", str(source), "diff", "--binary", "HEAD"])
    untracked_output = run_checked(
        [git, "-C", str(source), "ls-files", "--others", "--exclude-standard"]
    )
    untracked = sorted(line for line in untracked_output.splitlines() if line)
    digest = hashlib.sha256()
    digest.update(diff.encode("utf-8"))
    digest.update(b"\0")
    for relative in untracked:
        candidate = source / relative
        if not candidate.is_file():
            fail(f"untracked COLMAP source entry is not a regular file: {relative}")
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(sha256_file(candidate).encode("ascii"))
        digest.update(b"\0")
    return digest.hexdigest(), bool(diff or untracked)


def collect_preflight(args: argparse.Namespace) -> dict[str, Any]:
    # Probe the complete CUDA toolchain first. There is no CPU or synthetic fallback.
    nvidia_smi = require_tool("nvidia-smi")
    nvcc = require_tool("nvcc")
    cuobjdump = require_tool("cuobjdump")
    git = require_tool("git")

    source = _required_path(args.colmap_source, "--colmap-source", directory=True)
    colmap_bin = _required_path(args.colmap_bin, "--colmap-bin")
    collector_bin = _required_path(args.collector_bin, "--collector-bin")
    input_manifest = _required_path(args.input_manifest, "--input-manifest")
    default_parameters = _required_path(
        args.default_parameters, "--default-parameters"
    )
    build_metadata_path = _required_path(args.build_metadata, "--build-metadata")
    if not args.input_manifest_sha256:
        fail("missing required option --input-manifest-sha256")
    if not args.collector_sha256:
        fail("missing required option --collector-sha256")
    if not args.expected_gpu_name:
        fail("missing required option --expected-gpu-name")

    head = run_checked([git, "-C", str(source), "rev-parse", "HEAD"]).strip()
    if head != COLMAP_COMMIT:
        fail(f"COLMAP commit mismatch: expected {COLMAP_COMMIT}, got {head}")

    build_metadata = load_json(build_metadata_path)
    require_keys(
        build_metadata,
        (
            "colmap_commit",
            "colmap_version",
            "cuda_codegen",
            "source_tree_diff_sha256",
        ),
        "build metadata",
    )
    if build_metadata["colmap_commit"] != COLMAP_COMMIT:
        fail("build metadata does not name the frozen COLMAP commit")
    if build_metadata["colmap_version"] != COLMAP_VERSION:
        fail("build metadata does not name COLMAP 4.1.1")
    diff_sha256, dirty = _tree_diff(source, git)
    if build_metadata["source_tree_diff_sha256"] != diff_sha256:
        fail("COLMAP source diff does not match the audited build metadata")
    if dirty and build_metadata.get("instrumentation_only") is not True:
        fail("modified COLMAP source is not declared instrumentation-only")

    cuda_codegen = build_metadata["cuda_codegen"]
    if not isinstance(cuda_codegen, dict):
        fail("build metadata cuda_codegen must be an object")
    require_keys(
        cuda_codegen,
        ("virtual_arch", "ptx_jit_required", "sass_arches", "nvcc_flags"),
        "build metadata cuda_codegen",
    )
    if cuda_codegen["virtual_arch"] != PTX_ARCH:
        fail(f"CUDA virtual architecture must be {PTX_ARCH}")
    if cuda_codegen["ptx_jit_required"] is not True:
        fail("Blackwell baseline must explicitly require PTX JIT")
    sass_arches = cuda_codegen["sass_arches"]
    if not isinstance(sass_arches, list) or any(
        not isinstance(value, str) for value in sass_arches
    ):
        fail("cuda_codegen.sass_arches must be a string list")
    forbidden_declared = sorted(set(sass_arches) & set(FORBIDDEN_SASS_ARCHES))
    if forbidden_declared:
        fail(f"forbidden Blackwell SASS declared: {forbidden_declared}")
    flags = cuda_codegen["nvcc_flags"]
    if not isinstance(flags, list) or any(not isinstance(value, str) for value in flags):
        fail("cuda_codegen.nvcc_flags must be a string list")
    joined_flags = " ".join(flags)
    if "arch=compute_90,code=compute_90" not in joined_flags:
        fail("nvcc flags must embed compute_90 PTX for Blackwell JIT")
    if any(arch in joined_flags for arch in FORBIDDEN_SASS_ARCHES):
        fail("nvcc flags request forbidden sm_100/sm_120 SASS")

    collector_sha256 = sha256_file(collector_bin)
    if collector_sha256 != args.collector_sha256.lower():
        fail(
            "collector SHA-256 mismatch: "
            f"expected {args.collector_sha256.lower()}, got {collector_sha256}"
        )

    input_payload = validate_input_manifest(
        input_manifest, args.input_manifest_sha256.lower()
    )
    parameters = validate_default_parameters(default_parameters)

    gpu_query = run_checked(
        [
            nvidia_smi,
            "--query-gpu=name,driver_version,compute_cap",
            "--format=csv,noheader",
        ]
    ).strip()
    gpu_rows = [row.strip() for row in gpu_query.splitlines() if row.strip()]
    matches = [
        row for row in gpu_rows if args.expected_gpu_name.lower() in row.lower()
    ]
    if len(matches) != 1:
        fail(
            "expected exactly one requested GPU; "
            f"needle={args.expected_gpu_name!r}, rows={gpu_rows}"
        )
    gpu_fields = [field.strip() for field in matches[0].split(",")]
    if len(gpu_fields) != 3:
        fail(f"unexpected nvidia-smi query result: {matches[0]}")

    nvcc_output = run_checked([nvcc, "--version"])
    release = re.search(r"release\s+([0-9]+(?:\.[0-9]+)*)", nvcc_output)
    if release is None:
        fail("cannot parse CUDA toolkit release from nvcc --version")

    colmap_help = run_checked([str(colmap_bin), "-h"])
    if re.search(rf"\bCOLMAP\s+{re.escape(COLMAP_VERSION)}\b", colmap_help) is None:
        fail("COLMAP executable does not report version 4.1.1")

    ptx_dump = run_checked([cuobjdump, "--dump-ptx", str(collector_bin)])
    if re.search(r"\.target\s+sm_90\b", ptx_dump) is None:
        fail("collector does not contain compute_90 PTX")
    if any(re.search(rf"\.target\s+{arch}\b", ptx_dump) for arch in FORBIDDEN_SASS_ARCHES):
        fail("collector PTX contains a forbidden Blackwell target")
    elf_listing = run_checked([cuobjdump, "--list-elf", str(collector_bin)])
    forbidden_embedded = [arch for arch in FORBIDDEN_SASS_ARCHES if arch in elf_listing]
    if forbidden_embedded:
        fail(f"collector contains forbidden Blackwell SASS: {forbidden_embedded}")

    return {
        "schema_version": 1,
        "colmap": {
            "version": COLMAP_VERSION,
            "commit": COLMAP_COMMIT,
            "binary": str(colmap_bin),
            "binary_sha256": sha256_file(colmap_bin),
            "source": str(source),
            "source_tree_diff_sha256": diff_sha256,
            "instrumentation_only": dirty,
        },
        "collector": {
            "path": str(collector_bin),
            "sha256": collector_sha256,
            "build_metadata_sha256": sha256_file(build_metadata_path),
        },
        "cuda": {
            "gpu_name": gpu_fields[0],
            "driver_version": gpu_fields[1],
            "compute_capability": gpu_fields[2],
            "toolkit_release": release.group(1),
            "ptx_arch": PTX_ARCH,
            "ptx_jit_required": True,
            "forbidden_sass_arches": list(FORBIDDEN_SASS_ARCHES),
            "nvcc_output": nvcc_output.strip(),
        },
        "input_manifest": {
            "path": str(input_manifest),
            "sha256": args.input_manifest_sha256.lower(),
            "file_count": len(input_payload["files"]),
        },
        "default_parameters": parameters,
        "default_parameters_sha256": sha256_file(DEFAULT_PARAMETERS_PATH),
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed preflight for the COLMAP 4.1.1 CUDA golden run."
    )
    parser.add_argument("--colmap-source")
    parser.add_argument("--colmap-bin")
    parser.add_argument("--collector-bin")
    parser.add_argument("--collector-sha256")
    parser.add_argument("--input-manifest")
    parser.add_argument("--input-manifest-sha256")
    parser.add_argument("--default-parameters")
    parser.add_argument("--build-metadata")
    parser.add_argument("--expected-gpu-name")
    parser.add_argument("--output-json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        payload = collect_preflight(args)
        if args.output_json:
            write_json_atomic(pathlib.Path(args.output_json), payload)
        else:
            import json

            print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    except ContractError as exc:
        print(f"FAIL-CLOSED: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
