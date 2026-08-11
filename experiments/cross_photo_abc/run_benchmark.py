#!/usr/bin/env python3
"""Run exact-JPEG cross-photo arms A then B on one frozen host sample."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import resource
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Sequence

import cv2
import numpy as np
import yaml


EXPERIMENT_DIR = Path(__file__).resolve().parent
REPO_ROOT = EXPERIMENT_DIR.parents[1]
OLD_EXPERIMENT_DIR = REPO_ROOT / "experiments" / "cross_photo_lossless_potential"
sys.path.insert(0, str(OLD_EXPERIMENT_DIR))

from cross_photo_estimator import (  # noqa: E402
    ArchiveFrame,
    CoefficientComponent,
    JpegCoefficientData,
    load_registered_poses,
    parse_pwc,
    serialize_pwc,
)

from cross_photo_arms import (  # noqa: E402
    FlowGrid,
    build_faiss_parent_maps,
    decode_global_component,
    decode_local_component,
    decode_parent_deltas,
    dense_flow_grid,
    encode_global_component,
    encode_local_component,
    encode_parent_deltas,
    flow_parent_block_bases,
    pack_residual_planes,
    unpack_residual_planes,
)
from cross_photo_group_codec import (  # noqa: E402
    decode_protected_payload,
    encode_protected_payload,
)


@dataclass(frozen=True)
class Photo:
    index: int
    frame_id: str
    name: str
    bytes: int
    sha256: str
    jxl_bytes: int
    jxl_sha256: str
    jxl_path: Path
    jpeg_path: Path
    pwc_path: Path


def canonical_json(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def files_equal(first: Path, second: Path) -> bool:
    if first.stat().st_size != second.stat().st_size:
        return False
    with first.open("rb") as a, second.open("rb") as b:
        while True:
            left = a.read(1024 * 1024)
            right = b.read(1024 * 1024)
            if left != right:
                return False
            if not left:
                return True


def run_checked(command: Sequence[os.PathLike[str] | str], *, quiet: bool = True) -> None:
    subprocess.run(
        [os.fspath(value) for value in command],
        check=True,
        stdout=subprocess.DEVNULL if quiet else None,
        stderr=subprocess.PIPE if quiet else None,
    )


def build_tools(build: Path) -> tuple[Path, Path]:
    jpeg_tool = build / "jpeg_coeff_tool"
    zpaq_tool = build / "zpaq_file_tool"
    jpeg_flags = subprocess.check_output(
        ["pkg-config", "--cflags", "--libs", "libjpeg"], text=True
    ).split()
    run_checked(
        (
            "xcrun",
            "clang++",
            "-std=c++17",
            "-O3",
            "-Wall",
            "-Wextra",
            "-Werror",
            *jpeg_flags,
            OLD_EXPERIMENT_DIR / "jpeg_coeff_tool.cpp",
            "-o",
            jpeg_tool,
        )
    )
    zpaq_include = REPO_ROOT / "ios" / "Vendor" / "Zpaq" / "include"
    zpaq_source = REPO_ROOT / "ios" / "Vendor" / "Zpaq" / "src" / "libzpaq.cpp"
    zpaq_object = build / "libzpaq.o"
    tool_object = build / "zpaq_file_tool.o"
    common = ("-std=c++17", "-O2", "-Dunix", "-DNOJIT", f"-I{zpaq_include}")
    run_checked(
        (
            "xcrun",
            "clang++",
            *common,
            "-Wall",
            "-Wextra",
            "-Werror",
            "-Wno-unused-parameter",
            "-Wno-null-pointer-subtraction",
            "-c",
            REPO_ROOT / "tool" / "zpaq_file_tool.cpp",
            "-o",
            tool_object,
        )
    )
    run_checked(
        (
            "xcrun",
            "clang++",
            *common,
            "-c",
            zpaq_source,
            "-o",
            zpaq_object,
        )
    )
    run_checked(
        (
            "xcrun",
            "clang++",
            tool_object,
            zpaq_object,
            "-framework",
            "Security",
            "-o",
            zpaq_tool,
        )
    )
    version = subprocess.check_output((zpaq_tool, "version"), text=True).strip()
    expected = "7.15 e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418"
    if version != expected:
        raise RuntimeError(f"ZPAQ tool identity mismatch: {version}")
    return jpeg_tool, zpaq_tool


def load_manifest() -> dict[str, Any]:
    path = EXPERIMENT_DIR / "input-manifest.yaml"
    decoded = yaml.safe_load(path.read_text(encoding="utf-8"))
    if decoded["ordered_jpeg_count"] != 25 or decoded["ordered_jpeg_bytes"] != 107649656:
        raise RuntimeError("frozen input contract changed")
    if len(decoded["photos"]) != decoded["ordered_jpeg_count"]:
        raise RuntimeError("photo manifest count mismatch")
    return decoded


def verify_sidecars(manifest: dict[str, Any], root: Path) -> None:
    for name, expected_sha in manifest["sidecars"].items():
        path = root / name
        if not path.is_file() or sha256_file(path) != expected_sha:
            raise RuntimeError(f"sidecar identity mismatch: {path}")


def prepare_inputs(
    manifest: dict[str, Any],
    scratch: Path,
    jpeg_tool: Path,
) -> list[Photo]:
    root = Path(manifest["source_root"])
    verify_sidecars(manifest, root)
    jpeg_dir = scratch / "jpeg"
    pwc_dir = scratch / "pwc"
    jpeg_dir.mkdir()
    pwc_dir.mkdir()
    photos: list[Photo] = []
    started = time.perf_counter()
    for registered in manifest["photos"]:
        index = int(registered["index"])
        name = str(registered["name"])
        jxl_path = root / "photos_highres" / f"{name}.jxl"
        if (
            jxl_path.stat().st_size != int(registered["jxl_bytes"])
            or sha256_file(jxl_path) != registered["jxl_sha256"]
        ):
            raise RuntimeError(f"JXL member identity mismatch: {jxl_path}")
        jpeg_path = jpeg_dir / name
        run_checked(("djxl", jxl_path, jpeg_path, "--quiet"))
        if (
            jpeg_path.stat().st_size != int(registered["bytes"])
            or sha256_file(jpeg_path) != registered["sha256"]
        ):
            raise RuntimeError(f"exact JXL reconstruction failed: {name}")
        pwc_path = pwc_dir / f"{index:03d}.pwc"
        run_checked((jpeg_tool, "extract", jpeg_path, pwc_path))
        parsed = parse_pwc(pwc_path.read_bytes())
        roundtrip_pwc = pwc_dir / f"{index:03d}.roundtrip.pwc"
        roundtrip_jpeg = jpeg_dir / f"{index:03d}.roundtrip.jpg"
        roundtrip_pwc.write_bytes(serialize_pwc(parsed))
        run_checked((jpeg_tool, "restore", roundtrip_pwc, roundtrip_jpeg))
        if not files_equal(jpeg_path, roundtrip_jpeg):
            raise RuntimeError(f"coefficient container exactness failed: {name}")
        roundtrip_pwc.unlink()
        roundtrip_jpeg.unlink()
        photos.append(
            Photo(
                index=index,
                frame_id=str(registered["frame_id"]),
                name=name,
                bytes=int(registered["bytes"]),
                sha256=str(registered["sha256"]),
                jxl_bytes=int(registered["jxl_bytes"]),
                jxl_sha256=str(registered["jxl_sha256"]),
                jxl_path=jxl_path,
                jpeg_path=jpeg_path,
                pwc_path=pwc_path,
            )
        )
        print(
            f"PREPARED {index + 1}/{manifest['ordered_jpeg_count']} {name}",
            flush=True,
        )
    if sum(photo.bytes for photo in photos) != manifest["ordered_jpeg_bytes"]:
        raise RuntimeError("restored source total differs from frozen input")
    print(f"INPUT_READY elapsed_s={time.perf_counter() - started:.3f}", flush=True)
    return photos


def baseline_result(photos: Sequence[Photo]) -> dict[str, Any]:
    manifest = {
        "schema": "pw_cross_photo_jxl_baseline_v1",
        "codec": "jpeg-xl-exact-jpeg",
        "photos": [
            {
                "index": photo.index,
                "name": photo.name,
                "source_bytes": photo.bytes,
                "source_sha256": photo.sha256,
                "member_bytes": photo.jxl_bytes,
                "member_sha256": photo.jxl_sha256,
            }
            for photo in photos
        ],
    }
    manifest_bytes = len(canonical_json(manifest))
    member_bytes = sum(photo.jxl_bytes for photo in photos)
    complete = member_bytes + manifest_bytes
    return {
        "name": "jxl_exact_baseline",
        "source_jpeg_bytes": sum(photo.bytes for photo in photos),
        "archive_member_bytes": member_bytes,
        "manifest_bytes": manifest_bytes,
        "complete_archive_bytes": complete,
        "ratio": sum(photo.bytes for photo in photos) / complete,
        "exactness_failures": 0,
        "source_count": len(photos),
    }


def load_frame(photo: Photo) -> ArchiveFrame:
    return ArchiveFrame(
        index=photo.index,
        name=photo.name,
        source_bytes=photo.bytes,
        source_sha256=photo.sha256,
        jpeg=parse_pwc(photo.pwc_path.read_bytes()),
    )


def choose_pose_parent(
    frames: Sequence[ArchiveFrame],
    poses: dict[int, np.ndarray],
    child_local_index: int,
) -> int:
    child = frames[child_local_index]
    if child.index not in poses:
        raise RuntimeError(f"SfM pose missing for frame {child.index}")

    def center(pose: np.ndarray) -> np.ndarray:
        return -pose[:3, :3].T @ pose[:3, 3]

    child_center = center(poses[child.index])
    candidates = []
    for local_index in range(child_local_index):
        candidate = frames[local_index]
        if candidate.index not in poses:
            raise RuntimeError(f"SfM pose missing for frame {candidate.index}")
        distance = float(np.linalg.norm(child_center - center(poses[candidate.index])))
        candidates.append((distance, local_index))
    return min(candidates)[1]


def component_metadata(jpeg: JpegCoefficientData) -> list[dict[str, int]]:
    return [
        {
            "width_blocks": component.width_blocks,
            "height_blocks": component.height_blocks,
            "block_count": len(component.coefficients),
        }
        for component in jpeg.components
    ]


def build_a_child(
    child: ArchiveFrame,
    parent: ArchiveFrame,
    *,
    child_photo: Photo,
    parent_photo: Photo,
    parent_local_index: int,
) -> bytes:
    target_gray = cv2.imread(os.fspath(child_photo.jpeg_path), cv2.IMREAD_GRAYSCALE)
    parent_gray = cv2.imread(os.fspath(parent_photo.jpeg_path), cv2.IMREAD_GRAYSCALE)
    if target_gray is None or parent_gray is None:
        raise RuntimeError("OpenCV failed to decode benchmark JPEG")
    flow = dense_flow_grid(target_gray, parent_gray, image_scale=0.25, spacing=64)
    sections: list[bytes] = []
    metadata = {
        "schema": "pw_cross_photo_arm_a_child_v1",
        "source_index": child.index,
        "parent_local_index": parent_local_index,
        "restart_interval": child.jpeg.restart_interval,
        "components": component_metadata(child.jpeg),
        "residual_layout": "coefficient-plane-byte-shuffle-u16-mod65536",
    }
    sections.extend((canonical_json(metadata), child.jpeg.header, flow.to_bytes()))
    for child_component, parent_component in zip(
        child.jpeg.components, parent.jpeg.components, strict=True
    ):
        base_x, base_y = flow_parent_block_bases(
            flow,
            target_width_blocks=child_component.width_blocks,
            target_height_blocks=child_component.height_blocks,
            parent_width_blocks=parent_component.width_blocks,
            parent_height_blocks=parent_component.height_blocks,
        )
        selectors, residual = encode_local_component(
            child_component.coefficients,
            parent_component.coefficients,
            base_x=base_x,
            base_y=base_y,
            parent_width_blocks=parent_component.width_blocks,
            parent_height_blocks=parent_component.height_blocks,
            radius=2,
        )
        sections.extend((selectors.tobytes(), pack_residual_planes(residual)))
    return encode_protected_payload("arm-a-child", tuple(sections))


def decode_a_child(payload: bytes, decoded: Sequence[ArchiveFrame]) -> ArchiveFrame:
    sections = decode_protected_payload(payload, expected_kind="arm-a-child")
    if len(sections) < 5 or (len(sections) - 3) % 2:
        raise ValueError("arm A child section count is invalid")
    metadata = json.loads(sections[0])
    if metadata.get("schema") != "pw_cross_photo_arm_a_child_v1":
        raise ValueError("arm A child schema mismatch")
    parent_local_index = int(metadata["parent_local_index"])
    if not 0 <= parent_local_index < len(decoded):
        raise ValueError("arm A parent is not an earlier group frame")
    parent = decoded[parent_local_index]
    flow = FlowGrid.from_bytes(sections[2])
    components: list[CoefficientComponent] = []
    descriptions = metadata["components"]
    if len(descriptions) != len(parent.jpeg.components):
        raise ValueError("arm A component count differs from parent")
    for component_index, (description, parent_component) in enumerate(
        zip(descriptions, parent.jpeg.components, strict=True)
    ):
        block_count = int(description["block_count"])
        selectors = np.frombuffer(sections[3 + component_index * 2], dtype=np.uint8)
        if len(selectors) != block_count:
            raise ValueError("arm A selector count mismatch")
        residual = unpack_residual_planes(
            sections[4 + component_index * 2], block_count=block_count
        )
        base_x, base_y = flow_parent_block_bases(
            flow,
            target_width_blocks=int(description["width_blocks"]),
            target_height_blocks=int(description["height_blocks"]),
            parent_width_blocks=parent_component.width_blocks,
            parent_height_blocks=parent_component.height_blocks,
        )
        restored = decode_local_component(
            selectors,
            residual,
            parent_component.coefficients,
            base_x=base_x,
            base_y=base_y,
            parent_width_blocks=parent_component.width_blocks,
            parent_height_blocks=parent_component.height_blocks,
            radius=2,
        )
        components.append(
            CoefficientComponent(
                width_blocks=int(description["width_blocks"]),
                height_blocks=int(description["height_blocks"]),
                coefficients=restored,
            )
        )
    source_index = int(metadata["source_index"])
    return ArchiveFrame(
        index=source_index,
        name="decoded",
        source_bytes=1,
        source_sha256="0" * 64,
        jpeg=JpegCoefficientData(
            restart_interval=int(metadata["restart_interval"]),
            header=sections[1],
            components=tuple(components),
        ),
    )


def build_b_children(frames: Sequence[ArchiveFrame]) -> tuple[bytes, ...]:
    component_count = len(frames[0].jpeg.components)
    if any(len(frame.jpeg.components) != component_count for frame in frames):
        raise RuntimeError("JPEG component count differs within Faiss group")
    maps_by_component = []
    for component_index in range(component_count):
        maps_by_component.append(
            build_faiss_parent_maps(
                tuple(
                    frame.jpeg.components[component_index].coefficients
                    for frame in frames
                ),
                seed=20260802,
                requested_nlist=2048,
                nprobe=32,
                max_training_vectors=131072,
            )
        )
    children: list[bytes] = []
    for local_index, child in enumerate(frames[1:], start=1):
        metadata = {
            "schema": "pw_cross_photo_arm_b_child_v1",
            "source_index": child.index,
            "restart_interval": child.jpeg.restart_interval,
            "components": component_metadata(child.jpeg),
            "parent_map": "backward-uvarint-within-component",
            "residual_layout": "coefficient-plane-byte-shuffle-u16-mod65536",
        }
        sections: list[bytes] = [canonical_json(metadata), child.jpeg.header]
        for component_index, child_component in enumerate(child.jpeg.components):
            prior = [
                frame.jpeg.components[component_index].coefficients
                for frame in frames[:local_index]
            ]
            parent_pool = np.concatenate(prior, axis=0)
            parent_map = maps_by_component[component_index][local_index]
            residual = encode_global_component(
                child_component.coefficients, parent_pool, parent_map
            )
            sections.extend(
                (
                    encode_parent_deltas(parent_map, current_start=len(parent_pool)),
                    pack_residual_planes(residual),
                )
            )
        children.append(encode_protected_payload("arm-b-child", tuple(sections)))
    return tuple(children)


def decode_b_child(payload: bytes, decoded: Sequence[ArchiveFrame]) -> ArchiveFrame:
    sections = decode_protected_payload(payload, expected_kind="arm-b-child")
    if len(sections) < 4 or (len(sections) - 2) % 2:
        raise ValueError("arm B child section count is invalid")
    metadata = json.loads(sections[0])
    if metadata.get("schema") != "pw_cross_photo_arm_b_child_v1":
        raise ValueError("arm B child schema mismatch")
    descriptions = metadata["components"]
    if not decoded or len(descriptions) != len(decoded[0].jpeg.components):
        raise ValueError("arm B decoded parent component count mismatch")
    components: list[CoefficientComponent] = []
    for component_index, description in enumerate(descriptions):
        parent_pool = np.concatenate(
            [frame.jpeg.components[component_index].coefficients for frame in decoded],
            axis=0,
        )
        block_count = int(description["block_count"])
        parent_map = decode_parent_deltas(
            sections[2 + component_index * 2],
            current_start=len(parent_pool),
            count=block_count,
        )
        residual = unpack_residual_planes(
            sections[3 + component_index * 2], block_count=block_count
        )
        restored = decode_global_component(residual, parent_pool, parent_map)
        components.append(
            CoefficientComponent(
                width_blocks=int(description["width_blocks"]),
                height_blocks=int(description["height_blocks"]),
                coefficients=restored,
            )
        )
    return ArchiveFrame(
        index=int(metadata["source_index"]),
        name="decoded",
        source_bytes=1,
        source_sha256="0" * 64,
        jpeg=JpegCoefficientData(
            restart_interval=int(metadata["restart_interval"]),
            header=sections[1],
            components=tuple(components),
        ),
    )


def verify_restored(
    frame: ArchiveFrame,
    photo: Photo,
    *,
    jpeg_tool: Path,
    verify_dir: Path,
) -> None:
    pwc_path = verify_dir / f"{photo.index:03d}.pwc"
    jpeg_path = verify_dir / f"{photo.index:03d}.jpg"
    pwc_path.write_bytes(serialize_pwc(frame.jpeg))
    run_checked((jpeg_tool, "restore", pwc_path, jpeg_path))
    if (
        jpeg_path.stat().st_size != photo.bytes
        or sha256_file(jpeg_path) != photo.sha256
        or not files_equal(jpeg_path, photo.jpeg_path)
    ):
        raise RuntimeError(f"restored JPEG differs: {photo.name}")
    pwc_path.unlink()
    jpeg_path.unlink()


def corruption_rejected(zpaq_tool: Path, member: Path, work: Path, *, kind: str) -> bool:
    corrupted = work / "corrupted.zpaq"
    data = bytearray(member.read_bytes())
    data[len(data) // 2] ^= 0x80
    corrupted.write_bytes(data)
    output = work / "corrupted.raw"
    completed = subprocess.run(
        (zpaq_tool, "decompress", corrupted, output),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if completed.returncode != 0:
        corrupted.unlink()
        return True
    try:
        decode_protected_payload(output.read_bytes(), expected_kind=kind)
    except ValueError:
        corrupted.unlink()
        output.unlink(missing_ok=True)
        return True
    corrupted.unlink()
    output.unlink(missing_ok=True)
    return False


def run_arm(
    arm: str,
    photos: Sequence[Photo],
    *,
    poses: dict[int, np.ndarray],
    jpeg_tool: Path,
    zpaq_tool: Path,
    scratch: Path,
    baseline: dict[str, Any],
) -> dict[str, Any]:
    started = time.perf_counter()
    archive_dir = scratch / f"archive-{arm}"
    verify_dir = scratch / f"verify-{arm}"
    archive_dir.mkdir()
    verify_dir.mkdir()
    group_records: list[dict[str, Any]] = []
    first_member: Path | None = None
    for group_index, group_start in enumerate(range(0, len(photos), 8)):
        group_photos = list(photos[group_start : group_start + 8])
        frames = [load_frame(photo) for photo in group_photos]
        root_name = f"group-{group_index:02d}-root.jxl"
        root_path = archive_dir / root_name
        shutil.copyfile(group_photos[0].jxl_path, root_path)
        children: tuple[bytes, ...]
        if arm == "a":
            built: list[bytes] = []
            for child_local_index in range(1, len(frames)):
                parent_local_index = choose_pose_parent(
                    frames, poses, child_local_index
                )
                built.append(
                    build_a_child(
                        frames[child_local_index],
                        frames[parent_local_index],
                        child_photo=group_photos[child_local_index],
                        parent_photo=group_photos[parent_local_index],
                        parent_local_index=parent_local_index,
                    )
                )
                print(
                    f"ARM_A_PREDICTED group={group_index + 1}/4 "
                    f"child={child_local_index + 1}/{len(frames)}",
                    flush=True,
                )
            children = tuple(built)
        elif arm == "b":
            children = build_b_children(frames)
            print(
                f"ARM_B_INDEXED group={group_index + 1}/4 children={len(children)}",
                flush=True,
            )
        else:
            raise ValueError(f"unsupported arm: {arm}")

        member_name: str | None = None
        member_path: Path | None = None
        if children:
            raw = encode_protected_payload(f"arm-{arm}-group", children)
            raw_path = scratch / f"arm-{arm}-group-{group_index:02d}.raw"
            raw_path.write_bytes(raw)
            del raw
            member_name = f"group-{group_index:02d}-children.zpaq"
            member_path = archive_dir / member_name
            run_checked((zpaq_tool, "compress", raw_path, member_path), quiet=False)
            raw_path.unlink()
            if first_member is None:
                first_member = member_path

        # Decode from the persisted root/member rather than encoder memory.
        root_jpeg = verify_dir / f"group-{group_index:02d}-root.jpg"
        root_pwc = verify_dir / f"group-{group_index:02d}-root.pwc"
        run_checked(("djxl", root_path, root_jpeg, "--quiet"))
        if not files_equal(root_jpeg, group_photos[0].jpeg_path):
            raise RuntimeError("persisted group root failed exact reconstruction")
        run_checked((jpeg_tool, "extract", root_jpeg, root_pwc))
        decoded = [
            ArchiveFrame(
                index=group_photos[0].index,
                name=group_photos[0].name,
                source_bytes=group_photos[0].bytes,
                source_sha256=group_photos[0].sha256,
                jpeg=parse_pwc(root_pwc.read_bytes()),
            )
        ]
        root_jpeg.unlink()
        root_pwc.unlink()
        if member_path is not None:
            decoded_raw = verify_dir / f"group-{group_index:02d}.raw"
            run_checked((zpaq_tool, "decompress", member_path, decoded_raw), quiet=False)
            persisted_children = decode_protected_payload(
                decoded_raw.read_bytes(), expected_kind=f"arm-{arm}-group"
            )
            decoded_raw.unlink()
            if len(persisted_children) != len(group_photos) - 1:
                raise RuntimeError("persisted group child count mismatch")
            for child_local_index, child_payload in enumerate(
                persisted_children, start=1
            ):
                restored = (
                    decode_a_child(child_payload, decoded)
                    if arm == "a"
                    else decode_b_child(child_payload, decoded)
                )
                expected_photo = group_photos[child_local_index]
                if restored.index != expected_photo.index:
                    raise RuntimeError("decoded source index differs from manifest")
                verify_restored(
                    restored,
                    expected_photo,
                    jpeg_tool=jpeg_tool,
                    verify_dir=verify_dir,
                )
                decoded.append(restored)
                print(
                    f"ARM_{arm.upper()}_EXACT group={group_index + 1}/4 "
                    f"photo={child_local_index + 1}/{len(group_photos)}",
                    flush=True,
                )
        group_records.append(
            {
                "group_index": group_index,
                "source_indices": [photo.index for photo in group_photos],
                "root": {
                    "name": root_name,
                    "bytes": root_path.stat().st_size,
                    "sha256": sha256_file(root_path),
                },
                "children": None
                if member_path is None
                else {
                    "name": member_name,
                    "bytes": member_path.stat().st_size,
                    "sha256": sha256_file(member_path),
                },
            }
        )
        print(
            f"ARM_{arm.upper()}_GROUP_DONE {group_index + 1}/4 "
            f"elapsed_s={time.perf_counter() - started:.3f}",
            flush=True,
        )

    archive_manifest = {
        "schema": f"pw_cross_photo_arm_{arm}_archive_v1",
        "source_jpeg_bytes": sum(photo.bytes for photo in photos),
        "source": [
            {
                "index": photo.index,
                "name": photo.name,
                "bytes": photo.bytes,
                "sha256": photo.sha256,
            }
            for photo in photos
        ],
        "group_size": 8,
        "groups": group_records,
        "backend": "zpaq-7.15-method-5",
        "exact_residual": "uint16-modulo-65536",
        "encoder_only_model_bytes": 0,
    }
    manifest_path = archive_dir / "manifest.json"
    manifest_path.write_bytes(canonical_json(archive_manifest))
    files = [path for path in archive_dir.iterdir() if path.is_file()]
    complete_bytes = sum(path.stat().st_size for path in files)
    corruption_ok = first_member is not None and corruption_rejected(
        zpaq_tool,
        first_member,
        verify_dir,
        kind=f"arm-{arm}-group",
    )
    if not corruption_ok:
        raise RuntimeError(f"arm {arm} accepted a corrupt persisted member")
    source_bytes = sum(photo.bytes for photo in photos)
    elapsed = time.perf_counter() - started
    result = {
        "schema": "pw_cross_photo_abc_result_v1",
        "arm": arm,
        "source_jpeg_count": len(photos),
        "source_jpeg_bytes": source_bytes,
        "complete_archive_bytes": complete_bytes,
        "ratio": source_bytes / complete_bytes,
        "baseline_complete_archive_bytes": baseline["complete_archive_bytes"],
        "fraction_smaller_than_baseline": (
            baseline["complete_archive_bytes"] - complete_bytes
        )
        / baseline["complete_archive_bytes"],
        "exactness_failures": 0,
        "restored_lengths_equal": True,
        "restored_bytes_equal": True,
        "restored_sha256_equal": True,
        "random_read_max_decoded_jpegs": 8,
        "corruption_rejected": True,
        "all_persisted_bytes_counted": True,
        "encoder_only_model_bytes": 0,
        "elapsed_seconds": elapsed,
        "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "archive_manifest_sha256": sha256_file(manifest_path),
        "groups": group_records,
    }
    result_path = EXPERIMENT_DIR / "results" / f"arm-{arm}.json"
    result_path.parent.mkdir(exist_ok=True)
    temporary = result_path.with_suffix(".json.tmp")
    temporary.write_bytes(canonical_json(result))
    temporary.replace(result_path)
    print(
        f"ARM_{arm.upper()}_COMPLETE bytes={complete_bytes} "
        f"ratio={result['ratio']:.6f} elapsed_s={elapsed:.3f}",
        flush=True,
    )
    return result


def verify_sources_unchanged(photos: Sequence[Photo]) -> None:
    for photo in photos:
        if (
            photo.jxl_path.stat().st_size != photo.jxl_bytes
            or sha256_file(photo.jxl_path) != photo.jxl_sha256
        ):
            raise RuntimeError(f"source JXL changed during benchmark: {photo.name}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--arms",
        default="a,b",
        help="comma-separated ordered arms; supported: a,b",
    )
    parser.add_argument("--keep-scratch", action="store_true")
    arguments = parser.parse_args()
    arms = tuple(value.strip() for value in arguments.arms.split(",") if value.strip())
    if not arms or any(value not in ("a", "b") for value in arms):
        parser.error("--arms must contain only a and/or b")
    scratch = Path(tempfile.mkdtemp(prefix="pw-cross-photo-abc-", dir="/private/tmp"))
    failed = True
    try:
        print(f"SCRATCH {scratch}", flush=True)
        build = scratch / "build"
        build.mkdir()
        jpeg_tool, zpaq_tool = build_tools(build)
        manifest = load_manifest()
        photos = prepare_inputs(manifest, scratch, jpeg_tool)
        baseline = baseline_result(photos)
        baseline_path = EXPERIMENT_DIR / "results" / "baseline.json"
        baseline_path.parent.mkdir(exist_ok=True)
        baseline_path.write_bytes(canonical_json(baseline))
        print(
            f"BASELINE_COMPLETE bytes={baseline['complete_archive_bytes']} "
            f"ratio={baseline['ratio']:.6f}",
            flush=True,
        )
        poses = load_registered_poses(Path(manifest["source_root"]) / "official_sfm_sparse_meta.json")
        if any(photo.index not in poses for photo in photos):
            raise RuntimeError("not every frozen photo has a registered SfM pose")
        results = []
        for arm in arms:
            results.append(
                run_arm(
                    arm,
                    photos,
                    poses=poses,
                    jpeg_tool=jpeg_tool,
                    zpaq_tool=zpaq_tool,
                    scratch=scratch,
                    baseline=baseline,
                )
            )
        verify_sources_unchanged(photos)
        winner = min((baseline, *results), key=lambda value: value["complete_archive_bytes"])
        summary = {
            "schema": "pw_cross_photo_abc_summary_v1",
            "baseline": baseline,
            "arms": results,
            "winner": winner["arm"] if "arm" in winner else winner["name"],
            "winner_complete_archive_bytes": winner["complete_archive_bytes"],
        }
        summary_path = EXPERIMENT_DIR / "results" / "summary.json"
        summary_path.write_bytes(canonical_json(summary))
        print(
            f"ABC_HOST_WINNER {summary['winner']} "
            f"bytes={summary['winner_complete_archive_bytes']}",
            flush=True,
        )
        failed = False
        return 0
    finally:
        if arguments.keep_scratch or failed:
            print(f"SCRATCH_RETAINED {scratch}", flush=True)
        else:
            shutil.rmtree(scratch)
            print("SCRATCH_REMOVED", flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
