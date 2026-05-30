#!/usr/bin/env python3
"""Mac research executor for DA3-only vs DA3+MoGe pre-SAP uncertainty.

This is a research runner, not a production stage. It keeps DA3 as the geometry
spine and tests whether MoGe-2 depth/normal/mask improve uncertainty ranking on
patches before SAP/ISP exists.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CAPTURE_DIR = REPO_ROOT / "device_captures/analysis_cap_1779777762841797"
DEFAULT_DA3_DIR = REPO_ROOT / "device_captures/pulled_cap_1779777762841797_latest"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "device_captures/pre_sap_uncertainty_cap_1779777762841797"
DEFAULT_MOGE_ROOT = REPO_ROOT.parent / "third_party/MoGe"
DEFAULT_UTILS3D_ROOT = REPO_ROOT.parent / "third_party/utils3d_moge"


@dataclass(frozen=True)
class FrameRecord:
    frame_id: str
    frame_index: int
    image_path: Path
    depth_path: Path
    conf_path: Path
    extrinsics_path: Path
    intrinsics_path: Path
    width: int
    height: int
    window_id: str
    window_to_root: dict[str, Any]
    bundle: dict[str, Any]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture-dir", type=Path, default=DEFAULT_CAPTURE_DIR)
    parser.add_argument("--da3-dir", type=Path, default=DEFAULT_DA3_DIR)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--moge-root", type=Path, default=DEFAULT_MOGE_ROOT)
    parser.add_argument("--utils3d-root", type=Path, default=DEFAULT_UTILS3D_ROOT)
    parser.add_argument("--model", default="Ruicheng/moge-2-vitl-normal")
    parser.add_argument("--num-tokens", type=int, default=1800)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--max-frames", type=int, default=0)
    parser.add_argument("--patch-size", type=int, default=32)
    parser.add_argument("--stride", type=int, default=16)
    parser.add_argument("--skip-moge", action="store_true")
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    log_path = args.output_dir / "run_log.jsonl"
    started = time.time()
    write_jsonl(log_path, {"event": "start", "args": vars_for_json(args)})

    depth_index = read_json(args.da3_dir / "depth_index.json")
    bundle = read_json(args.capture_dir / "photo_bundle.json")
    records = build_frame_records(args.capture_dir, args.da3_dir, depth_index, bundle)
    if args.max_frames > 0:
        records = records[: args.max_frames]
    write_jsonl(log_path, {"event": "records_loaded", "frame_count": len(records)})

    spec = build_spec(args, records)
    write_json(args.output_dir / "pre_sap_uncertainty_spec.json", spec)

    if not args.skip_moge:
        run_moge_outputs(args, records, log_path)

    rows = build_patch_features(args, records, log_path)
    if not rows:
        raise RuntimeError("No patch features generated")
    patch_csv = args.output_dir / "patch_features.csv"
    write_patch_csv(patch_csv, rows)

    metrics = run_route_benchmark(rows)
    write_json(args.output_dir / "route_metrics.json", metrics)
    write_feature_sanity(args.output_dir, rows)

    report = build_report(args, records, rows, metrics, time.time() - started)
    write_json(args.output_dir / "pre_sap_uncertainty_report.json", report)
    write_summary(args.output_dir / "summary.md", report, metrics)
    write_jsonl(log_path, {"event": "done", "elapsed_s": round(time.time() - started, 3)})
    return 0


def vars_for_json(args: argparse.Namespace) -> dict[str, Any]:
    out = {}
    for key, value in vars(args).items():
        out[key] = str(value) if isinstance(value, Path) else value
    return out


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def write_jsonl(path: Path, value: dict[str, Any]) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=False, default=str) + "\n")


def build_frame_records(
    capture_dir: Path,
    da3_dir: Path,
    depth_index: dict[str, Any],
    bundle: dict[str, Any],
) -> list[FrameRecord]:
    bundle_by_id = {frame["id"]: frame for frame in bundle.get("frames", [])}
    records: list[FrameRecord] = []
    for frame in depth_index.get("frames", []):
        if frame.get("status") != "completed":
            continue
        frame_id = frame.get("frameID")
        bundle_frame = bundle_by_id.get(frame_id)
        if not bundle_frame:
            continue
        image_rel = frame.get("imageRelativePath") or f"photos_depth/{frame_id}.jpg"
        record = FrameRecord(
            frame_id=frame_id,
            frame_index=int(frame.get("frameIndex", len(records))),
            image_path=capture_dir / image_rel,
            depth_path=da3_dir / frame["relativeDepthPath"],
            conf_path=da3_dir / frame["confidencePath"],
            extrinsics_path=da3_dir / frame["predExtrinsicsPath"],
            intrinsics_path=da3_dir / frame["predIntrinsicsPath"],
            width=int(frame.get("depthWidth", depth_index.get("input_width", 742))),
            height=int(frame.get("depthHeight", depth_index.get("input_height", 476))),
            window_id=frame.get("windowID", ""),
            window_to_root=frame.get("windowToRootSim3") or identity_sim3(),
            bundle=bundle_frame,
        )
        if record.image_path.exists():
            records.append(record)
    records.sort(key=lambda r: r.frame_index)
    return records


def identity_sim3() -> dict[str, Any]:
    return {
        "scale": 1.0,
        "rotationRowMajor3x3": [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        "translation": [0.0, 0.0, 0.0],
    }


def build_spec(args: argparse.Namespace, records: list[FrameRecord]) -> dict[str, Any]:
    capture_id = capture_id_from_dir(args.capture_dir)
    return {
        "schema_version": "aether_pre_sap_uncertainty_benchmark_spec_v1",
        "benchmark_id": f"{capture_id}_real_proxy_moge2_da3_input_v1",
        "capture_id": capture_id,
        "mode": "real_capture_proxy",
        "frame_count": len(records),
        "da3_depth_index_path": str(args.da3_dir / "depth_index.json"),
        "moge_auxiliary_signal_spec": {
            "model_id": "moge_2",
            "model_variant": "vitl_normal",
            "model": args.model,
            "num_tokens": args.num_tokens,
            "input_source": "photos_depth DA3-aligned 742x476 images",
            "signals": ["depth", "normal", "valid_mask"],
            "depth_role": "shadow_residual_only",
            "normal_role": "surface_and_edge_uncertainty_signal",
            "valid_mask_role": "candidate_bad_patch_signal",
        },
        "routes": [
            {
                "id": "da3_only",
                "features": [
                    "da3_conf_median",
                    "da3_conf_p10",
                    "da3_conf_std",
                    "da3_depth_grad_mean",
                    "da3_depth_grad_p90",
                    "rgb_edge_mean",
                    "rgb_depth_edge_disagreement",
                    "capture_quality_score",
                ],
            },
            {
                "id": "da3_plus_moge",
                "features": [
                    "all_da3_only_features",
                    "moge_valid_ratio",
                    "da3_moge_log_residual_median",
                    "da3_moge_log_residual_p90",
                    "moge_normal_variation",
                    "da3_moge_normal_angle_mean",
                ],
            },
        ],
        "patch_policy": {
            "patch_size_px": args.patch_size,
            "stride_px": args.stride,
            "coordinate_space": "da3_input_resolution",
        },
        "proxy_label": {
            "source": "cross_view_da3_reprojection_abs_log_residual",
            "bad_patch_rule": "residual >= p75 over finite patches",
            "neighbors": "previous and next frame in DA3 frameIndex order",
        },
        "hard_rules": [
            "do_not_fuse_moge_depth_before_this_benchmark_passes",
            "da3_depth_pose_intrinsics_remain_primary_geometry_spine",
            "moge_outputs_are_shadow_signals_for_uncertainty_only",
        ],
    }


def run_moge_outputs(
    args: argparse.Namespace,
    records: list[FrameRecord],
    log_path: Path,
) -> None:
    sys.path.insert(0, str(args.moge_root))
    sys.path.insert(0, str(args.utils3d_root))
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    import torch
    from moge.model.v2 import MoGeModel

    if args.device == "auto":
        device_name = "mps" if torch.backends.mps.is_available() else "cpu"
    else:
        device_name = args.device
    device = torch.device(device_name)
    write_jsonl(log_path, {"event": "moge_load_start", "device": device_name, "model": args.model})
    model = MoGeModel.from_pretrained(args.model).to(device).eval()
    write_jsonl(log_path, {"event": "moge_load_done", "device": device_name})

    out_dir = args.output_dir / "moge_aux"
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest = {
        "schema_version": "aether_moge_aux_manifest_v1",
        "model": args.model,
        "num_tokens": args.num_tokens,
        "device": device_name,
        "input_source": "photos_depth",
        "frames": [],
    }
    for i, record in enumerate(records):
        out_path = out_dir / f"{record.frame_id}.npz"
        if out_path.exists():
            manifest["frames"].append({"frameID": record.frame_id, "path": str(out_path.relative_to(args.output_dir))})
            continue
        image = cv2.cvtColor(cv2.imread(str(record.image_path)), cv2.COLOR_BGR2RGB)
        image_tensor = torch.tensor(image / 255, dtype=torch.float32, device=device).permute(2, 0, 1)
        fov_x = fov_x_degrees(record)
        start = time.time()
        with torch.no_grad():
            output = model.infer(
                image_tensor,
                fov_x=fov_x,
                num_tokens=args.num_tokens,
                use_fp16=False,
            )
        depth = output["depth"].detach().cpu().numpy().astype(np.float32)
        mask = output["mask"].detach().cpu().numpy().astype(np.bool_)
        normal = output.get("normal")
        normal_np = (
            normal.detach().cpu().numpy().astype(np.float32)
            if normal is not None
            else np.zeros((*depth.shape, 3), dtype=np.float32)
        )
        np.savez_compressed(
            out_path,
            depth=depth,
            normal=normal_np.astype(np.float16),
            mask=mask,
            fov_x=np.float32(fov_x if fov_x is not None else np.nan),
            image_height=np.int32(image.shape[0]),
            image_width=np.int32(image.shape[1]),
        )
        elapsed = time.time() - start
        manifest["frames"].append(
            {
                "frameID": record.frame_id,
                "path": str(out_path.relative_to(args.output_dir)),
                "infer_s": round(elapsed, 4),
                "mask_ratio": round(float(mask.mean()), 6),
            }
        )
        write_jsonl(
            log_path,
            {
                "event": "moge_frame_done",
                "i": i + 1,
                "n": len(records),
                "frameID": record.frame_id,
                "infer_s": round(elapsed, 4),
            },
        )
    write_json(args.output_dir / "moge_aux_manifest.json", manifest)


def fov_x_degrees(record: FrameRecord) -> float | None:
    intr = record.bundle.get("intrinsics") or []
    image_width = record.bundle.get("imageWidth")
    if len(intr) < 1 or not image_width:
        return None
    fx = float(intr[0])
    if fx <= 1e-6:
        return None
    return float(math.degrees(2.0 * math.atan(float(image_width) / (2.0 * fx))))


def build_patch_features(
    args: argparse.Namespace,
    records: list[FrameRecord],
    log_path: Path,
) -> list[dict[str, Any]]:
    by_index = {record.frame_index: record for record in records}
    rows: list[dict[str, Any]] = []
    for i, record in enumerate(records):
        depth = read_f32_map(record.depth_path, record.height, record.width)
        conf = read_f32_map(record.conf_path, record.height, record.width)
        image = cv2.cvtColor(cv2.imread(str(record.image_path)), cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
        if image.shape != depth.shape:
            image = cv2.resize(image, (record.width, record.height), interpolation=cv2.INTER_AREA)
        moge = load_moge_npz(args.output_dir / "moge_aux" / f"{record.frame_id}.npz", depth.shape)
        moge_features = compute_moge_feature_maps(depth, record, moge)
        da3_features = compute_da3_feature_maps(depth, conf, image)
        proxy_error = proxy_residual_map(record, by_index, args.da3_dir, records)
        qscore = float((record.bundle.get("quality") or {}).get("score") or 0.0)
        for patch in iter_patch_slices(record.height, record.width, args.patch_size, args.stride):
            y0, y1, x0, x1, cy, cx = patch
            pe = proxy_error[cy, cx]
            if not np.isfinite(pe):
                continue
            row = {
                "frame_id": record.frame_id,
                "frame_index": record.frame_index,
                "window_id": record.window_id,
                "x": cx,
                "y": cy,
                "proxy_abs_log_reproj_error": float(pe),
                "da3_conf_median": finite_percentile(conf[y0:y1, x0:x1], 50),
                "da3_conf_p10": finite_percentile(conf[y0:y1, x0:x1], 10),
                "da3_conf_std": finite_std(conf[y0:y1, x0:x1]),
                "da3_depth_grad_mean": finite_mean(da3_features["depth_grad"][y0:y1, x0:x1]),
                "da3_depth_grad_p90": finite_percentile(da3_features["depth_grad"][y0:y1, x0:x1], 90),
                "rgb_edge_mean": finite_mean(da3_features["rgb_edge"][y0:y1, x0:x1]),
                "rgb_depth_edge_disagreement": finite_mean(da3_features["edge_disagreement"][y0:y1, x0:x1]),
                "capture_quality_score": qscore,
                "moge_valid_ratio": finite_mean(moge_features["valid"][y0:y1, x0:x1]),
                "da3_moge_log_residual_median": finite_percentile(moge_features["log_residual"][y0:y1, x0:x1], 50),
                "da3_moge_log_residual_p90": finite_percentile(moge_features["log_residual"][y0:y1, x0:x1], 90),
                "moge_normal_variation": finite_mean(moge_features["normal_variation"][y0:y1, x0:x1]),
                "da3_moge_normal_angle_mean": finite_mean(moge_features["normal_angle"][y0:y1, x0:x1]),
            }
            if all(np.isfinite(float(v)) for k, v in row.items() if k not in {"frame_id", "window_id"}):
                rows.append(row)
        write_jsonl(
            log_path,
            {"event": "patch_features_frame_done", "i": i + 1, "n": len(records), "frameID": record.frame_id, "rows": len(rows)},
        )
    return rows


def read_f32_map(path: Path, height: int, width: int) -> np.ndarray:
    arr = np.fromfile(path, dtype="<f4")
    expected = height * width
    if arr.size < expected:
        raise ValueError(f"{path} has {arr.size} floats, expected {expected}")
    return arr[:expected].reshape(height, width)


def read_f32_list(path: Path) -> np.ndarray:
    return np.fromfile(path, dtype="<f4")


def load_moge_npz(path: Path, target_shape: tuple[int, int]) -> dict[str, np.ndarray]:
    data = np.load(path)
    depth = data["depth"].astype(np.float32)
    mask = data["mask"].astype(np.float32)
    normal = data["normal"].astype(np.float32)
    h, w = target_shape
    if depth.shape != target_shape:
        depth = cv2.resize(depth, (w, h), interpolation=cv2.INTER_LINEAR)
        mask = cv2.resize(mask, (w, h), interpolation=cv2.INTER_NEAREST)
        normal = cv2.resize(normal, (w, h), interpolation=cv2.INTER_LINEAR)
    norm = np.linalg.norm(normal, axis=2, keepdims=True)
    normal = normal / np.maximum(norm, 1e-6)
    return {"depth": depth, "mask": mask > 0.5, "normal": normal}


def compute_da3_feature_maps(depth: np.ndarray, conf: np.ndarray, image: np.ndarray) -> dict[str, np.ndarray]:
    log_depth = np.log(np.maximum(depth, 1e-6))
    dx = cv2.Sobel(log_depth, cv2.CV_32F, 1, 0, ksize=3)
    dy = cv2.Sobel(log_depth, cv2.CV_32F, 0, 1, ksize=3)
    depth_grad = np.sqrt(dx * dx + dy * dy)
    ix = cv2.Sobel(image, cv2.CV_32F, 1, 0, ksize=3)
    iy = cv2.Sobel(image, cv2.CV_32F, 0, 1, ksize=3)
    rgb_edge = np.sqrt(ix * ix + iy * iy)
    depth_norm = robust_01(depth_grad)
    rgb_norm = robust_01(rgb_edge)
    return {
        "depth_grad": depth_grad,
        "rgb_edge": rgb_edge,
        "edge_disagreement": np.abs(depth_norm - rgb_norm),
        "conf": conf,
    }


def compute_moge_feature_maps(
    depth: np.ndarray,
    record: FrameRecord,
    moge: dict[str, np.ndarray],
) -> dict[str, np.ndarray]:
    valid = moge["mask"] & np.isfinite(moge["depth"]) & (moge["depth"] > 1e-6) & np.isfinite(depth) & (depth > 1e-6)
    if valid.sum() > 32:
        scale = np.median(depth[valid] / np.maximum(moge["depth"][valid], 1e-6))
    else:
        scale = 1.0
    moge_depth_aligned = moge["depth"] * float(scale)
    log_residual = np.abs(np.log(np.maximum(depth, 1e-6)) - np.log(np.maximum(moge_depth_aligned, 1e-6)))
    da3_normal = da3_depth_normal(depth, record)
    dot = np.sum(da3_normal * moge["normal"], axis=2)
    dot = np.clip(dot, -1.0, 1.0)
    # Normal direction conventions can differ by a global sign. For uncertainty
    # we care about orientation mismatch, so use min(angle, 180-angle).
    normal_angle = np.degrees(np.arccos(np.abs(dot))).astype(np.float32)
    nx = cv2.Sobel(moge["normal"][:, :, 0], cv2.CV_32F, 1, 0, ksize=3)
    ny = cv2.Sobel(moge["normal"][:, :, 1], cv2.CV_32F, 0, 1, ksize=3)
    nz = cv2.Sobel(moge["normal"][:, :, 2], cv2.CV_32F, 1, 1, ksize=3)
    normal_variation = np.sqrt(nx * nx + ny * ny + nz * nz)
    log_residual[~valid] = np.nan
    normal_angle[~moge["mask"]] = np.nan
    return {
        "valid": valid.astype(np.float32),
        "log_residual": log_residual,
        "normal_angle": normal_angle,
        "normal_variation": normal_variation,
    }


def da3_depth_normal(depth: np.ndarray, record: FrameRecord) -> np.ndarray:
    intr = read_f32_list(record.intrinsics_path)
    fx = float(intr[0]) if intr.size > 0 and abs(float(intr[0])) > 1e-6 else 1.0
    fy = float(intr[4]) if intr.size > 4 and abs(float(intr[4])) > 1e-6 else fx
    dzdx = cv2.Sobel(depth, cv2.CV_32F, 1, 0, ksize=3) / fx
    dzdy = cv2.Sobel(depth, cv2.CV_32F, 0, 1, ksize=3) / fy
    normal = np.dstack([-dzdx, -dzdy, np.ones_like(depth, dtype=np.float32)])
    norm = np.linalg.norm(normal, axis=2, keepdims=True)
    return normal / np.maximum(norm, 1e-6)


def proxy_residual_map(
    source: FrameRecord,
    by_index: dict[int, FrameRecord],
    da3_dir: Path,
    all_records: list[FrameRecord],
) -> np.ndarray:
    candidates = []
    for delta in (-1, 1):
        target = by_index.get(source.frame_index + delta)
        if target is not None:
            candidates.append(target)
    if not candidates:
        return np.full((source.height, source.width), np.nan, dtype=np.float32)

    source_depth = read_f32_map(source.depth_path, source.height, source.width)
    source_pose = read_f32_list(source.extrinsics_path)
    source_intr = read_f32_list(source.intrinsics_path)
    source_sim3 = sim3_arrays(source.window_to_root)
    yy, xx = np.mgrid[0 : source.height, 0 : source.width]
    world = unproject_to_world(xx.astype(np.float32), yy.astype(np.float32), source_depth, source_intr, source_pose)
    root = apply_sim3(world, source_sim3)
    residuals = []
    for target in candidates:
        target_depth = read_f32_map(target.depth_path, target.height, target.width)
        target_pose = read_f32_list(target.extrinsics_path)
        target_intr = read_f32_list(target.intrinsics_path)
        target_sim3 = sim3_arrays(target.window_to_root)
        target_world = apply_inverse_sim3(root, target_sim3)
        cam = world_to_camera(target_world, target_pose)
        z = cam[:, :, 2]
        fx = target_intr[0] if target_intr.size > 0 and abs(target_intr[0]) > 1e-6 else 1.0
        fy = target_intr[4] if target_intr.size > 4 and abs(target_intr[4]) > 1e-6 else fx
        cx = target_intr[2] if target_intr.size > 2 else 0.0
        cy = target_intr[5] if target_intr.size > 5 else 0.0
        u = np.rint(fx * cam[:, :, 0] / np.maximum(z, 1e-6) + cx).astype(np.int32)
        v = np.rint(fy * cam[:, :, 1] / np.maximum(z, 1e-6) + cy).astype(np.int32)
        valid = (z > 1e-6) & (u >= 0) & (u < target.width) & (v >= 0) & (v < target.height)
        sampled = np.full_like(z, np.nan, dtype=np.float32)
        sampled[valid] = target_depth[v[valid], u[valid]]
        valid_sample = valid & np.isfinite(sampled) & (sampled > 1e-6)
        delta = np.log(np.maximum(z, 1e-6)) - np.log(np.maximum(sampled, 1e-6))
        if valid_sample.sum() > 32:
            # DA3 depth is still relative enough that a source-target pair can
            # carry a global log-scale bias. For uncertainty labels we care
            # about local inconsistency, so remove the pair median first.
            delta = delta - np.nanmedian(delta[valid_sample])
        res = np.abs(delta)
        res[~valid_sample] = np.nan
        residuals.append(res.astype(np.float32))
    return np.nanmin(np.stack(residuals, axis=0), axis=0).astype(np.float32)


def sim3_arrays(sim3: dict[str, Any]) -> tuple[float, np.ndarray, np.ndarray]:
    scale = float(sim3.get("scale", 1.0))
    rot = np.asarray(sim3.get("rotationRowMajor3x3", identity_sim3()["rotationRowMajor3x3"]), dtype=np.float32).reshape(3, 3)
    trans = np.asarray(sim3.get("translation", [0.0, 0.0, 0.0]), dtype=np.float32)
    return scale, rot, trans


def unproject_to_world(x: np.ndarray, y: np.ndarray, depth: np.ndarray, intr: np.ndarray, pose: np.ndarray) -> np.ndarray:
    fx = intr[0] if intr.size > 0 and abs(intr[0]) > 1e-6 else 1.0
    fy = intr[4] if intr.size > 4 and abs(intr[4]) > 1e-6 else fx
    cx = intr[2] if intr.size > 2 else 0.0
    cy = intr[5] if intr.size > 5 else 0.0
    px = (x - cx) / fx * depth
    py = (y - cy) / fy * depth
    cam = np.dstack([px, py, depth]).astype(np.float32)
    r = pose[:12].reshape(3, 4)[:, :3].astype(np.float32)
    t = pose[:12].reshape(3, 4)[:, 3].astype(np.float32)
    return (cam - t) @ r


def world_to_camera(world: np.ndarray, pose: np.ndarray) -> np.ndarray:
    p = pose[:12].reshape(3, 4).astype(np.float32)
    r = p[:, :3]
    t = p[:, 3]
    return world @ r.T + t


def apply_sim3(world: np.ndarray, sim3: tuple[float, np.ndarray, np.ndarray]) -> np.ndarray:
    scale, rot, trans = sim3
    return scale * (world @ rot.T) + trans


def apply_inverse_sim3(root: np.ndarray, sim3: tuple[float, np.ndarray, np.ndarray]) -> np.ndarray:
    scale, rot, trans = sim3
    return ((root - trans) / max(scale, 1e-9)) @ rot


def iter_patch_slices(height: int, width: int, patch_size: int, stride: int):
    half = patch_size // 2
    for cy in range(half, height - half + 1, stride):
        for cx in range(half, width - half + 1, stride):
            yield cy - half, cy + half, cx - half, cx + half, cy, cx


def finite_values(values: np.ndarray) -> np.ndarray:
    arr = np.asarray(values, dtype=np.float32).reshape(-1)
    return arr[np.isfinite(arr)]


def finite_mean(values: np.ndarray) -> float:
    arr = finite_values(values)
    return float(np.mean(arr)) if arr.size else float("nan")


def finite_std(values: np.ndarray) -> float:
    arr = finite_values(values)
    return float(np.std(arr)) if arr.size else float("nan")


def finite_percentile(values: np.ndarray, q: float) -> float:
    arr = finite_values(values)
    return float(np.percentile(arr, q)) if arr.size else float("nan")


def robust_01(values: np.ndarray) -> np.ndarray:
    arr = np.asarray(values, dtype=np.float32)
    finite = arr[np.isfinite(arr)]
    if finite.size == 0:
        return np.zeros_like(arr, dtype=np.float32)
    lo, hi = np.percentile(finite, [5, 95])
    return np.clip((arr - lo) / max(hi - lo, 1e-6), 0.0, 1.0)


def write_patch_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    fieldnames = list(rows[0].keys())
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


DA3_FEATURES = [
    "da3_conf_median",
    "da3_conf_p10",
    "da3_conf_std",
    "da3_depth_grad_mean",
    "da3_depth_grad_p90",
    "rgb_edge_mean",
    "rgb_depth_edge_disagreement",
    "capture_quality_score",
]
MOGE_FEATURES = [
    "moge_valid_ratio",
    "da3_moge_log_residual_median",
    "da3_moge_log_residual_p90",
    "moge_normal_variation",
    "da3_moge_normal_angle_mean",
]


def run_route_benchmark(rows: list[dict[str, Any]]) -> dict[str, Any]:
    errors = np.asarray([float(row["proxy_abs_log_reproj_error"]) for row in rows], dtype=np.float32)
    finite_errors = errors[np.isfinite(errors)]
    positive_errors = finite_errors[finite_errors > 1e-6]
    threshold_pool = positive_errors if positive_errors.size >= 100 else finite_errors
    bad_threshold = float(np.percentile(threshold_pool, 75))
    labels = (errors >= bad_threshold).astype(np.float32)
    test = np.asarray([int(row["frame_index"]) % 5 == 0 for row in rows], dtype=bool)
    train = ~test
    if test.sum() < 100 or train.sum() < 100:
        test = np.arange(len(rows)) % 5 == 0
        train = ~test
    routes = {
        "da3_only": DA3_FEATURES,
        "da3_plus_moge": DA3_FEATURES + MOGE_FEATURES,
    }
    route_reports = {}
    for route_id, feature_names in routes.items():
        x = np.asarray([[float(row[name]) for name in feature_names] for row in rows], dtype=np.float32)
        probs = fit_predict_logistic(x, labels, train, test)
        route_reports[route_id] = route_metrics(probs[test], labels[test], errors[test], bad_threshold)
        route_reports[route_id]["feature_count"] = len(feature_names)
    comparison = compare_routes(route_reports)
    disagreement = np.asarray([float(row["da3_moge_log_residual_median"]) for row in rows], dtype=np.float32)
    route_reports["da3_plus_moge"]["disagreement_proxy_error_corr_all"] = pearson(disagreement, errors)
    labeled_frame_ids = sorted({str(row["frame_id"]) for row in rows})
    train_frame_ids = sorted({str(rows[i]["frame_id"]) for i in np.where(train)[0]})
    test_frame_ids = sorted({str(rows[i]["frame_id"]) for i in np.where(test)[0]})
    return {
        "schema_version": "aether_pre_sap_route_metrics_v1",
        "proxy_bad_threshold_abs_log": bad_threshold,
        "row_count": len(rows),
        "labeled_frame_count": len(labeled_frame_ids),
        "train_frame_count": len(train_frame_ids),
        "test_frame_count": len(test_frame_ids),
        "bad_patch_count": int(labels.sum()),
        "bad_patch_ratio": float(labels.mean()),
        "train_count": int(train.sum()),
        "test_count": int(test.sum()),
        "normal_angle_convention": "sign_invariant_min_angle_0_to_90_degrees",
        "routes": route_reports,
        "comparison": comparison,
    }


def fit_predict_logistic(x: np.ndarray, y: np.ndarray, train: np.ndarray, test: np.ndarray) -> np.ndarray:
    x = np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0)
    mean = x[train].mean(axis=0)
    std = x[train].std(axis=0)
    std[std < 1e-6] = 1.0
    xs = (x - mean) / std
    xs = np.c_[np.ones(xs.shape[0], dtype=np.float32), xs]
    w = np.zeros(xs.shape[1], dtype=np.float32)
    lr = 0.05
    l2 = 0.001
    xt = xs[train]
    yt = y[train]
    for _ in range(450):
        z = np.clip(xt @ w, -30, 30)
        p = 1.0 / (1.0 + np.exp(-z))
        grad = (xt.T @ (p - yt)) / max(1, yt.size)
        grad[1:] += l2 * w[1:]
        w -= lr * grad.astype(np.float32)
    z = np.clip(xs @ w, -30, 30)
    return (1.0 / (1.0 + np.exp(-z))).astype(np.float32)


def route_metrics(probs: np.ndarray, labels: np.ndarray, errors: np.ndarray, bad_threshold: float) -> dict[str, Any]:
    order_trust = np.argsort(probs)
    keep_n = max(1, int(0.80 * len(order_trust)))
    kept = order_trust[:keep_n]
    return {
        "bad_patch_auroc": auroc(labels, probs),
        "bad_patch_auprc": auprc(labels, probs),
        "ece": ece(labels, probs),
        "brier": float(np.mean((probs - labels) ** 2)),
        "error_at_80pct_coverage": float(np.mean(errors[kept])),
        "reprojection_p90_at_80pct_coverage": float(np.percentile(errors[kept], 90)),
        "coverage_at_fixed_error": coverage_at_fixed_error(probs, errors, bad_threshold),
    }


def auroc(labels: np.ndarray, scores: np.ndarray) -> float:
    labels = labels.astype(bool)
    pos = scores[labels]
    neg = scores[~labels]
    if pos.size == 0 or neg.size == 0:
        return float("nan")
    ranks = np.argsort(np.argsort(np.r_[pos, neg])).astype(np.float64) + 1.0
    rank_pos = ranks[: pos.size].sum()
    auc = (rank_pos - pos.size * (pos.size + 1) / 2.0) / (pos.size * neg.size)
    return float(auc)


def auprc(labels: np.ndarray, scores: np.ndarray) -> float:
    order = np.argsort(-scores)
    y = labels[order].astype(np.float32)
    positives = y.sum()
    if positives <= 0:
        return float("nan")
    tp = np.cumsum(y)
    fp = np.cumsum(1.0 - y)
    precision = tp / np.maximum(tp + fp, 1e-9)
    recall = tp / positives
    recall_prev = np.r_[0.0, recall[:-1]]
    return float(np.sum((recall - recall_prev) * precision))


def ece(labels: np.ndarray, probs: np.ndarray, bins: int = 10) -> float:
    out = 0.0
    for lo in np.linspace(0.0, 1.0, bins, endpoint=False):
        hi = lo + 1.0 / bins
        m = (probs >= lo) & (probs < hi if hi < 1.0 else probs <= hi)
        if not m.any():
            continue
        out += float(m.mean()) * abs(float(probs[m].mean()) - float(labels[m].mean()))
    return out


def coverage_at_fixed_error(probs: np.ndarray, errors: np.ndarray, threshold: float) -> float:
    order = np.argsort(probs)
    ok = errors[order] < threshold
    prefix_ok = np.cumsum(ok)
    prefix_n = np.arange(1, ok.size + 1)
    precision = prefix_ok / prefix_n
    good_prefixes = np.where(precision >= 0.80)[0]
    if good_prefixes.size == 0:
        return 0.0
    return float((good_prefixes[-1] + 1) / ok.size)


def pearson(a: np.ndarray, b: np.ndarray) -> float:
    m = np.isfinite(a) & np.isfinite(b)
    if m.sum() < 3:
        return float("nan")
    aa = a[m] - a[m].mean()
    bb = b[m] - b[m].mean()
    return float(np.sum(aa * bb) / max(np.sqrt(np.sum(aa * aa) * np.sum(bb * bb)), 1e-9))


def write_feature_sanity(output_dir: Path, rows: list[dict[str, Any]]) -> None:
    feature_names = DA3_FEATURES + MOGE_FEATURES
    y = np.asarray([float(row["proxy_abs_log_reproj_error"]) for row in rows], dtype=np.float32)
    summary = []
    for name in feature_names:
        x = np.asarray([float(row[name]) for row in rows], dtype=np.float32)
        summary.append(
            {
                "feature": name,
                "mean": finite_mean(x),
                "p50": finite_percentile(x, 50),
                "p90": finite_percentile(x, 90),
                "corr_proxy_error": pearson(x, y),
            }
        )
    summary.sort(
        key=lambda item: abs(item["corr_proxy_error"])
        if math.isfinite(item["corr_proxy_error"])
        else -1.0,
        reverse=True,
    )
    write_json(
        output_dir / "feature_sanity.json",
        {
            "schema_version": "aether_pre_sap_feature_sanity_v1",
            "normal_angle_convention": "sign_invariant_min_angle_0_to_90_degrees",
            "features": summary,
        },
    )
    lines = [
        "# Feature Sanity Check",
        "",
        "| Feature | Mean | P50 | P90 | Corr(proxy error) |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for item in summary:
        corr = item["corr_proxy_error"]
        corr_text = f"{corr:.6f}" if math.isfinite(corr) else "nan"
        lines.append(
            f"| {item['feature']} | {item['mean']:.6f} | {item['p50']:.6f} | {item['p90']:.6f} | {corr_text} |"
        )
    (output_dir / "feature_sanity.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def compare_routes(route_reports: dict[str, dict[str, Any]]) -> dict[str, Any]:
    da3 = route_reports["da3_only"]
    moge = route_reports["da3_plus_moge"]
    directions = {
        "bad_patch_auroc": "higher",
        "bad_patch_auprc": "higher",
        "ece": "lower",
        "brier": "lower",
        "error_at_80pct_coverage": "lower",
        "reprojection_p90_at_80pct_coverage": "lower",
        "coverage_at_fixed_error": "higher",
    }
    deltas = {}
    wins = 0
    for key, direction in directions.items():
        delta = float(moge[key]) - float(da3[key])
        deltas[key] = delta
        if (direction == "higher" and delta > 0) or (direction == "lower" and delta < 0):
            wins += 1
    return {
        "primary": "da3_plus_moge_vs_da3_only",
        "metric_deltas": deltas,
        "wins": wins,
        "total": len(directions),
        "status": "moge_helped" if wins >= 4 else "moge_not_proven",
    }


def build_report(
    args: argparse.Namespace,
    records: list[FrameRecord],
    rows: list[dict[str, Any]],
    metrics: dict[str, Any],
    elapsed_s: float,
) -> dict[str, Any]:
    comparison_status = metrics["comparison"]["status"]
    capture_id = capture_id_from_dir(args.capture_dir)
    return {
        "schema_version": "aether_pre_sap_uncertainty_benchmark_report_v1",
        "status": "success",
        "capture_id": capture_id,
        "mode": "real_capture_proxy",
        "frame_count": len(records),
        "labeled_frame_count": metrics.get("labeled_frame_count"),
        "patch_count": len(rows),
        "bad_patch_count": metrics.get("bad_patch_count"),
        "bad_patch_ratio": metrics.get("bad_patch_ratio"),
        "elapsed_s": round(elapsed_s, 3),
        "spec_path": "pre_sap_uncertainty_spec.json",
        "route_metrics_path": "route_metrics.json",
        "patch_features_path": "patch_features.csv",
        "moge_aux_manifest_path": "moge_aux_manifest.json",
        "quality_gate": {
            "status": comparison_status,
            "meaning": "This is proxy evidence only; GT AUROC/AUPRC still needs HiRoom/DA3-BENCH/DTU.",
        },
        "comparison": metrics["comparison"],
        "routes": metrics["routes"],
        "limitations": [
            "Uses DA3-aligned photos_depth images for pixel-accurate comparison, not high-res originals.",
            "Uses cross-view DA3 reprojection residual as a proxy label; no GT depth is available in this real capture.",
            "Proxy labels are DA3-derived and can favor DA3-only features; treat this as production-direction evidence, not a GT verdict.",
            "Patch rows from the same frame are highly correlated; labeled_frame_count is the better sample-count sanity check.",
            "Does not fuse depth and does not modify SAP policy.",
        ],
    }


def capture_id_from_dir(capture_dir: Path) -> str:
    name = capture_dir.name
    if name.startswith("cap_"):
        return name
    if name.startswith("analysis_"):
        return name.removeprefix("analysis_")
    return name


def write_summary(path: Path, report: dict[str, Any], metrics: dict[str, Any]) -> None:
    routes = metrics["routes"]
    da3 = routes["da3_only"]
    moge = routes["da3_plus_moge"]
    lines = [
        "# Pre-SAP Uncertainty Benchmark",
        "",
        f"- Status: {report['status']}",
        f"- Capture: {report['capture_id']}",
        f"- Frames: {report['frame_count']}",
        f"- Labeled frames: {report.get('labeled_frame_count')}",
        f"- Patches: {report['patch_count']}",
        f"- Bad patch ratio: {float(report.get('bad_patch_ratio') or 0.0):.6f}",
        f"- Gate: {report['quality_gate']['status']}",
        "",
        "| Metric | DA3 only | DA3 + MoGe | Delta | Better |",
        "| --- | ---: | ---: | ---: | --- |",
    ]
    directions = {
        "bad_patch_auroc": "higher",
        "bad_patch_auprc": "higher",
        "ece": "lower",
        "brier": "lower",
        "error_at_80pct_coverage": "lower",
        "reprojection_p90_at_80pct_coverage": "lower",
        "coverage_at_fixed_error": "higher",
    }
    for key, direction in directions.items():
        delta = float(moge[key]) - float(da3[key])
        better = "MoGe" if (direction == "higher" and delta > 0) or (direction == "lower" and delta < 0) else "DA3"
        lines.append(
            f"| {key} | {float(da3[key]):.6f} | {float(moge[key]):.6f} | {delta:+.6f} | {better} |"
        )
    lines.extend(
        [
            "",
            f"- DA3-MoGe disagreement vs proxy error corr: {float(moge.get('disagreement_proxy_error_corr_all', float('nan'))):.6f}",
            "",
            "Notes:",
            "- This is a real-capture proxy benchmark, not GT.",
            "- MoGe is only evaluated as an uncertainty signal; DA3 remains the geometry spine.",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
