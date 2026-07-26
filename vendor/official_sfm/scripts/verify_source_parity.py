#!/usr/bin/env python3
"""Prove that the native official route is the frozen self-route source copy.

The shipping self archive predates b930's resume/tombstone changes.  Its exact
source identity is the ea77244a snapshot plus the already-present ghost-mask
working-tree change.  The official copy may differ only in ownership names:
configuration keys, the Metal matcher symbol, and native sidecar filenames.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys


SELF_SOURCE_REVISION = "ea77244a8fd54153544cddaf95b56c0010d575ca"
REJECTED_REVISION = "b930ab185135dfbd172aef7c2bbeed67ef315f75"
SELF_ARCHIVE_SHA256 = (
    "9c88366a1db32b42c3c402616c9eae90b76279a68b16763aefbbcfebeec07618"
)
SELF_ADAPTER_OBJECT_SHA256 = (
    "a01a7c356f5a8efc052b40d096566dbd5c65adb1a1346ff73bad73c606981c2d"
)
DIRTY_GHOST_MASK_SHA256 = (
    "d32694cb42451095a66a093d61f47b668f075423733e5aabfe62944551e0ce20"
)
# The official route intentionally carries reviewed deltas from the frozen
# self-route copy: one fixed ARKit PINHOLE camera per image, upstream COLMAP
# six-image local and iterative global refinement for the independent V20 /
# +10% publication schedule, and the product-selected 0.8 Lowe ratio. Pin the
# complete normalized translation unit so this exception cannot grow silently.
# Production additionally hard-stops at COLMAP's final global BA + official
# filtering; all historical self repair/detail passes remain compiled only for
# old-run reproducibility and are unreachable in the shipping route.
# 2026-07-25 reviewed delta: AddOfficialQuadraticPairs — a faithful port of
# upstream SequentialPairingOptions{overlap=10, quadratic_overlap=true}
# (colmap/controllers/pairing.{h,cc}) that appends the (i, i+2^k) long-range
# pairs the capture-time K-window never produces. It is pair SELECTION only:
# candidates are matched with the shipped matcher, verified under COLMAP
# DEFAULT TwoViewGeometryOptions, and appended to matches /
# two_view_geometries; no Point3D or observation is touched, and it runs
# strictly BEFORE the final global BA, so the delivered model is still the
# official endpoint. Kill switch: OFFICIAL_AETHER_QUADRATIC_OVERLAP=0.
# 2026-07-26 reviewed delta: the capture-time global BA
# (aether_sfm_global_refine) now enables upstream's own global-BA size
# reducer, mapper.ba_global_ignore_redundant_points3D = true. Upstream
# IncrementalMapper::AdjustGlobalBundle then splits the whole-model problem
# into a joint solve over the cameras plus only the non-redundant points,
# followed by a second pass that optimizes the dropped points alone with every
# other parameter fixed — nothing is discarded, so it is lossless by
# construction. It bounds the joint Jacobian/Schur workspace, which is the
# block that OOM-killed a 126-frame capture on an iPhone 14 Pro.
# 2026-07-26 reviewed delta (diagnostic only, no algorithm change):
# aether_sfm_add_frame's catch used to discard the exception message, so a
# device take that lost 25 consecutive frames to errInternal left no evidence
# of what threw — and every one of those frames surfaced to the user as a red
# "unconnected photo, reshoot nearby" card. The handler now logs e.what() and
# appends an add_frame_throw record to sfm_match_fail.jsonl (pullable after a
# detached run), plus a catch-all for non-std exceptions.
# 2026-07-26 reviewed delta (env-gated experiment knobs, defaults unchanged =
# shipped behaviour byte-identical when unset):
#   OFFICIAL_AETHER_OFFICIAL_TRIANGULATE=1  — call upstream
#     IncrementalMapper::TriangulateImage on each accepted frame, the way
#     controllers/incremental_pipeline.cc does after registering an image.
#   OFFICIAL_AETHER_SELFDEV_TRIANGULATE=0   — skip the hand-written live
#     create/grow/merge point authoring (matching + db writes unaffected).
#   OFFICIAL_AETHER_TRI_IGNORE_2VIEW=0      — let the official triangulator
#     keep two-view tracks (upstream default true; the flag confounded the
#     official-vs-selfdev comparison).
#   OFFICIAL_AETHER_CREATE_REPROJ_PX        — live new-point gate, default 10.
# Plus a diagnostic point-provenance count at finalize publish (live vs
# official vs dropped, logged + appended to sfm_match_fail.jsonl) and the
# add_frame exception logger. Seven-arm host A/B on a 131-frame device db:
# official TriangulateImage with 2-view enabled beats the self-dev authoring
# on depth-sigma in every track-length bucket, +33% 7+-tracks, waste 27.7%->
# 8.4%, at -6.9% total points (the worst 2-view tail). Production switch
# pending on-device sign-off.
# 2026-07-26 reviewed delta (signed): FinalizeRematchStarvedFrames un-gated
# from kProductionOfficialEndpointOnly. It is pair generation + matching under
# colmap-DEFAULT TwoViewGeometryOptions and only appends matches /
# two_view_geometries — the same official-semantics classification that
# re-enabled the quadratic pass — and it is what repays the thermal
# throttle's debt (the shipped plugin opts into LIVE_CAND_K_HOT=6 whose
# "delivery-lossless" promise depends on this backfill; with the gate in
# place, a 149-frame capture with 118 thermal-serious frames delivered ~20%
# fewer points than the same db with full matching). The remaining five
# endpoint gates (temporal-detail / spatial-revisit / low-parallax upgrade /
# fragment merge / live repay) stay in place.
# 2026-07-26 reviewed delta (enrichment scheduling, signed): device capture
# cap_1785066707194992 (156 frames, 115 thermal-serious) proved the armed
# enrichment order inverted the "most valuable debt first" principle — the
# unbudgeted quadratic pass consumed the whole kAuto window on long-range
# pairs (gap-128 avg 0.7 inliers) and the starved-frame re-match was
# budget-stopped at zero, leaving ~100 throttled frames without gaps 7-12.
# Fix: armed order is now rematch → quadratic → spatial; the quadratic pass
# gained the same per-pair EnrichBudgetExhausted gate and a gap-ascending
# stable sort (a budget stop sheds the least-valuable far tail); both passes
# append a pullable summary record (quadratic_summary /
# finalize_rematch_summary) to sfm_match_fail.jsonl because glog is invisible
# in release builds. Unarmed runs keep the legacy order bit-identically; the
# shipped plugin currently disarms the budget entirely
# (OFFICIAL_AETHER_ENRICH_TIME_BUDGET_MS=0, user-signed: full K12 + full
# quadratic, no truncation).
# 2026-07-26 reviewed delta (QUAD-PREPAY, signed): the capture-idle channel
# (aether_sfm_live_repay, driven by the Dart facade only when the frame queue
# is empty) now performs the OFFICIAL quadratic-overlap prepay at the
# production endpoint: the exact candidate set (i, i+2^k with 2^k > live K),
# matcher, ratio, and colmap-DEFAULT TwoViewGeometry verification the
# finalize AddOfficialQuadraticPairs pass runs at finish time, executed
# earlier so the finish-time debt shrinks toward zero (user constraint:
# post-capture wait must not grow). db-only writes, identical per-pair
# results (descriptors frozen at extraction); the finalize pass remains the
# unconditional backstop and now always emits its quadratic_summary (with
# prepaid_attempted/prepaid_written) even when the prepay left it nothing to
# do. Kill switch: OFFICIAL_AETHER_QUADRATIC_PREPAY=0. The self-route
# starved-window repay body stays behind the endpoint gate unchanged.
OFFICIAL_PRODUCTION_ENDPOINT_SHA256 = (
    "f2db4385e870eae98815fe54d9c5ce32b80d323d8f028ec6e954809af4f947f2"
)
REQUIRED_PRODUCTION_ENDPOINT_MARKERS = (
    b"colmap::PinholeCameraModel::model_id",
    b"camera.SetFocalLengthX(fx);",
    b"camera.SetFocalLengthY(fy);",
    b"rec.camera_id = camera_id;",
    b"rec.camera = camera;",
    b"SetAllCameraIntrinsicsConstant(",
    b"constexpr bool kProductionOfficialEndpointOnly = true;",
    b"if (kProductionOfficialEndpointOnly) return;",
    # 2026-07-26 QUAD-PREPAY: the one `return 0;`-form gate (live_repay) now
    # routes the production path to the official quadratic prepay instead of
    # a bare no-op; the marker below pins that wiring (and the gate itself)
    # against silent removal. The self-route repay body stays behind it.
    b"if (kProductionOfficialEndpointOnly) {\n    return PrepayQuadraticTick(s, max_pairs);\n  }",
    # Upstream quadratic overlap must stay wired and stay official-default:
    # a silent removal (or a switch to the tightened self-route gates) would
    # otherwise pass every other check in this file.
    # The capture-time global BA must keep upstream's size reducer on: without
    # it the joint problem is whole-model again and 126-frame captures OOM.
    b"official_options.mapper.ba_global_ignore_redundant_points3D = true;",
    b"void AddOfficialQuadraticPairs(aether_sfm_session* s) {",
    b"const colmap::TwoViewGeometryOptions tvg_options;  // colmap defaults",
    b"AddOfficialQuadraticPairs(s);",
)
FORBIDDEN_SHARED_CAMERA_MARKERS = (
    b"colmap::kInvalidCameraId, colmap::SimplePinholeCameraModel::model_id",
    b"s->camera, prev.points, s->camera, rec.points",
)
FORBIDDEN_B930_MARKERS = (
    "AETHER_SFM_ERR_BUSY",
    "AppendRemovedId",
    "RemovedSidecarPath",
    '".removed"',
    "tombstone",
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git_show(repo: Path, revision: str, path: str) -> bytes:
    return subprocess.check_output(
        ["git", "-C", str(repo), "show", f"{revision}:{path}"]
    )


def normalize_owned_names(data: bytes) -> bytes:
    return (
        data.replace(b"OFFICIAL_AETHER_", b"AETHER_")
        .replace(b"pwofficial_gpu_match", b"pwsfm_gpu_match")
        .replace(b"official_finalize_segments.json", b"finalize_segments.json")
        .replace(b"official_sfm_fed_frames.jsonl", b"sfm_fed_frames.jsonl")
    )


def normalize_product_wrapper(data: bytes, *, telemetry: bool = False) -> bytes:
    normalized = (
        data.replace(b"pwofficial_", b"pwsfm_")
        .replace(b"PWOFFICIAL_EXPORT", b"PWSFM_EXPORT")
        .replace(b"// pwsfm_telemetry.mm", b"// pw_telemetry.mm")
        .replace(b"pwsfm_telemetry", b"pw_telemetry")
    )
    if telemetry:
        normalized = normalized.replace(
            b'__attribute__((visibility("default"), used))\n', b""
        )
    return normalized


def normalize_official_match_ratio_delta(data: bytes) -> bytes:
    """Map only the reviewed official-route 0.8 default back to self 0.7."""
    replacements = (
        (b"0.8 product default", b"0.7 default"),
        (b"product default 0.8", b"default 0.7"),
        (b"maxRatio = 0.8f", b"maxRatio = 0.7f"),
        (b"max_ratio > 0 ? max_ratio : 0.8",
         b"max_ratio > 0 ? max_ratio : 0.7"),
    )
    for official, self_route in replacements:
        data = data.replace(official, self_route)
    return data


def without_whitespace(data: bytes) -> bytes:
    return re.sub(rb"\s+", b"", data)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    dev_root = root.parents[1]
    aether_root = Path(
        os.environ.get("AETHER_ROOT", dev_root.parent / "Aether3D-cross")
    ).resolve()
    official_source_root = aether_root / "aether_cpp/official_pipeline"

    source_pairs = {
        "src/official_aether_sfm_c.cc":
            "aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc",
        "src/official_aether_threaded_extract.cc":
            "aether_cpp/third_party/glomap_vendor/bench/aether_threaded_extract.cc",
        "src/official_dsp_sift_c.cc":
            "aether_cpp/third_party/glomap_vendor/bench/dsp_sift_c.cc",
        "src/official_dsp_sift_gpu_c.cc":
            "aether_cpp/third_party/glomap_vendor/bench/dsp_sift_gpu_c.cc",
        "src/official_incremental_pipeline.cc":
            "aether_cpp/third_party/glomap_vendor/colmap-src/colmap/controllers/"
            "incremental_pipeline.cc",
        "src/official_bundle_adjustment_ceres.cc":
            "aether_cpp/third_party/glomap_vendor/colmap-src/colmap/estimators/"
            "bundle_adjustment_ceres.cc",
        "include/aether_sfm_c.h": "aether_cpp/include/aether_sfm_c.h",
        "include/aether_bitmap_shim.h":
            "aether_cpp/third_party/glomap_vendor/stubs/aether_bitmap_shim.h",
        "include/aether_l1_arbitrate.h":
            "aether_cpp/third_party/glomap_vendor/bench/aether_l1_arbitrate.h",
        "include/aether_l1_plan.h":
            "aether_cpp/third_party/glomap_vendor/bench/aether_l1_plan.h",
        "include/aether_threaded_extract.h":
            "aether_cpp/third_party/glomap_vendor/bench/aether_threaded_extract.h",
    }

    for official_relative, source_path in source_pairs.items():
        official_path = official_source_root / official_relative
        if not official_path.is_file():
            fail(f"missing official source copy: {official_path}")
        actual = normalize_owned_names(official_path.read_bytes())
        if official_relative == "src/official_aether_sfm_c.cc":
            actual_hash = sha256(actual)
            if actual_hash != OFFICIAL_PRODUCTION_ENDPOINT_SHA256:
                fail(
                    "official production-endpoint source identity changed: "
                    f"{actual_hash}"
                )
            for marker in REQUIRED_PRODUCTION_ENDPOINT_MARKERS:
                if marker not in actual:
                    fail(f"missing production-endpoint marker: {marker!r}")
            for marker in FORBIDDEN_SHARED_CAMERA_MARKERS:
                if marker in actual:
                    fail(f"shared-camera implementation returned: {marker!r}")
            print(
                "PASS source src/official_aether_sfm_c.cc "
                "(pinned per-image PINHOLE + official BA/filter endpoint)"
            )
            continue
        expected = git_show(aether_root, SELF_SOURCE_REVISION, source_path)
        actual = normalize_official_match_ratio_delta(actual)
        if actual != expected:
            fail(
                "source copy diverged beyond allowed ownership names: "
                f"{official_relative}"
            )
        print(f"PASS source {official_relative}")

    # The framework-facing shim, Metal matcher, and telemetry probe are copied
    # from the shipping product tree, not the algorithm repository.  Verify
    # both the vendored files and the Aether build inputs so neither copy can
    # silently drift.
    product_pairs = {
        "src/pwofficial_export_shim.c": "vendor/aether_ffi/src/pwsfm_export_shim.c",
        "src/pwofficial_gpu_match.mm": "vendor/aether_ffi/src/pwsfm_gpu_match.mm",
        "src/pwofficial_telemetry.mm": "vendor/aether_ffi/src/pw_telemetry.mm",
    }
    for official_relative, self_relative in product_pairs.items():
        official_data = normalize_official_match_ratio_delta(
            normalize_product_wrapper(
                (root / official_relative).read_bytes(),
                telemetry=official_relative.endswith("telemetry.mm"),
            )
        )
        self_data = (dev_root / self_relative).read_bytes()
        if without_whitespace(official_data) != without_whitespace(self_data):
            fail(f"product wrapper copy diverged: {official_relative}")
        print(f"PASS product wrapper {official_relative}")

    mirrored_build_inputs = {
        "src/pwofficial_export_shim.c": "src/pwofficial_export_shim.c",
        "src/pwofficial_gpu_match.mm": "src/official_gpu_match.mm",
        "src/pwofficial_sim_backend.c": "src/pwofficial_sim_backend.c",
        "src/pwofficial_telemetry.mm": "src/pwofficial_telemetry.mm",
    }
    for product_relative, aether_relative in mirrored_build_inputs.items():
        if (root / product_relative).read_bytes() != (
            official_source_root / aether_relative
        ).read_bytes():
            fail(f"vendored/build-input mirror drifted: {product_relative}")
        print(f"PASS mirrored build input {product_relative}")

    product_type_header = root / "include/aether_sfm_c.h"
    expected_type_header = git_show(
        aether_root, SELF_SOURCE_REVISION, "aether_cpp/include/aether_sfm_c.h"
    )
    if (
        normalize_official_match_ratio_delta(product_type_header.read_bytes())
        != expected_type_header
    ):
        fail("vendored product type header is not the ea77244a header")
    print("PASS product type header (no b930 BUSY enum)")

    ghost_mask = official_source_root / "include/aether_ghost_mask.h"
    ghost_hash = sha256(ghost_mask.read_bytes())
    if ghost_hash != DIRTY_GHOST_MASK_SHA256:
        fail(f"frozen dirty ghost-mask hash changed: {ghost_hash}")
    print(f"PASS dirty ghost-mask {ghost_hash}")

    self_archive = dev_root / "vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a"
    if not self_archive.is_file():
        fail(f"shipping self archive missing: {self_archive}")
    archive_hash = sha256(self_archive.read_bytes())
    if archive_hash != SELF_ARCHIVE_SHA256:
        fail(f"shipping self archive identity changed: {archive_hash}")
    print(f"PASS shipping self archive {archive_hash}")
    adapter_member = subprocess.check_output(
        ["ar", "-p", str(self_archive), "aether_sfm_c.cc.o"]
    )
    adapter_member_hash = sha256(adapter_member)
    if adapter_member_hash != SELF_ADAPTER_OBJECT_SHA256:
        fail(f"shipping adapter object identity changed: {adapter_member_hash}")
    print(f"PASS shipping adapter member {adapter_member_hash}")

    official_text = b"\n".join(
        path.read_bytes()
        for tree in (official_source_root / "src", official_source_root / "include")
        for path in sorted(tree.rglob("*"))
        if path.is_file() and path.suffix in {".c", ".cc", ".h", ".mm"}
    )
    for marker in FORBIDDEN_B930_MARKERS:
        if marker.encode() in official_text:
            fail(f"b930-only marker present in official source: {marker}")

    rejected_source = git_show(
        aether_root,
        REJECTED_REVISION,
        "aether_cpp/third_party/glomap_vendor/bench/aether_sfm_c.cc",
    )
    for marker in FORBIDDEN_B930_MARKERS[:3]:
        if marker.encode() not in rejected_source:
            fail(f"forensic control no longer distinguishes b930 marker: {marker}")
    print("PASS b930-only source markers absent (positive control present in b930)")

    binary = (
        root
        / "Frameworks/PWOfficialSfm.xcframework/ios-arm64/"
          "PWOfficialSfm.framework/PWOfficialSfm"
    )
    if not binary.is_file():
        fail(f"official device binary missing: {binary}")
    binary_strings = subprocess.check_output(["strings", str(binary)])
    for marker in FORBIDDEN_B930_MARKERS:
        if marker.encode() in binary_strings:
            fail(f"b930-only marker present in official device binary: {marker}")
    print("PASS b930-only binary markers absent")

    for marker in (b"missing_jpeg=", b"n_frames_missing_jpeg"):
        if marker not in binary_strings:
            fail(f"shipping ea/L1 marker missing from device binary: {marker!r}")
    demangled_symbols = subprocess.check_output(
        ["c++filt"], input=subprocess.check_output(["nm", str(binary)])
    )
    five_argument_floor = (
        b"aether_ghost::FitFloorPlane(double const*, unsigned long, double*, "
        b"double*, double const*)"
    )
    if five_argument_floor not in demangled_symbols:
        fail("dirty ghost-mask five-argument FitFloorPlane is missing")
    print("PASS shipping L1 markers and dirty-ghost five-argument symbol present")

    print(
        "PASS: native official route is ea77244a self semantics plus the "
        "pinned per-image PINHOLE, official BA, and 0.8 ratio deltas, "
        "ownership names, and frozen dirty ghost-mask"
    )


if __name__ == "__main__":
    main()
