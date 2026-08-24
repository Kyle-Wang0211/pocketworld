#!/usr/bin/env python3
"""Build the audited A/B1 raw-PLY comparison viewer."""

from __future__ import annotations

import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import pycolmap
from plotly.offline import get_plotlyjs


VIEWER_ROOT = Path(__file__).resolve().parent
EXPERIMENT_ROOT = VIEWER_ROOT.parent
DATA_ROOT = VIEWER_ROOT / "data"
CAPTURE_ROOT = Path(
    "/Users/kaidongwang/pw_device_backups/20260817_pre_install/Documents/"
    "captures_official/cap_1786546115077820"
)
HEVC_SOURCE = CAPTURE_ROOT / "photos_hevc/photos.hevc"
HEVC_MANIFEST = CAPTURE_ROOT / "photos_hevc/manifest.json"
HEVC_MASTER_MANIFEST = CAPTURE_ROOT / "photos_hevc/master-manifest.json"
PHOTO_BUNDLE = CAPTURE_ROOT / "official_photo_bundle.json"
FED_FRAMES = CAPTURE_ROOT / "official_sfm_fed_frames.jsonl"
FFMPEG = Path("/opt/homebrew/bin/ffmpeg")
FRAME_COUNT = 60
FRAME_WIDTH = 4032
FRAME_HEIGHT = 3024
FRAME_NAME = re.compile(r"^frame_(\d{6})\.jpg$")

COLOR_SOURCE_HASHES = {
    HEVC_SOURCE: "d3254c0868fd09a772cd22477d14b431bb047a6dada7787f8c870bddd33c7512",
    HEVC_MANIFEST: "50a97f12a34384b73383d2c75bc9bb9b4c7038a0fc14ed1ee33ed6a823e357e3",
    HEVC_MASTER_MANIFEST: "b68612fcab2d54fb8ae3f0d29ef5b5f0d86fd878c34e4afbe3d10f66df7b7fb0",
    PHOTO_BUNDLE: "e423ebcd601207607cb8abe4b4beee7f9c51b53e45e898b802d9681b0ac8cd5d",
    FED_FRAMES: "4769b6e0e8e3a27985c89d49e4c4e9988a08113a31bf563e65d398967f13432e",
}

ARMS = {
    "A": {
        "model": EXPERIMENT_ROOT / "work/A_current_sidecar_01/model",
        "registered": 59,
        "vertices": 20407,
        "ply_name": "A_raw_same_graph.ply",
        "hashes": {
            "cameras.bin": "8be3194a4cd0c3fbbf3cc1648e6cdc7bee357276215cb132ebbfda8f5e32b41d",
            "images.bin": "1f202254fa69641bd2b99b78e1a861ab5facdd7effad74563c9f79955889f8fd",
            "points3D.bin": "6ac680e8f84a9109eb21543de627b6f87568893b3d30b348af72291d2a900132",
        },
    },
    "B1": {
        "model": EXPERIMENT_ROOT / "work/B1_contract_smoke_01/model",
        "registered": 57,
        "vertices": 20348,
        "ply_name": "B1_raw_aligned_to_A.ply",
        "hashes": {
            "cameras.bin": "b84472bbba9736c25a2d42b953eb785db18ed1cb6e2fa04f68b58a3337caab8f",
            "images.bin": "1ae4aa9e368a1bb48a2bec611a3e4963f34bfcbf4e97cf8c3d60e9b3a769d4cd",
            "points3D.bin": "dc0a2c7d0a1e0877f0cba01833c833917a3bc3d1354e3fa6cef1bf4a7a50fea8",
        },
    },
}

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assert_source_hashes() -> None:
    for arm, spec in ARMS.items():
        for filename, expected in spec["hashes"].items():
            path = spec["model"] / filename
            actual = sha256(path)
            if actual != expected:
                raise RuntimeError(
                    f"{arm} source hash mismatch for {filename}: {actual}"
                )
    for path, expected in COLOR_SOURCE_HASHES.items():
        actual = sha256(path)
        if actual != expected:
            raise RuntimeError(f"color source hash mismatch for {path}: {actual}")


