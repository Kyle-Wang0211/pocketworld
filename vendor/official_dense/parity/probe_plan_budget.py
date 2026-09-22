#!/usr/bin/env python3
"""Calculate exact static work for the frozen mobile COLMAP probe."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
from typing import Any

from compare_colmap_workspaces import read_frozen_scene_manifest
from contract import ContractError, fail


_ROW_TILE_HEIGHT = 8
_PARTITION_DISPATCHES_PER_SUBMIT = 256
_SWEEPS_PER_MODE = 20


def _partition_internal_submits(
    *, full_sweep: bool, height: int, group_count_x: int
) -> int:
    if height <= 0 or group_count_x <= 0:
        fail("probe budget dimensions must be positive")
    tile_count = (height + _ROW_TILE_HEIGHT - 1) // _ROW_TILE_HEIGHT
    physical_count = tile_count * group_count_x * (2 if full_sweep else 1)
    additional = (physical_count - 1) // _PARTITION_DISPATCHES_PER_SUBMIT
    return additional + (1 if full_sweep and physical_count >= 2 else 0)


def _split_phase_queue_submits(width: int, height: int) -> int:
    internal = _partition_internal_submits(
        full_sweep=False, height=height, group_count_x=(width + 31) // 32
    )
    for sweep in range(_SWEEPS_PER_MODE):
        quarter_turn = sweep % 2 == 1
        rotated_width = height if quarter_turn else width
        rotated_height = width if quarter_turn else height
        internal += _partition_internal_submits(
            full_sweep=True,
            height=rotated_height,
            group_count_x=(rotated_width + 31) // 32,
        )
    return internal + 2 + _SWEEPS_PER_MODE + 1


def calculate_probe_plan_budget(images: list[dict[str, Any]]) -> dict[str, Any]:
    """Return exact submit and float-map budgets for an ordered scene."""

    if not images:
        fail("probe budget requires at least one image")
    total_queue_submits = 0
    float_map_payload_bytes = 0
    phase_submit_counts: list[int] = []
    source_counts: list[int] = []
    dimensions: set[tuple[int, int]] = set()
    for expected_index, image in enumerate(images):
        try:
            image_index = int(image["index"])
            width = int(image["width"])
            height = int(image["height"])
            sources = image["source_indices"]
        except (KeyError, TypeError, ValueError):
            fail("invalid probe budget image record")
        if (
            image_index != expected_index
            or width <= 0
            or height <= 0
            or not isinstance(sources, list)
            or not sources
        ):
            fail("invalid ordered probe budget image record")
        phase_submits = _split_phase_queue_submits(width, height)
        phase_submit_counts.append(phase_submits)
        total_queue_submits += 2 * phase_submits
        # Four float maps: photo depth+normal and geometric depth+normal.
        float_map_payload_bytes += width * height * (1 + 3 + 1 + 3) * 4
        source_counts.append(len(sources))
        dimensions.add((width, height))
    uniform_phase_submits = (
        phase_submit_counts[0]
        if len(set(phase_submit_counts)) == 1
        else None
    )
    return {
        "schema_version": 1,
        "image_count": len(images),
        "dimensions": [list(value) for value in sorted(dimensions)],
        "source_count_min": min(source_counts),
        "source_count_max": max(source_counts),
        "queue_submits_per_split_phase": uniform_phase_submits,
        "full_scene_queue_submits": total_queue_submits,
        "float_map_payload_bytes": float_map_payload_bytes,
        "consistency_graph_bytes": "excluded_variable",
        "restart_unit": "one_reference_phase",
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Calculate exact static work for a frozen mobile probe."
    )
    parser.add_argument("--scene-packet", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        result = calculate_probe_plan_budget(
            read_frozen_scene_manifest(args.scene_packet)
        )
    except ContractError as error:
        print(f"FAIL-CLOSED: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
