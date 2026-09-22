#!/usr/bin/env python3
"""Audit and compile the structurally available dense Vulkan shaders.

This gate is intentionally fail-closed.  A successful invocation only means
that the currently present structural shaders compile and validate.  It never
means that the PatchMatch backend is runnable: a commercially permitted exact
replacement for CUDA XORWOW, plus sweep and texture parity, remain hard gates.
Reference-only shaders may compile for contract verification while remaining
explicitly non-runnable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


FROZEN_COMMIT = "a0d785fba74b2664f31edc4a29026a8b27c00f67"
TARGET_ENVIRONMENT = "vulkan1.1"

# These identities are copied from the frozen COLMAP 4.1.1 tree, rather than
# trusted from the mutable manifest being checked.
FROZEN_CUDA_REFERENCE_SHA256 = {
    "src/colmap/mvs/cuda_flip.h":
        "08148312195042696f923cb01182290c57e3174233d84c113dbc4d4cbd788cea",
    "src/colmap/mvs/cuda_rotate.h":
        "265e01e836da889530289f424f91a8cb92bd29978bde168724ab23889a39405a",
    "src/colmap/mvs/cuda_texture.h":
        "cc05fde8ddbb2543264a8a0ea4a0d8acfc7a22a2020fb61dde3622b577a477f5",
    "src/colmap/mvs/cuda_transpose.h":
        "1ebe5bbdea901e5f227042c77fdbdbc4a590a557008ea8201093d4cfbe503100",
    "src/colmap/mvs/gpu_mat.h":
        "c3ee6bef2b012cf1572b4789212aa52aba08bcfa3f312bb2d141ac98f240296b",
    "src/colmap/mvs/gpu_mat_prng.cu":
        "aac48adcc68e558b3634141d327a352895ea90d351c254bce3e7d289f5ffe15f",
    "src/colmap/mvs/gpu_mat_ref_image.cu":
        "01bf74693da801cce20411a447a673b7b2577f028590130264fa1659bc2d8142",
    "src/colmap/mvs/patch_match_cuda.cu":
        "1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448",
    "src/colmap/mvs/patch_match_cuda.h":
        "3d86f1c6c3dd49e54e6e65f2389c2c0937e7af376647bd351138248bcce4a555",
}

UNAVAILABLE_SHADERS = {
    "normal_ops/init_normal_unavailable.comp": {
        "compile": False,
        "blockers": ["cuda-xorwow-golden-required"],
    },
    "rng/init_xorwow_unavailable.comp": {
        "compile": True,
        "blockers": ["cuda-xorwow-golden-required", "do-not-dispatch-stub"],
    },
    "sweep/sweep_unavailable.comp": {
        "compile": True,
        "blockers": [
            "cuda-xorwow-golden-required",
            "patchmatch-sweep-parity-required",
            "do-not-dispatch-stub",
        ],
    },
    "sweep/sweep_full_unavailable.comp": {
        "compile": False,
        "blockers": [
            "cuda-xorwow-golden-required",
            "cuda-texture-parity-required",
            "do-not-dispatch-until-parity",
        ],
    },
}

REFERENCE_ONLY_SHADERS = {
    "rng/init_openmvs_pcg.comp": {
        "compile": True,
        "blockers": [
            "production-rng-dispatch-disabled",
            "openmvs-pcg-adaptation-parity-required",
            "agpl-reference-not-production-backend",
        ],
    },
    "depth_ops/init_depth_openmvs_pcg.comp": {
        "compile": True,
        "blockers": [
            "production-rng-dispatch-disabled",
            "openmvs-pcg-adaptation-parity-required",
            "agpl-reference-not-production-backend",
        ],
    },
    "normal_ops/init_normal_openmvs_pcg.comp": {
        "compile": True,
        "blockers": [
            "production-rng-dispatch-disabled",
            "openmvs-pcg-adaptation-parity-required",
            "agpl-reference-not-production-backend",
        ],
    },
    "sweep/sweep_full_openmvs_pcg.comp": {
        "compile": True,
        "blockers": [
            "production-rng-dispatch-disabled",
            "production-sweep-dispatch-disabled",
            "openmvs-pcg-adaptation-parity-required",
            "cuda-texture-parity-required",
            "agpl-reference-not-production-backend",
        ],
    },
}

SHADER_DEPENDENCIES = {
    "cost_ops/cost_ops_contract.comp": ["cost_ops/cost_ops.glsl"],
    "initial_cost/compute_initial_cost.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "src/colmap/mvs/cuda_texture.h",
    ],
    "mat_ops/flip_horizontal_f32.comp": ["src/colmap/mvs/cuda_flip.h"],
    "mat_ops/rotate_f32.comp": ["src/colmap/mvs/cuda_rotate.h"],
    "mat_ops/rotate_u32.comp": ["src/colmap/mvs/cuda_rotate.h"],
    "mat_ops/transpose_f32.comp": ["src/colmap/mvs/cuda_transpose.h"],
    "normal_ops/init_normal_unavailable.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "src/colmap/mvs/gpu_mat_prng.cu",
    ],
    "normal_ops/init_normal_openmvs_pcg.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "rng/colmap_xorwow.glsl",
        "rng/openmvs_pcg_initialization_layout.glsl",
    ],
    "normal_ops/rotate_normal_f32.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
    ],
    "ref_filter/filter_u8.comp": ["src/colmap/mvs/gpu_mat_ref_image.cu"],
    "rng/init_xorwow_unavailable.comp": ["src/colmap/mvs/gpu_mat_prng.cu"],
    "rng/init_openmvs_pcg.comp": [
        "src/colmap/mvs/gpu_mat_prng.cu",
        "rng/colmap_xorwow.glsl",
        "rng/openmvs_pcg_initialization_layout.glsl",
    ],
    "depth_ops/init_depth_openmvs_pcg.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "src/colmap/mvs/gpu_mat.h",
        "rng/colmap_xorwow.glsl",
        "rng/openmvs_pcg_initialization_layout.glsl",
    ],
    "sweep/sweep_unavailable.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "src/colmap/mvs/gpu_mat_prng.cu",
    ],
    "sweep/sweep_full_unavailable.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "src/colmap/mvs/gpu_mat_prng.cu",
        "cost_ops/cost_ops.glsl",
    ],
    "sweep/sweep_full_openmvs_pcg.comp": [
        "src/colmap/mvs/patch_match_cuda.cu",
        "cost_ops/cost_ops.glsl",
        "rng/colmap_xorwow.glsl",
    ],
}

LOCAL_SIZE_RE = re.compile(
    r"layout\s*\(\s*local_size_x\s*=\s*(\d+)\s*,\s*"
    r"local_size_y\s*=\s*(\d+)\s*,\s*"
    r"local_size_z\s*=\s*(\d+)\s*\)\s*in\s*;"
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def require_tool(name: str) -> str:
    executable = shutil.which(name)
    if executable is None:
        raise RuntimeError(f"required tool unavailable: {name}")
    return executable


def verify_frozen_upstream(dense_root: Path) -> dict:
    manifest_path = dense_root / "upstream_import" / "colmap_4_1_1_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("commit") != FROZEN_COMMIT:
        raise RuntimeError("frozen COLMAP commit mismatch")

    entries = manifest.get("scopes", {}).get("cuda_reference_only", [])
    actual = {entry.get("path"): entry.get("sha256") for entry in entries}
    if actual != FROZEN_CUDA_REFERENCE_SHA256:
        raise RuntimeError("frozen COLMAP CUDA reference hashes mismatch")

    vendored_root = dense_root / "third_party" / "colmap-4.1.1"
    for relative, expected in FROZEN_CUDA_REFERENCE_SHA256.items():
        source = vendored_root / relative
        if source.is_symlink() or not source.is_file():
            raise RuntimeError(f"missing or non-regular frozen source: {relative}")
        observed = sha256_file(source)
        if observed != expected:
            raise RuntimeError(
                f"vendored frozen source hash mismatch for {relative}: "
                f"expected {expected}, got {observed}"
            )
    return manifest


def rng_backend_dispatchable(dense_root: Path) -> bool:
    contract_path = dense_root / "rng" / "rng_contract.h"
    contract = contract_path.read_text(encoding="utf-8")
    match = re.search(
        r"constexpr\s+bool\s+CanDispatchRngBackend\s*\(\s*\)\s*"
        r"noexcept\s*\{\s*return\s+(true|false)\s*;\s*\}",
        contract,
    )
    if match is None:
        raise RuntimeError("unable to audit CanDispatchRngBackend()")
    return match.group(1) == "true"


def sweep_backend_dispatchable(dense_root: Path) -> bool:
    contract_path = dense_root / "sweep" / "sweep_contract.h"
    contract = contract_path.read_text(encoding="utf-8")
    match = re.search(
        r"constexpr\s+bool\s+CanDispatchSweepBackend\s*\(\s*\)\s*"
        r"noexcept\s*\{\s*return\s+(true|false)\s*;\s*\}",
        contract,
    )
    if match is None:
        raise RuntimeError("unable to audit CanDispatchSweepBackend()")
    return match.group(1) == "true"


def dependency_identity(dense_root: Path, relative: str) -> dict:
    if relative in FROZEN_CUDA_REFERENCE_SHA256:
        source = dense_root / "third_party" / "colmap-4.1.1" / relative
        kind = "frozen-colmap-source"
    else:
        source = dense_root / relative
        kind = "local-source"

    if source.is_symlink() or not source.is_file():
        raise RuntimeError(f"missing or non-regular shader dependency: {relative}")

    identity = {
        "path": relative,
        "sha256": sha256_file(source),
        "kind": kind,
    }
    if relative.endswith(".glsl"):
        identity["kind"] = "shader-include"
    elif relative == "rng/third_party/openmvs_pcg/LICENSE":
        identity["kind"] = "license"
        identity["license"] = "AGPL-3.0-or-later"
    elif relative.endswith("/provenance.json"):
        identity["kind"] = "provenance"
    return identity


def local_size(shader: Path) -> list[int]:
    match = LOCAL_SIZE_RE.search(shader.read_text(encoding="utf-8"))
    if match is None:
        raise RuntimeError(f"missing literal local size: {shader}")
    return [int(match.group(index)) for index in range(1, 4)]


def run_checked(command: list[str], label: str) -> None:
    result = subprocess.run(command, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        details = "\n".join(part for part in (result.stdout, result.stderr) if part)
        raise RuntimeError(f"{label} failed ({result.returncode})\n{details}")


def compile_shader(
    glslang: str,
    spirv_val: str,
    shader: Path,
    output_file: Path,
) -> None:
    output_file.parent.mkdir(parents=True, exist_ok=True)
    run_checked(
        [
            glslang,
            "-V",
            "--target-env",
            TARGET_ENVIRONMENT,
            "-S",
            "comp",
            f"-I{shader.parent}",
            "-o",
            str(output_file),
            str(shader),
        ],
        f"compile {shader}",
    )
    run_checked(
        [spirv_val, "--target-env", TARGET_ENVIRONMENT, str(output_file)],
        f"validate {output_file}",
    )


def build(output: Path) -> dict:
    dense_root = Path(__file__).resolve().parents[1]
    output = output.resolve()
    if is_within(output, dense_root):
        raise RuntimeError("output directory must be outside vendor/official_dense")
    if output.exists() and any(output.iterdir()):
        raise RuntimeError("output directory must be empty")
    output.mkdir(parents=True, exist_ok=True)

    glslang = require_tool("glslangValidator")
    spirv_val = require_tool("spirv-val")
    verify_frozen_upstream(dense_root)
    dispatchable = rng_backend_dispatchable(dense_root)
    sweep_dispatchable = sweep_backend_dispatchable(dense_root)

    shader_records = []
    shaders = sorted(dense_root.glob("**/*.comp"))
    if not shaders:
        raise RuntimeError("no Vulkan compute shaders found")

    for shader in shaders:
        relative = shader.relative_to(dense_root).as_posix()
        unavailable = UNAVAILABLE_SHADERS.get(relative)
        reference_only = REFERENCE_ONLY_SHADERS.get(relative)
        policy = unavailable or reference_only
        should_compile = policy is None or policy["compile"]
        relative_spirv = f"spirv/{relative}.spv" if should_compile else None
        output_file = output / relative_spirv if relative_spirv else None
        if should_compile:
            assert output_file is not None
            compile_shader(glslang, spirv_val, shader, output_file)

        if unavailable is not None:
            classification = "unavailable-pending-licensed-xorwow-and-parity"
        elif reference_only is not None:
            classification = "reference-only-non-runnable"
        else:
            classification = "runnable-structural"

        dependencies = SHADER_DEPENDENCIES.get(relative, [])
        shader_records.append({
            "source_path": relative,
            "source_sha256": sha256_file(shader),
            "classification": classification,
            "runnable": classification == "runnable-structural",
            "compiled": should_compile,
            "spirv_path": relative_spirv,
            "spirv_sha256": sha256_file(output_file) if output_file else None,
            "target_environment": TARGET_ENVIRONMENT,
            "local_size": local_size(shader),
            "dependencies": dependencies,
            "dependency_identities": [
                dependency_identity(dense_root, dependency)
                for dependency in dependencies
            ],
            "blockers": policy["blockers"] if policy else [],
        })

    adapted_init_paths = {
        "rng/init_openmvs_pcg.comp",
        "depth_ops/init_depth_openmvs_pcg.comp",
        "normal_ops/init_normal_openmvs_pcg.comp",
    }
    adapted_init_records = [
        record for record in shader_records
        if record["source_path"] in adapted_init_paths
    ]
    if {record["source_path"] for record in adapted_init_records} != adapted_init_paths:
        raise RuntimeError("incomplete OpenMVS-PCG initialization chain")
    if not dispatchable and any(record["runnable"] for record in adapted_init_records):
        raise RuntimeError(
            "OpenMVS-PCG init chain cannot be runnable while RNG dispatch is disabled"
        )
    adapted_sweep_record = next(
        (
            record for record in shader_records
            if record["source_path"] == "sweep/sweep_full_openmvs_pcg.comp"
        ),
        None,
    )
    if adapted_sweep_record is None:
        raise RuntimeError("missing OpenMVS-PCG sweep adaptation")
    if (not dispatchable or not sweep_dispatchable) and adapted_sweep_record["runnable"]:
        raise RuntimeError(
            "OpenMVS-PCG sweep cannot be runnable while production dispatch is disabled"
        )

    manifest = {
        "schema_version": 1,
        "upstream": "https://github.com/colmap/colmap",
        "upstream_release": "4.1.1",
        "upstream_commit": FROZEN_COMMIT,
        "frozen_cuda_reference_sha256": FROZEN_CUDA_REFERENCE_SHA256,
        "target_environment": TARGET_ENVIRONMENT,
        "toolchain": {
            "glslangValidator": str(Path(glslang).resolve()),
            "spirv-val": str(Path(spirv_val).resolve()),
        },
        "backend_status": "unavailable-pending-licensed-xorwow-and-parity",
        "rng_backend_dispatchable": dispatchable,
        "sweep_backend_dispatchable": sweep_dispatchable,
        "overall_ready": False,
        "blockers": [
            "cuda-xorwow-golden-required",
            "commercially-permitted-xorwow-semantics-required",
            "openmvs-pcg-adaptation-parity-required",
            "patchmatch-sweep-parity-required",
        ],
        "shaders": shader_records,
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        manifest = build(args.output)
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"official dense build gate failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps({
        "manifest": str((args.output.resolve() / "manifest.json")),
        "overall_ready": manifest["overall_ready"],
        "backend_status": manifest["backend_status"],
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