def assert_color_frame_mapping() -> list[str]:
    archive = json.loads(HEVC_MANIFEST.read_text(encoding="utf-8"))
    if archive.get("frame_count") != FRAME_COUNT:
        raise RuntimeError("HEVC manifest frame count mismatch")
    if archive.get("resolution") != f"{FRAME_WIDTH}x{FRAME_HEIGHT}":
        raise RuntimeError("HEVC manifest resolution mismatch")
    if archive.get("stream_sha256") != COLOR_SOURCE_HASHES[HEVC_SOURCE]:
        raise RuntimeError("HEVC manifest stream hash mismatch")

    master = json.loads(HEVC_MASTER_MANIFEST.read_text(encoding="utf-8"))
    master_by_index = {
        int(entry["frame"]): filename
        for filename, entry in master["entries"].items()
    }
    if sorted(master_by_index) != list(range(FRAME_COUNT)):
        raise RuntimeError("HEVC master-manifest frame indices mismatch")

    bundle = json.loads(PHOTO_BUNDLE.read_text(encoding="utf-8"))
    bundle_names = [frame["highresFilename"] for frame in bundle["frames"]]
    if len(bundle_names) != FRAME_COUNT:
        raise RuntimeError("photo bundle frame count mismatch")

    fed = [
        json.loads(line)
        for line in FED_FRAMES.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    if [int(row["frameId"]) for row in fed] != list(range(FRAME_COUNT)):
        raise RuntimeError("fed-frame IDs are not exactly 0..59")
    fed_names = [Path(row["jpegPath"]).name for row in fed]
    master_names = [master_by_index[index] for index in range(FRAME_COUNT)]
    if not (bundle_names == fed_names == master_names):
        raise RuntimeError("capture photo/HEVC/model frame order is ambiguous")
    return master_names


def assert_model_frame_names(reconstruction: pycolmap.Reconstruction, arm: str) -> None:
    for image in reconstruction.images.values():
        match = FRAME_NAME.fullmatch(image.name)
        if match is None or not 0 <= int(match.group(1)) < FRAME_COUNT:
            raise RuntimeError(f"{arm}: unexpected registered image name {image.name}")
        camera = reconstruction.cameras[image.camera_id]
        if (camera.width, camera.height) != (FRAME_WIDTH, FRAME_HEIGHT):
            raise RuntimeError(f"{arm}: image geometry mismatch for {image.name}")


def extract_true_colors(
    reconstructions: dict[str, pycolmap.Reconstruction],
) -> dict[str, np.ndarray]:
    if not FFMPEG.is_file():
        raise RuntimeError(f"ffmpeg not found at frozen path: {FFMPEG}")
    with tempfile.TemporaryDirectory(prefix="pw_ab_true_color_") as temp:
        temp_root = Path(temp)
        output_pattern = temp_root / "frame_%06d.jpg"
        command = [
            str(FFMPEG),
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(HEVC_SOURCE),
            "-map",
            "0:v:0",
            "-frames:v",
            str(FRAME_COUNT),
            "-fps_mode",
            "passthrough",
            "-start_number",
            "0",
            "-c:v",
            "png",
            "-f",
            "image2",
            str(output_pattern),
        ]
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=240,
        )
        if result.returncode != 0:
            raise RuntimeError(f"HEVC decode failed: {result.stderr.strip()}")
        decoded = sorted(temp_root.glob("frame_*.jpg"))
        expected_names = [f"frame_{index:06d}.jpg" for index in range(FRAME_COUNT)]
        if [path.name for path in decoded] != expected_names:
            raise RuntimeError("decoded HEVC frame set is not exactly frame_000000..59")
        png_signature = b"\x89PNG\r\n\x1a\n"
        if any(path.read_bytes()[:8] != png_signature for path in decoded):
            raise RuntimeError("lossless decoded frame is not PNG payload")

        for reconstruction in reconstructions.values():
            reconstruction.extract_colors_for_all_images(str(temp_root))

    colors: dict[str, np.ndarray] = {}
    for arm, reconstruction in reconstructions.items():
        points = [
            reconstruction.points3D[key]
            for key in sorted(reconstruction.points3D)
        ]
        rgb = np.stack([point.color for point in points]).astype(
            np.uint8, copy=False
        )
        nonblack = int(np.count_nonzero(np.any(rgb != 0, axis=1)))
        if nonblack / len(rgb) < 0.99:
            raise RuntimeError(
                f"{arm}: true-color coverage too low: {nonblack}/{len(rgb)}"
            )
        colors[arm] = rgb
    return colors


