#!/usr/bin/env python3
"""Contract checks for the generated A/B1 PLY comparison viewer."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import numpy as np
import pycolmap


VIEWER_ROOT = Path(__file__).resolve().parents[1]
EXPERIMENT_ROOT = VIEWER_ROOT.parent
EXPECTED = {
    "A": {
        "vertices": 20407,
        "points3D_sha256":
            "6ac680e8f84a9109eb21543de627b6f87568893b3d30b348af72291d2a900132",
        "ply": "data/A_raw_same_graph.ply",
        "model": "work/A_current_sidecar_01/model",
    },
    "B1": {
        "vertices": 20348,
        "points3D_sha256":
            "dc0a2c7d0a1e0877f0cba01833c833917a3bc3d1354e3fa6cef1bf4a7a50fea8",
        "ply": "data/B1_raw_aligned_to_A.ply",
        "model": "work/B1_contract_smoke_01/model",
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_file(path: Path) -> None:
    if not path.is_file() or path.stat().st_size == 0:
        raise AssertionError(f"missing generated artifact: {path}")


def parse_ascii_ply(
    path: Path,
) -> tuple[int, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    require_file(path)
    vertex_count = None
    header_lines = 0
    with path.open("r", encoding="ascii", newline="") as stream:
        if stream.readline().strip() != "ply":
            raise AssertionError(f"not a PLY file: {path}")
        header_lines += 1
        if stream.readline().strip() != "format ascii 1.0":
            raise AssertionError(f"PLY must be ASCII: {path}")
        header_lines += 1
        properties: list[str] = []
        for line in stream:
            header_lines += 1
            stripped = line.strip()
            if stripped.startswith("element vertex "):
                vertex_count = int(stripped.rsplit(" ", 1)[1])
            elif stripped.startswith("property "):
                properties.append(stripped)
            elif stripped == "end_header":
                break
        else:
            raise AssertionError(f"unterminated PLY header: {path}")

        required_properties = {
            "property double x",
            "property double y",
            "property double z",
            "property uchar red",
            "property uchar green",
            "property uchar blue",
            "property uint track_length",
            "property double reprojection_error",
        }
        if not required_properties.issubset(properties):
            raise AssertionError(f"missing PLY properties: {path}")
        xyz: list[list[float]] = []
        rgb: list[list[int]] = []
        track_lengths: list[int] = []
        errors: list[float] = []
        for line in stream:
            if not line.strip():
                continue
            values = line.split()
            if len(values) != 8:
                raise AssertionError(f"unexpected PLY row width: {path}")
            xyz.append([float(values[0]), float(values[1]), float(values[2])])
            rgb.append([int(values[3]), int(values[4]), int(values[5])])
            track_lengths.append(int(values[6]))
            errors.append(float(values[7]))

    if vertex_count is None:
        raise AssertionError(f"missing vertex count: {path}")
    return (
        vertex_count,
        np.asarray(xyz, dtype=np.float64),
        np.asarray(rgb, dtype=np.uint8),
        np.asarray(track_lengths, dtype=np.uint32),
        np.asarray(errors, dtype=np.float64),
    )


def reconstruction_arrays(model_path: Path) -> tuple[
    pycolmap.Reconstruction, np.ndarray, np.ndarray, np.ndarray
]:
    reconstruction = pycolmap.Reconstruction(str(model_path))
    points = [reconstruction.points3D[key] for key in sorted(reconstruction.points3D)]
    return (
        reconstruction,
        np.stack([point.xyz for point in points]),
        np.asarray([point.track.length() for point in points], dtype=np.uint32),
        np.asarray([point.error for point in points], dtype=np.float64),
    )


def main() -> None:
    manifest_path = VIEWER_ROOT / "viewer-manifest.json"
    html_path = VIEWER_ROOT / "index.html"
    require_file(manifest_path)
    require_file(html_path)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["schema"] == "pw_ab_true_color_ply_viewer_v2"
    assert manifest["filtering"] is False
    assert manifest["synthetic_colors"] is False
    assert manifest["ply_rgb"] == "capture_hevc_mean_over_track_observations"
    assert manifest["color_source"]["frame_count"] == 60
    assert manifest["color_source"]["resolution"] == [4032, 3024]
    assert manifest["color_source"]["hevc_sha256"] == (
        "d3254c0868fd09a772cd22477d14b431bb047a6dada7787f8c870bddd33c7512"
    )
    assert manifest["b1_transform"] == "camera_center_sim3_to_A"
    assert abs(manifest["sim3"]["scale"] - 0.167374037472674) < 1e-12

    parsed: dict[str, tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]] = {}
    reconstructions: dict[str, pycolmap.Reconstruction] = {}
    source_xyz: dict[str, np.ndarray] = {}
    for arm, expected in EXPECTED.items():
        ply_path = VIEWER_ROOT / expected["ply"]
        vertices, xyz, rgb, tracks, errors = parse_ascii_ply(ply_path)
        assert vertices == expected["vertices"], (arm, vertices)
        assert len(xyz) == expected["vertices"], (arm, len(xyz))
        recorded = manifest["arms"][arm]
        assert recorded["vertices"] == expected["vertices"]
        assert recorded["source_points3D_sha256"] == expected["points3D_sha256"]
        assert recorded["ply_sha256"] == sha256(ply_path)
        reconstruction, raw_xyz, raw_tracks, raw_errors = reconstruction_arrays(
            EXPERIMENT_ROOT / expected["model"]
        )
        reconstructions[arm] = reconstruction
        source_xyz[arm] = raw_xyz
        parsed[arm] = (xyz, rgb, tracks, errors)
        nonblack = int(np.count_nonzero(np.any(rgb != 0, axis=1)))
        assert nonblack / vertices >= 0.99, (arm, nonblack, vertices)
        assert len(np.unique(rgb, axis=0)) >= 100, arm
        assert recorded["true_color_nonblack_vertices"] == nonblack
        assert recorded["source_model_rgb_all_zero"] is True
        assert np.array_equal(tracks, raw_tracks)
        assert np.allclose(errors, raw_errors, rtol=0, atol=1e-15)

    assert np.allclose(parsed["A"][0], source_xyz["A"], rtol=0, atol=1e-15)
    sim3 = pycolmap.align_reconstructions_via_proj_centers(
        reconstructions["B1"], reconstructions["A"], 0.1
    )
    assert sim3 is not None
    matrix = np.asarray(sim3.matrix())
    expected_b1 = (
        matrix[:, :3] @ source_xyz["B1"].T
    ).T + matrix[:, 3]
    assert np.allclose(parsed["B1"][0], expected_b1, rtol=0, atol=1e-14)

    html = html_path.read_text(encoding="utf-8")
    for required in (
        "A · ARKit pose baseline",
        "B1 · pose input = 0",
        "A_raw_same_graph.ply",
        "B1_raw_aligned_to_A.ply",
        "plotly_relayout",
        "sync-camera",
        "point-size",
        "A is a baseline, not ground truth",
        "TRUE-COLOR PLY",
        "TRUE COLOR · CAPTURE RGB",
    ):
        assert required in html, required
    assert "heightColor" not in html
    assert "HEIGHT COLOR" not in html
    assert re.search(r"<script\\b[^>]*\\bsrc\\s*=", html, re.IGNORECASE) is None
    assert "<script type=\"module\"" not in html

    print("PASS viewer contract A=20407 B1=20348")


if __name__ == "__main__":
    main()
