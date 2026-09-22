#!/usr/bin/env python3
"""Inspect resumable progress of an official COLMAP dense workspace."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

from compare_colmap_maps import compare_float_matrix_files
from compare_colmap_workspaces import (
    read_colmap_consistency_graph,
    read_frozen_scene_image_names,
)
from contract import ContractError, fail


def _safe_image_names(image_names: list[str]) -> None:
    if not image_names or len(set(image_names)) != len(image_names):
        fail("workspace inspection requires unique ordered image names")
    for image_name in image_names:
        if (
            image_name in ("", ".", "..")
            or "/" in image_name
            or "\\" in image_name
            or "\x00" in image_name
            or pathlib.PurePath(image_name).name != image_name
        ):
            fail("unsafe workspace image name")


def _check_float_map(
    workspace: pathlib.Path,
    relative: pathlib.Path,
    expected_depth: int,
    missing: list[str],
    corrupt: list[dict[str, str]],
) -> list[int] | None:
    path = workspace / relative
    if not path.is_file():
        missing.append(relative.as_posix())
        return None
    try:
        result = compare_float_matrix_files(path, path)
    except ContractError as error:
        corrupt.append({"path": relative.as_posix(), "error": str(error)})
        return None
    shape = result["shape"]
    if shape[2] != expected_depth:
        corrupt.append(
            {
                "path": relative.as_posix(),
                "error": f"expected depth {expected_depth}, found {shape[2]}",
            }
        )
        return None
    return shape


def _check_graph(
    workspace: pathlib.Path,
    relative: pathlib.Path,
    missing: list[str],
    corrupt: list[dict[str, str]],
) -> list[int] | None:
    path = workspace / relative
    if not path.is_file():
        missing.append(relative.as_posix())
        return None
    try:
        return read_colmap_consistency_graph(path)["shape"]
    except ContractError as error:
        corrupt.append({"path": relative.as_posix(), "error": str(error)})
        return None


def inspect_colmap_workspace(
    workspace: pathlib.Path, image_names: list[str]
) -> dict[str, Any]:
    """Return exact phase completion without changing the workspace."""

    workspace = pathlib.Path(workspace)
    _safe_image_names(image_names)
    missing_outputs: list[str] = []
    corrupt_outputs: list[dict[str, str]] = []
    photometric_images: list[str] = []
    geometric_images: list[str] = []
    for image_name in image_names:
        photo_suffix = f"{image_name}.photometric.bin"
        photo_depth = _check_float_map(
            workspace,
            pathlib.Path("stereo/depth_maps") / photo_suffix,
            1,
            missing_outputs,
            corrupt_outputs,
        )
        photo_normal = _check_float_map(
            workspace,
            pathlib.Path("stereo/normal_maps") / photo_suffix,
            3,
            missing_outputs,
            corrupt_outputs,
        )
        if (
            photo_depth is not None
            and photo_normal is not None
            and photo_depth[:2] == photo_normal[:2]
        ):
            photometric_images.append(image_name)
        elif (
            photo_depth is not None
            and photo_normal is not None
            and photo_depth[:2] != photo_normal[:2]
        ):
            corrupt_outputs.append(
                {
                    "path": photo_suffix,
                    "error": "photometric depth/normal dimensions differ",
                }
            )

        geo_suffix = f"{image_name}.geometric.bin"
        geo_depth = _check_float_map(
            workspace,
            pathlib.Path("stereo/depth_maps") / geo_suffix,
            1,
            missing_outputs,
            corrupt_outputs,
        )
        geo_normal = _check_float_map(
            workspace,
            pathlib.Path("stereo/normal_maps") / geo_suffix,
            3,
            missing_outputs,
            corrupt_outputs,
        )
        geo_graph = _check_graph(
            workspace,
            pathlib.Path("stereo/consistency_graphs") / geo_suffix,
            missing_outputs,
            corrupt_outputs,
        )
        if (
            geo_depth is not None
            and geo_normal is not None
            and geo_graph is not None
            and geo_depth[:2] == geo_normal[:2] == geo_graph[:2]
        ):
            geometric_images.append(image_name)
        elif geo_depth is not None and geo_normal is not None and geo_graph is not None:
            corrupt_outputs.append(
                {
                    "path": geo_suffix,
                    "error": "geometric depth/normal/graph dimensions differ",
                }
            )

    photo_set = set(photometric_images)
    geo_set = set(geometric_images)
    next_photo = next((name for name in image_names if name not in photo_set), None)
    next_geo = next((name for name in image_names if name not in geo_set), None)
    return {
        "schema_version": 1,
        "workspace": str(workspace.resolve()),
        "image_count": len(image_names),
        "photometric_complete": len(photometric_images),
        "geometric_complete": len(geometric_images),
        "next_photometric_image": next_photo,
        "next_geometric_image": next_geo,
        "complete": (
            len(photometric_images) == len(image_names)
            and len(geometric_images) == len(image_names)
            and not corrupt_outputs
        ),
        "missing_outputs": missing_outputs,
        "corrupt_outputs": corrupt_outputs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect exact per-image progress of a COLMAP dense workspace."
    )
    parser.add_argument("--workspace", type=pathlib.Path, required=True)
    parser.add_argument("--scene-packet", type=pathlib.Path, required=True)
    parser.add_argument("--require-complete", action="store_true")
    args = parser.parse_args()
    try:
        result = inspect_colmap_workspace(
            args.workspace, read_frozen_scene_image_names(args.scene_packet)
        )
    except ContractError as error:
        print(f"FAIL-CLOSED: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    if result["corrupt_outputs"]:
        return 2
    if args.require_complete and not result["complete"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