def reconstruction_arrays(
    model_path: Path,
) -> tuple[
    pycolmap.Reconstruction, np.ndarray, np.ndarray, np.ndarray, np.ndarray
]:
    reconstruction = pycolmap.Reconstruction(str(model_path))
    points = [reconstruction.points3D[key] for key in sorted(reconstruction.points3D)]
    xyz = np.stack([point.xyz for point in points])
    rgb = np.stack([point.color for point in points]).astype(np.uint8, copy=False)
    tracks = np.asarray([point.track.length() for point in points], dtype=np.uint32)
    errors = np.asarray([point.error for point in points], dtype=np.float64)
    return reconstruction, xyz, rgb, tracks, errors


def write_ascii_ply(
    path: Path,
    *,
    arm: str,
    xyz: np.ndarray,
    rgb: np.ndarray,
    tracks: np.ndarray,
    errors: np.ndarray,
    source_hash: str,
    transform_label: str,
) -> None:
    if not (len(xyz) == len(rgb) == len(tracks) == len(errors)):
        raise RuntimeError(f"{arm}: PLY column length mismatch")
    header = [
        "ply",
        "format ascii 1.0",
        f"comment arm {arm}",
        "comment source raw COLMAP points3D.bin",
        f"comment source_points3D_sha256 {source_hash}",
        "comment filtering false",
        "comment point_count_preserved true",
        "comment rgb capture_hevc_mean_over_track_observations",
        f"comment rgb_source_hevc_sha256 {COLOR_SOURCE_HASHES[HEVC_SOURCE]}",
        "comment rgb_decode lossless_png_payload_from_frozen_hevc",
        f"comment transform {transform_label}",
        f"element vertex {len(xyz)}",
        "property double x",
        "property double y",
        "property double z",
        "property uchar red",
        "property uchar green",
        "property uchar blue",
        "property uint track_length",
        "property double reprojection_error",
        "end_header",
    ]
    with path.open("w", encoding="ascii", newline="\n") as stream:
        stream.write("\n".join(header))
        stream.write("\n")
        for point, color, track, error in zip(
            xyz, rgb, tracks, errors, strict=True
        ):
            stream.write(
                f"{point[0]:.17g} {point[1]:.17g} {point[2]:.17g} "
                f"{int(color[0])} {int(color[1])} {int(color[2])} "
                f"{int(track)} {error:.17g}\n"
            )


def cube_ranges(points: np.ndarray) -> dict[str, list[float]]:
    minimum = points.min(axis=0)
    maximum = points.max(axis=0)
    center = (minimum + maximum) / 2.0
    span = float(np.max(maximum - minimum)) * 1.06
    return {
        axis: [float(center[index] - span / 2), float(center[index] + span / 2)]
        for index, axis in enumerate(("x", "y", "z"))
    }


