#!/usr/bin/env python3
"""Compare every official COLMAP PatchMatch map for a frozen scene."""

from __future__ import annotations

import argparse
import array
import json
import math
import pathlib
import struct
import sys
from typing import Any, BinaryIO

from compare_colmap_maps import compare_float_matrix_files
from contract import ContractError, fail, sha256_file


_PACKET_MAGIC = b"PWSCENE1"
_PACKET_VERSION = 1
_MAX_IMAGES = 4096
_MAX_NAME_BYTES = 4096
_MAX_SOURCES = 1024


def _read_exact(stream: BinaryIO, size: int, label: str) -> bytes:
    payload = stream.read(size)
    if len(payload) != size:
        fail(f"truncated frozen scene {label}")
    return payload


def _read_u32(stream: BinaryIO, label: str) -> int:
    return struct.unpack("<I", _read_exact(stream, 4, label))[0]


def read_frozen_scene_manifest(packet: pathlib.Path) -> list[dict[str, Any]]:
    """Read the ordered image contract from the frozen portable scene packet."""

    packet = pathlib.Path(packet)
    try:
        stream = packet.open("rb")
    except OSError as error:
        fail(f"cannot open frozen scene packet: {error}")
    with stream:
        if _read_exact(stream, len(_PACKET_MAGIC), "magic") != _PACKET_MAGIC:
            fail("invalid frozen scene packet magic")
        version = _read_u32(stream, "version")
        image_count = _read_u32(stream, "image count")
        if (
            version != _PACKET_VERSION
            or image_count <= 0
            or image_count > _MAX_IMAGES
        ):
            fail("invalid frozen scene packet header")
        images: list[dict[str, Any]] = []
        names: set[str] = set()
        for expected_index in range(image_count):
            image_index, width, height, name_size, source_count = struct.unpack(
                "<IIIII", _read_exact(stream, 20, "image header")
            )
            if (
                image_index != expected_index
                or width <= 0
                or height <= 0
                or name_size <= 0
                or name_size > _MAX_NAME_BYTES
                or source_count <= 0
                or source_count > _MAX_SOURCES
            ):
                fail("invalid frozen scene image header")
            encoded_name = _read_exact(stream, name_size, "image name")
            try:
                image_name = encoded_name.decode("utf-8")
            except UnicodeDecodeError:
                fail("frozen scene image name is not UTF-8")
            if (
                image_name in ("", ".", "..")
                or "/" in image_name
                or "\\" in image_name
                or "\x00" in image_name
                or pathlib.PurePath(image_name).name != image_name
                or image_name in names
            ):
                fail("unsafe or duplicate frozen scene image name")
            _read_exact(stream, 21 * 4, "camera matrices")
            depth_range = struct.unpack(
                "<2f", _read_exact(stream, 2 * 4, "depth range")
            )
            source_payload = _read_exact(
                stream, source_count * 4, "source indices"
            )
            source_indices = struct.unpack(
                f"<{source_count}i", source_payload
            )
            if any(index < 0 or index >= image_count for index in source_indices):
                fail("invalid frozen scene source index")
            names.add(image_name)
            images.append(
                {
                    "index": image_index,
                    "name": image_name,
                    "width": width,
                    "height": height,
                    "depth_range": list(depth_range),
                    "source_indices": list(source_indices),
                }
            )
        if stream.read(1):
            fail("unexpected frozen scene packet trailing bytes")
    return images


def read_frozen_scene_image_names(packet: pathlib.Path) -> list[str]:
    """Read ordered image identities from the frozen portable scene packet."""

    return [image["name"] for image in read_frozen_scene_manifest(packet)]


def _read_dimension(stream: BinaryIO) -> int:
    digits = bytearray()
    while len(digits) <= 20:
        value = stream.read(1)
        if value == b"&":
            break
        if len(value) != 1 or value < b"0" or value > b"9":
            fail("invalid COLMAP consistency graph header")
        digits.extend(value)
    if not digits or len(digits) > 20:
        fail("invalid COLMAP consistency graph dimension")
    result = int(digits.decode("ascii"))
    if result <= 0:
        fail("COLMAP consistency graph dimensions must be positive")
    return result


def read_colmap_consistency_graph(path: pathlib.Path) -> dict[str, Any]:
    try:
        stream = path.open("rb")
    except OSError as error:
        fail(f"cannot open COLMAP consistency graph: {error}")
    with stream:
        width = _read_dimension(stream)
        height = _read_dimension(stream)
        depth = _read_dimension(stream)
        if depth != 1:
            fail("COLMAP consistency graph depth must equal one")
        payload = stream.read()
    if len(payload) % 4 != 0:
        fail("misaligned COLMAP consistency graph payload")
    values = array.array("i")
    if values.itemsize != 4:
        fail("host int32 representation is unsupported")
    values.frombytes(payload)
    if sys.byteorder != "little":
        values.byteswap()
    offset = 0
    record_count = 0
    while offset < len(values):
        if len(values) - offset < 3:
            fail("truncated COLMAP consistency graph record")
        col, row, image_count = values[offset : offset + 3]
        if (
            col < 0
            or col >= width
            or row < 0
            or row >= height
            or image_count < 0
            or image_count > len(values) - offset - 3
        ):
            fail("invalid COLMAP consistency graph record")
        offset += 3 + image_count
        record_count += 1
    return {
        "path": str(path.resolve()),
        "sha256": sha256_file(path),
        "shape": [width, height, depth],
        "values": values,
        "record_count": record_count,
    }