def build_html(config: dict) -> str:
    plotly_js = get_plotlyjs()
    config_json = json.dumps(config, separators=(",", ":"), sort_keys=True)
    template = r'''<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>A / B1 · True-Color PLY Comparison</title>
  <link rel="icon" href="data:,">
  <script>__PLOTLY_JS__</script>
  <style>
    :root {
      color-scheme: dark;
      --carbon: #090e11;
      --field: #11191e;
      --line: #26343b;
      --line-strong: #3b4c54;
      --paper: #e8f0f2;
      --muted: #82959e;
      --a: #53d6e8;
      --b: #ffb454;
      --danger: #ff756b;
    }
    * { box-sizing: border-box; }
    html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; }
    body {
      background: var(--carbon);
      color: var(--paper);
      font-family: "Avenir Next", "Helvetica Neue", sans-serif;
      letter-spacing: 0.01em;
    }
    button, input { font: inherit; }
    .app {
      height: 100vh;
      display: grid;
      grid-template-rows: auto minmax(0, 1fr) auto;
      padding: 14px 16px 12px;
      gap: 10px;
    }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 18px;
      border-bottom: 1px solid var(--line);
      padding: 0 0 10px;
    }
    .identity { display: flex; align-items: baseline; gap: 14px; min-width: 0; }
    .identity h1 {
      margin: 0;
      font-family: "Avenir Next Condensed", "Arial Narrow", sans-serif;
      font-size: clamp(22px, 2.1vw, 34px);
      font-weight: 600;
      letter-spacing: 0.04em;
      line-height: 1;
      white-space: nowrap;
    }
    .identity .eyebrow,
    .utility,
    .metric-label,
    .arm-kicker,
    .status {
      font-family: "SFMono-Regular", Menlo, Consolas, monospace;
      text-transform: uppercase;
      letter-spacing: 0.09em;
    }
    .identity .eyebrow { color: var(--muted); font-size: 10px; white-space: nowrap; }
    .controls { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
    .control,
    .button {
      height: 32px;
      display: inline-flex;
      align-items: center;
      gap: 8px;
      border: 1px solid var(--line-strong);
      background: #0d1418;
      color: var(--paper);
      padding: 0 10px;
      font-family: "SFMono-Regular", Menlo, monospace;
      font-size: 10px;
      letter-spacing: 0.05em;
    }
    .button { cursor: pointer; }
    .button:hover { border-color: var(--paper); }
    .button:focus-visible, input:focus-visible { outline: 2px solid var(--a); outline-offset: 2px; }
    .control input[type="range"] { width: 88px; accent-color: var(--a); }
    .control input[type="checkbox"] { accent-color: var(--a); }
    .viewer {
      min-height: 0;
      position: relative;
      border: 1px solid var(--line-strong);
      background: var(--field);
      overflow: hidden;
    }
    .arm-rails {
      position: absolute;
      inset: 0 0 auto;
      z-index: 4;
      display: grid;
      grid-template-columns: 1fr 1fr;
      pointer-events: none;
      background: linear-gradient(180deg, rgba(9,14,17,.98), rgba(9,14,17,.72), transparent);
      padding: 10px 12px 28px;
    }
    .arm { display: flex; justify-content: space-between; align-items: baseline; gap: 12px; padding-right: 14px; }
    .arm + .arm { padding: 0 0 0 14px; }
    .arm-name { font-size: clamp(15px, 1.5vw, 21px); font-weight: 600; }
    .arm.a .arm-name, .arm.a .arm-kicker { color: var(--a); }
    .arm.b .arm-name, .arm.b .arm-kicker { color: var(--b); }
    .arm-kicker { font-size: 9px; }
    .arm-count { color: var(--muted); font-family: "SFMono-Regular", Menlo, monospace; font-size: 10px; }
    #plot { width: 100%; height: 100%; min-height: 440px; }
    .seam {
      position: absolute;
      z-index: 5;
      inset: 0 auto 0 50%;
      width: 1px;
      background: linear-gradient(180deg, transparent, #52666f 18%, #52666f 82%, transparent);
      pointer-events: none;
    }
    .seam-label {
      position: absolute;
      z-index: 6;
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%) rotate(-90deg);
      color: #71858d;
      background: var(--field);
      padding: 4px 10px;
      font: 8px/1 "SFMono-Regular", Menlo, monospace;
      letter-spacing: .18em;
      white-space: nowrap;
      pointer-events: none;
    }
    .loading {
      position: absolute;
      z-index: 10;
      inset: 0;
      display: grid;
      place-items: center;
      background: rgba(9,14,17,.88);
      color: var(--muted);
      font: 11px/1.7 "SFMono-Regular", Menlo, monospace;
      letter-spacing: .1em;
      text-align: center;
      transition: opacity .25s ease;
    }
    .loading.hidden { opacity: 0; pointer-events: none; }
    .loading.error { color: var(--danger); opacity: 1; }
    .footer {
      display: grid;
      grid-template-columns: repeat(5, minmax(0, 1fr)) auto;
      align-items: center;
      gap: 0;
      border-top: 1px solid var(--line);
      min-height: 48px;
    }
    .metric { padding: 8px 12px 5px 0; min-width: 0; }
    .metric + .metric { border-left: 1px solid var(--line); padding-left: 12px; }
    .metric-label { color: var(--muted); font-size: 8px; margin-bottom: 4px; }
    .metric-value { font-family: "SFMono-Regular", Menlo, monospace; font-size: 12px; white-space: nowrap; }
    .downloads { display: flex; gap: 8px; padding-left: 14px; }
    .downloads a { color: var(--muted); font: 9px/1 "SFMono-Regular", Menlo, monospace; text-decoration: none; border-bottom: 1px solid var(--line-strong); padding-bottom: 3px; }
    .downloads a:hover { color: var(--paper); border-color: var(--paper); }
    .status { position: absolute; right: 12px; bottom: 8px; z-index: 6; color: #697c84; font-size: 8px; pointer-events: none; }
    @media (max-width: 900px) {
      .identity .eyebrow { display: none; }
      .topbar { align-items: flex-start; }
      .footer { grid-template-columns: repeat(3, 1fr); }
      .downloads { grid-column: 1 / -1; padding: 7px 0 0; }
    }
    @media (prefers-reduced-motion: reduce) { .loading { transition: none; } }
  </style>
</head>
<body>
  <div class="app">
    <header class="topbar">
      <div class="identity">
        <h1>A // B1 · TRUE-COLOR PLY</h1>
        <div class="eyebrow">capture RGB · same graph · no denoise · camera-center Sim(3)</div>
      </div>
      <div class="controls" aria-label="查看器控制">
        <label class="control" for="sync-camera"><input id="sync-camera" type="checkbox" checked><span>同步视角</span></label>
        <label class="control" for="point-size"><span>点大小</span><input id="point-size" type="range" min="1" max="5" step="0.25" value="2"></label>
        <button class="button" id="reset-view" type="button">重置视角</button>
        <button class="button" id="fullscreen" type="button">全屏</button>
      </div>
    </header>

    <main class="viewer" id="viewer-shell">
      <div class="arm-rails">
        <div class="arm a">
          <div><div class="arm-kicker">POSE SIGNAL · ON</div><div class="arm-name">A · ARKit pose baseline</div></div>
          <div class="arm-count">59 / 60 frames · 20,407 pts</div>
        </div>
        <div class="arm b">
          <div><div class="arm-kicker">POSE SIGNAL · ZERO</div><div class="arm-name">B1 · pose input = 0</div></div>
          <div class="arm-count">57 / 60 frames · 20,348 pts</div>
        </div>
      </div>
      <div id="plot" role="img" aria-label="A 与 B1 两个真实 PLY 点云的并排交互比较"></div>
      <div class="seam"></div>
      <div class="seam-label">POSE ON // POSE OFF</div>
      <div class="loading" id="loading">READING THE TWO REAL PLY FILES…<br>正在加载 40,755 个未经去噪的点</div>
      <div class="status" id="status">TRUE COLOR · CAPTURE RGB · MEAN OVER TRACK OBSERVATIONS</div>
    </main>

    <footer class="footer">
      <div class="metric"><div class="metric-label">注册覆盖</div><div class="metric-value">98.33% → 95.00%</div></div>
      <div class="metric"><div class="metric-label">相机中心中位差</div><div class="metric-value">2.139 mm</div></div>
      <div class="metric"><div class="metric-label">旋转中位差</div><div class="metric-value">0.1372°</div></div>
      <div class="metric"><div class="metric-label">Sparse F1 @ 2.5 cm</div><div class="metric-value">98.94%</div></div>
      <div class="metric"><div class="metric-label">解释边界</div><div class="metric-value">A is a baseline, not ground truth</div></div>
      <div class="downloads">
        <a href="data/A_raw_same_graph.ply" download>下载 A PLY</a>
        <a href="data/B1_raw_aligned_to_A.ply" download>下载 B1 PLY</a>
      </div>
    </footer>
  </div>

  <script>
    "use strict";
    const BUILD = __CONFIG_JSON__;
    const loading = document.getElementById("loading");
    const plot = document.getElementById("plot");
    const syncCamera = document.getElementById("sync-camera");
    const pointSize = document.getElementById("point-size");
    const initialCamera = {
      eye: {x: 1.48, y: 1.48, z: 0.92},
      center: {x: 0, y: 0, z: 0},
      up: {x: 0, y: 1, z: 0},
      projection: {type: "perspective"}
    };

    function parsePly(text, label, expectedCount) {
      const lines = text.split(/\r?\n/);
      if (lines[0].trim() !== "ply" || lines[1].trim() !== "format ascii 1.0") {
        throw new Error(`${label}: 不是 ASCII PLY`);
      }
      let vertexCount = null;
      let headerEnd = -1;
      const properties = [];
      for (let i = 2; i < lines.length; i += 1) {
        const line = lines[i].trim();
        if (line.startsWith("element vertex ")) vertexCount = Number(line.split(/\s+/).at(-1));
        if (line.startsWith("property ")) properties.push(line.split(/\s+/).at(-1));
        if (line === "end_header") { headerEnd = i; break; }
      }
      if (headerEnd < 0 || vertexCount !== expectedCount) {
        throw new Error(`${label}: vertex count ${vertexCount}, expected ${expectedCount}`);
      }
      const index = Object.fromEntries(properties.map((name, i) => [name, i]));
      for (const name of ["x", "y", "z", "red", "green", "blue", "track_length", "reprojection_error"]) {
        if (!(name in index)) throw new Error(`${label}: 缺少 ${name}`);
      }
      const points = {x: [], y: [], z: [], sourceRgb: [], custom: []};
      for (let i = headerEnd + 1; i < lines.length && points.x.length < vertexCount; i += 1) {
        const row = lines[i].trim();
        if (!row) continue;
        const value = row.split(/\s+/);
        points.x.push(Number(value[index.x]));
        points.y.push(Number(value[index.y]));
        points.z.push(Number(value[index.z]));
        points.sourceRgb.push([
          Number(value[index.red]), Number(value[index.green]), Number(value[index.blue])
        ]);
        points.custom.push([Number(value[index.track_length]), Number(value[index.reprojection_error])]);
      }
      if (points.x.length !== vertexCount) throw new Error(`${label}: PLY 数据行不完整`);
      return points;
    }

    async function fetchPly(path, label, expectedCount) {
      const response = await fetch(path, {cache: "no-store"});
      if (!response.ok) throw new Error(`${label}: HTTP ${response.status}`);
      return parsePly(await response.text(), label, expectedCount);
    }

    function axis(title, range) {
      return {
        title: {text: title, font: {size: 9, color: "#71858d"}},
        range,
        showbackground: true,
        backgroundcolor: "#11191e",
        gridcolor: "#26343b",
        zerolinecolor: "#53666e",
        tickfont: {size: 8, color: "#61747c"},
        nticks: 6,
        showspikes: false
      };
    }

    function scene(domain) {
      return {
        domain,
        xaxis: axis("X / m", BUILD.ranges.x),
        yaxis: axis("Y / m", BUILD.ranges.y),
        zaxis: axis("Z / m", BUILD.ranges.z),
        aspectmode: "cube",
        camera: initialCamera,
        bgcolor: "#11191e",
        dragmode: "orbit"
      };
    }

    function trace(points, label, sceneName) {
      return {
        type: "scatter3d",
        mode: "markers",
        scene: sceneName,
        name: label,
        x: points.x,
        y: points.y,
        z: points.z,
        customdata: points.custom,
        marker: {
          size: Number(pointSize.value),
          color: points.sourceRgb.map(color =>
            `rgb(${color[0]},${color[1]},${color[2]})`
          ),
          opacity: 0.96,
          line: {width: 0}
        },
        hovertemplate: "x %{x:.3f} m<br>y %{y:.3f} m<br>z %{z:.3f} m<br>track %{customdata[0]}<br>reproj %{customdata[1]:.3f} px<extra>" + label + "</extra>"
      };
    }

    async function start() {
      const [a, b] = await Promise.all([
        fetchPly("data/A_raw_same_graph.ply", "A", 20407),
        fetchPly("data/B1_raw_aligned_to_A.ply", "B1", 20348)
      ]);
      const layout = {
        autosize: true,
        margin: {l: 0, r: 0, t: 0, b: 0},
        paper_bgcolor: "#11191e",
        plot_bgcolor: "#11191e",
        font: {family: "SFMono-Regular, Menlo, monospace", color: "#82959e"},
        showlegend: false,
        scene: scene({x: [0.0, 0.493], y: [0, 1]}),
        scene2: scene({x: [0.507, 1.0], y: [0, 1]}),
        hoverlabel: {bgcolor: "#090e11", bordercolor: "#52666f", font: {color: "#e8f0f2", size: 10}}
      };
      await Plotly.newPlot(
        plot,
        [trace(a, "A", "scene"), trace(b, "B1", "scene2")],
        layout,
        {responsive: true, displaylogo: false, scrollZoom: true, modeBarButtonsToRemove: ["sendDataToCloud"]}
      );
      loading.classList.add("hidden");

      let relaying = false;
      plot.on("plotly_relayout", event => {
        if (!syncCamera.checked || relaying) return;
        const updates = {};
        for (const [key, value] of Object.entries(event)) {
          if (key === "scene.camera" || key.startsWith("scene.camera.")) {
            updates[key.replace(/^scene\./, "scene2.")] = value;
          } else if (key === "scene2.camera" || key.startsWith("scene2.camera.")) {
            updates[key.replace(/^scene2\./, "scene.")] = value;
          }
        }
        if (!Object.keys(updates).length) return;
        relaying = true;
        Plotly.relayout(plot, updates).finally(() => { relaying = false; });
      });

      pointSize.addEventListener("input", () => {
        Plotly.restyle(plot, {"marker.size": Number(pointSize.value)}, [0, 1]);
      });
      document.getElementById("reset-view").addEventListener("click", () => {
        Plotly.relayout(plot, {"scene.camera": initialCamera, "scene2.camera": initialCamera});
      });
      document.getElementById("fullscreen").addEventListener("click", async () => {
        const shell = document.getElementById("viewer-shell");
        if (!document.fullscreenElement) await shell.requestFullscreen();
        else await document.exitFullscreen();
      });
      document.addEventListener("fullscreenchange", () => Plotly.Plots.resize(plot));
      window.addEventListener("resize", () => Plotly.Plots.resize(plot));
    }

    start().catch(error => {
      loading.classList.add("error");
      loading.textContent = `LOAD FAILED · ${error.message}`;
      console.error(error);
    });
  </script>
</body>
</html>
'''
    return template.replace("__PLOTLY_JS__", plotly_js).replace(
        "__CONFIG_JSON__", config_json
    )


def main() -> None:
    assert_source_hashes()
    archive_frame_names = assert_color_frame_mapping()
    DATA_ROOT.mkdir(parents=True, exist_ok=True)

    (
        a_reconstruction,
        a_xyz,
        a_source_rgb,
        a_tracks,
        a_errors,
    ) = reconstruction_arrays(ARMS["A"]["model"])
    (
        b_reconstruction,
        b_xyz,
        b_source_rgb,
        b_tracks,
        b_errors,
    ) = reconstruction_arrays(ARMS["B1"]["model"])
    if len(a_reconstruction.images) != ARMS["A"]["registered"]:
        raise RuntimeError("A registered-image count mismatch")
    if len(b_reconstruction.images) != ARMS["B1"]["registered"]:
        raise RuntimeError("B1 registered-image count mismatch")
    if len(a_xyz) != ARMS["A"]["vertices"]:
        raise RuntimeError("A point count mismatch")
    if len(b_xyz) != ARMS["B1"]["vertices"]:
        raise RuntimeError("B1 point count mismatch")
    if np.count_nonzero(a_source_rgb) or np.count_nonzero(b_source_rgb):
        raise RuntimeError("source RGB audit changed: expected all-black COLMAP colors")
    assert_model_frame_names(a_reconstruction, "A")
    assert_model_frame_names(b_reconstruction, "B1")

    sim3 = pycolmap.align_reconstructions_via_proj_centers(
        b_reconstruction, a_reconstruction, 0.1
    )
    if sim3 is None:
        raise RuntimeError("B1→A camera-center Sim3 failed")
    if abs(sim3.scale - 0.167374037472674) >= 1e-12:
        raise RuntimeError(f"unexpected Sim3 scale: {sim3.scale}")
    matrix = np.asarray(sim3.matrix())
    b_aligned = (matrix[:, :3] @ b_xyz.T).T + matrix[:, 3]

    true_colors = extract_true_colors(
        {"A": a_reconstruction, "B1": b_reconstruction}
    )
    a_rgb = true_colors["A"]
    b_rgb = true_colors["B1"]

    combined = np.concatenate([a_xyz, b_aligned], axis=0)
    a_ply = DATA_ROOT / ARMS["A"]["ply_name"]
    b_ply = DATA_ROOT / ARMS["B1"]["ply_name"]
    write_ascii_ply(
        a_ply,
        arm="A",
        xyz=a_xyz,
        rgb=a_rgb,
        tracks=a_tracks,
        errors=a_errors,
        source_hash=ARMS["A"]["hashes"]["points3D.bin"],
        transform_label="identity_A_world",
    )
    write_ascii_ply(
        b_ply,
        arm="B1",
        xyz=b_aligned,
        rgb=b_rgb,
        tracks=b_tracks,
        errors=b_errors,
        source_hash=ARMS["B1"]["hashes"]["points3D.bin"],
        transform_label="camera_center_sim3_to_A_no_filtering",
    )

    manifest = {
        "schema": "pw_ab_true_color_ply_viewer_v2",
        "experiment_id": "arkit_pose_solver_input_ab_20260821_host_smoke_v2",
        "filtering": False,
        "synthetic_colors": False,
        "ply_rgb": "capture_hevc_mean_over_track_observations",
        "color_source": {
            "capture_id": "cap_1786546115077820",
            "hevc_sha256": COLOR_SOURCE_HASHES[HEVC_SOURCE],
            "hevc_manifest_sha256": COLOR_SOURCE_HASHES[HEVC_MANIFEST],
            "master_manifest_sha256": COLOR_SOURCE_HASHES[
                HEVC_MASTER_MANIFEST
            ],
            "photo_bundle_sha256": COLOR_SOURCE_HASHES[PHOTO_BUNDLE],
            "fed_frames_sha256": COLOR_SOURCE_HASHES[FED_FRAMES],
            "frame_count": FRAME_COUNT,
            "resolution": [FRAME_WIDTH, FRAME_HEIGHT],
            "archive_first_frame": archive_frame_names[0],
            "archive_last_frame": archive_frame_names[-1],
            "decode": "ffmpeg_9.0.1_hevc_to_lossless_png_payload",
            "extraction": "pycolmap_extract_colors_for_all_images_mean",
        },
        "b1_transform": "camera_center_sim3_to_A",
        "sim3": {
            "scale": float(sim3.scale),
            "matrix_3x4": matrix.tolist(),
            "common_cameras": 57,
            "max_proj_center_error_argument": 0.1,
        },
        "ranges": cube_ranges(combined),
        "arms": {
            "A": {
                "source_model": "work/A_current_sidecar_01/model",
                "registered_images": len(a_reconstruction.images),
                "vertices": len(a_xyz),
                "source_cameras_sha256": ARMS["A"]["hashes"]["cameras.bin"],
                "source_images_sha256": ARMS["A"]["hashes"]["images.bin"],
                "source_points3D_sha256": ARMS["A"]["hashes"]["points3D.bin"],
                "ply": f"data/{a_ply.name}",
                "ply_sha256": sha256(a_ply),
                "source_model_rgb_all_zero": True,
                "true_color_nonblack_vertices": int(
                    np.count_nonzero(np.any(a_rgb != 0, axis=1))
                ),
                "true_color_unique_rgb": len(np.unique(a_rgb, axis=0)),
            },
            "B1": {
                "source_model": "work/B1_contract_smoke_01/model",
                "registered_images": len(b_reconstruction.images),
                "vertices": len(b_xyz),
                "source_cameras_sha256": ARMS["B1"]["hashes"]["cameras.bin"],
                "source_images_sha256": ARMS["B1"]["hashes"]["images.bin"],
                "source_points3D_sha256": ARMS["B1"]["hashes"]["points3D.bin"],
                "ply": f"data/{b_ply.name}",
                "ply_sha256": sha256(b_ply),
                "source_model_rgb_all_zero": True,
                "true_color_nonblack_vertices": int(
                    np.count_nonzero(np.any(b_rgb != 0, axis=1))
                ),
                "true_color_unique_rgb": len(np.unique(b_rgb, axis=0)),
            },
        },
        "diagnostic_metrics_not_ground_truth": {
            "camera_center_median_m": 0.00213900309323,
            "rotation_median_deg": 0.137239179963404,
            "sparse_fscore_2_5cm": 0.989365979428217,
        },
        "plotly_js": "3.6.0_inline_from_plotly_python_6.8.0",
    }
    (VIEWER_ROOT / "viewer-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (VIEWER_ROOT / "index.html").write_text(
        build_html({"ranges": manifest["ranges"]}),
        encoding="utf-8",
    )
    print(f"BUILT A={len(a_xyz)} B1={len(b_xyz)}")


if __name__ == "__main__":
    main()