def _compare_consistency_graphs(
    reference: pathlib.Path, candidate: pathlib.Path
) -> dict[str, Any]:
    left = read_colmap_consistency_graph(reference)
    right = read_colmap_consistency_graph(candidate)
    if left["shape"] != right["shape"]:
        fail(
            "COLMAP consistency graph shapes differ: "
            f"{left['shape']} vs {right['shape']}"
        )
    left_values = left.pop("values")
    right_values = right.pop("values")
    common = min(len(left_values), len(right_values))
    mismatched_values = sum(
        left_values[index] != right_values[index] for index in range(common)
    ) + abs(len(left_values) - len(right_values))
    return {
        "reference": left["path"],
        "candidate": right["path"],
        "reference_sha256": left["sha256"],
        "candidate_sha256": right["sha256"],
        "shape": left["shape"],
        "reference_value_count": len(left_values),
        "candidate_value_count": len(right_values),
        "reference_record_count": left["record_count"],
        "candidate_record_count": right["record_count"],
        "mismatched_values": mismatched_values,
        "bitwise_identical": left["sha256"] == right["sha256"],
    }


def compare_colmap_workspaces(
    reference_workspace: pathlib.Path,
    candidate_workspace: pathlib.Path,
    image_names: list[str],
) -> dict[str, Any]:
    """Compare four float maps and one graph per explicitly ordered image."""

    reference_workspace = pathlib.Path(reference_workspace)
    candidate_workspace = pathlib.Path(candidate_workspace)
    if not image_names or len(set(image_names)) != len(image_names):
        fail("workspace comparison requires unique ordered image names")
    float_specs = (
        ("photometric_depth", "depth_maps", "photometric"),
        ("photometric_normal", "normal_maps", "photometric"),
        ("geometric_depth", "depth_maps", "geometric"),
        ("geometric_normal", "normal_maps", "geometric"),
    )
    float_maps: list[dict[str, Any]] = []
    graphs: list[dict[str, Any]] = []
    for image_name in image_names:
        if (
            image_name in ("", ".", "..")
            or pathlib.PurePath(image_name).name != image_name
        ):
            fail("unsafe workspace image name")
        for kind, directory, output_type in float_specs:
            suffix = f"{image_name}.{output_type}.bin"
            result = compare_float_matrix_files(
                reference_workspace / "stereo" / directory / suffix,
                candidate_workspace / "stereo" / directory / suffix,
            )
            result["image_name"] = image_name
            result["kind"] = kind
            float_maps.append(result)
        graph_suffix = f"{image_name}.geometric.bin"
        graph = _compare_consistency_graphs(
            reference_workspace
            / "stereo"
            / "consistency_graphs"
            / graph_suffix,
            candidate_workspace
            / "stereo"
            / "consistency_graphs"
            / graph_suffix,
        )
        graph["image_name"] = image_name
        graph["kind"] = "geometric_consistency_graph"
        graphs.append(graph)
    mismatched_float_values = sum(
        result["mismatched_values"] for result in float_maps
    )
    mismatched_consistency_values = sum(
        result["mismatched_values"] for result in graphs
    )
    float_value_count = sum(result["value_count"] for result in float_maps)
    consistency_value_count = sum(
        max(result["reference_value_count"], result["candidate_value_count"])
        for result in graphs
    )
    numerical_outputs_are_finite = all(
        result["max_abs"] is not None and result["rms"] is not None
        for result in float_maps
    )
    max_abs = None
    rms = None
    if numerical_outputs_are_finite:
        max_abs = max(result["max_abs"] for result in float_maps)
        squared_error = sum(
            result["rms"] * result["rms"] * result["value_count"]
            for result in float_maps
        )
        rms = math.sqrt(squared_error / float_value_count)
    bitwise_identical = all(
        result["bitwise_identical"] for result in (*float_maps, *graphs)
    )
    return {
        "schema_version": 1,
        "reference_workspace": str(reference_workspace.resolve()),
        "candidate_workspace": str(candidate_workspace.resolve()),
        "image_count": len(image_names),
        "float_map_count": len(float_maps),
        "consistency_graph_count": len(graphs),
        "bitwise_identical": bitwise_identical,
        "mismatched_float_values": mismatched_float_values,
        "float_value_count": float_value_count,
        "float_mismatch_fraction": mismatched_float_values / float_value_count,
        "max_abs": max_abs,
        "rms": rms,
        "mismatched_consistency_values": mismatched_consistency_values,
        "consistency_value_count": consistency_value_count,
        "consistency_mismatch_fraction": (
            mismatched_consistency_values / consistency_value_count
            if consistency_value_count != 0
            else 0.0
        ),
        "float_maps": float_maps,
        "consistency_graphs": graphs,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Measure all official COLMAP photometric/geometric depth, normal, "
            "and consistency outputs for every image in a frozen scene."
        )
    )
    parser.add_argument("--reference-workspace", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-workspace", type=pathlib.Path, required=True)
    parser.add_argument("--scene-packet", type=pathlib.Path, required=True)
    parser.add_argument("--require-bitwise-identical", action="store_true")
    args = parser.parse_args()
    try:
        image_names = read_frozen_scene_image_names(args.scene_packet)
        result = compare_colmap_workspaces(
            args.reference_workspace, args.candidate_workspace, image_names
        )
    except ContractError as error:
        print(f"FAIL-CLOSED: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, sort_keys=True, allow_nan=False))
    if args.require_bitwise_identical and not result["bitwise_identical"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
