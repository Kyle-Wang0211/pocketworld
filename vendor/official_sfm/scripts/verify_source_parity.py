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
# 2026-07-26 reviewed delta (telemetry-only, signed): T1/T2/T3 observation
# timers — frame_split (per-frame five-way split of the match= wall: GPU
# pairing / TVG+writes / official triangulation / local BA / tail),
# finalize_split (stage-1 BA-vs-merge, enrich-gate wait, stage-2 interior via
# pure-timing hooks added to the vendored IterativeGlobalRefinement), and a
# build_stamp line at session create (twice in one day a capture was analysed
# against code written after it). All records go to the pullable
# sfm_match_fail.jsonl; zero algorithm changes. The vendored colmap tree also
# carries upstream PR #4553 (RANSAC lock-scope fix, MERGED upstream; local
# byte-parity proven on 40 device pairs; our builds never enabled OpenMP so
# the original critical was compiled out — the patch is upstream alignment +
# protection if parallel RANSAC is ever enabled).
# 2026-07-26 reviewed delta (BA-STAGE1-FULL, signed): the cap43-era stage-1
# protections (UTILITY QoS + halved ceres threads) assumed enrichment was
# the finalize critical path; cap_1785078141726265 measured that inverted
# after the v2 matcher (enrich 35.6s < stage-1 46.7s, gate_wait=0) — the
# protections taxed the true critical path 2x. Defaults flip to full speed
# (thread count is signed bit-equal; the plugin pins STAGE1_ROUNDS_CAP=2 so
# the 2/3 round allocation is frozen and the change stays EXACT); legacy
# posture one env away for the heavy-revisit shape
# (OFFICIAL_AETHER_STAGE1_HALF_THREADS=1 / _STAGE1_UTILITY_QOS=1). Plus the
# ba_rounds per-solve ring telemetry (official_bundle_adjustment_ceres.cc
# ring + AppendBaRingJsonl at both stages) — pure observation.
# 2026-07-26 reviewed delta (QUAD-PIPELINE, signed): the quadratic
# enrichment pass gains an order-preserving matcher prefetch. Provenance is
# upstream COLMAP's own matcher→verifier JobQueue pipeline
# (feature_matching_utils.h:103-106) — the serial per-pair match→TVG loop
# was our own simplification. The prefetch thread runs ONLY the
# deterministic Metal matcher (no PRNG); TVG estimation and all db writes
# stay on the enrichment thread in todo order, so the RANSAC thread-local
# PRNG stream — and therefore the written matches/two_view_geometries — are
# byte-identical to the serial loop (acceptance: host replay A/B db diff).
# Live sessions only; resume sessions and OFFICIAL_AETHER_QUAD_PIPELINE=0
# keep the serial loop verbatim.
# 2026-07-27 reviewed delta (EPI-PRIOR experiment arm, DEFAULT OFF — unset
# env keeps shipped behaviour byte-identical): ARKit epipolar-prior guided
# matching for the sign-off dossier. Synthesizes E from the FED ARKit poses
# (FrameRecord.cam_from_world, never BA-refined) and routes through the
# EXISTING COLMAP-parity guided kernel via PrepareGuidedGeometry's
# calibrated path, gap-adaptive band + match-count-collapse fallback to the
# unchanged full GEMM. Classification: APPROXIMATE — ships only through
# noise-band quality gates + user sign-off. Knobs:
# OFFICIAL_AETHER_EPI_PRIOR_MATCH / _EPI_BAND_BASE_PX / _EPI_BAND_PER_GAP_PX
# / _EPI_BAND_MAX_PX / _EPI_FALLBACK_MIN; epi_summary jsonl when armed.
# 2026-07-27 reviewed delta (T-EXTRACT, telemetry-only, signed): the
# extractor's nine SED stage durations (always recorded in
# sift_extract_dawn.cc, printing still env-gated) are read after each
# extract via the WEAK aether_sed_last_stages() and appended to the
# frame_split sidecar record as "ex":[pyr,pack,det,sup,aff,ori,clamp,desc,
# rb]. Sizes the A6 descriptor-batching knife (PopSift predicts the
# descriptor stage dominates DSP×10 — never measured on our kernel). The
# gpu-extract archive is rebuilt with the same recipe; pwofficial and pwsfm
# archives remain byte-identical copies. Zero algorithm changes.
# 2026-07-27 reviewed delta (A1B-ASYNC-PVBA experiment arm, DEFAULT OFF —
# unset env keeps the sync preview BA byte-identical): the streaming-BA
# publish is superlinear in poses (495ms@20 → 9.5s@140; ~40s extrapolated
# at 300 frames — the blocker for the signed 20-300 range). The arm runs
# the SAME BA on a snapshot copy on a background thread (own db read
# connection, WAL) and the worker merges poses + surviving point positions
# back at the next publish trigger. NOISE-BAND (refinements land a few
# frames late) — ships only through the host matrix + sign-off. Knobs:
# OFFICIAL_AETHER_ASYNC_PREVIEW_BA / _ASYNC_PREVIEW_BA_THREADS;
# apvba_summary jsonl when armed.
# 2026-07-27 A1b-v2 (still DEFAULT OFF): the field-merge harvest was killed
# by its own matrix — it discarded the background pass's FilterFrames /
# FilterPoints deletions, delivering -5.65%/-6.33% points against a 0.059%
# noise band. The harvest now ADOPTS THE REFINED MODEL WHOLESALE (every BA
# decision, deletions included) and replays the frames accepted during the
# background pass through the same official path add_frame uses (per-image
# PINHOLE + trivial rig, AddImageWithTrivialFrame with the ARKit pose, then
# IncrementalMapper::TriangulateImage over the db matches). Nothing is
# hand-merged. Still NOISE-BAND, still sign-off gated.
# 2026-07-27 A1b-v3 (still DEFAULT OFF): v2's matrix fixed the deletion
# 病根 (track-length fingerprint reversed: long tracks GREW) but exposed a
# P0 — the harvest built its DatabaseCache on the worker while the
# background thread had its own Database::Open, and the lock contention
# silently ate 4 accepted frames (add_frame_features ... ERR_INTERNAL),
# which contradicts "采集必出点云". v3: the cache is built once at kick on
# the worker's own connection and handed to the background thread, which
# never touches sqlite; consecutive drops back off (2 ⇒ skip 2 kicks, 3+ ⇒
# skip 4) instead of re-kicking every frame; the background catch records
# the exception text into apvba_summary.last_error.
# 2026-07-27 A1b-v4 (still DEFAULT OFF): correction propagation. v2/v3
# replayed the frames accepted during the background pass with their RAW
# ARKit poses, leaving a seam — one side of the model BA-corrected, the
# other not. ORB-SLAM2 (arXiv:1610.06475) solves exactly this when its full
# BA runs in a separate thread: "propagating the correction of updated
# keyframes (i.e. the transformation from the non-optimized to the
# optimized pose) to non-updated keyframes through the spanning tree".
# Adapted here: the reference is the newest frame the pass did optimize
# (the spanning-tree parent of a sequential K-window capture), the pre-BA
# poses are snapshotted at kick, and each replayed frame's pose becomes
# C * (C_old^-1 * C_new). Ideas only — ORB-SLAM3 is GPLv3. The correction
# magnitude is reported in apvba_summary (corr_mm / corr_deg) so the next
# matrix can say whether the seam explains v2's -2.4%.
# 2026-07-27 A1b-v5 (controlled-comparison knobs, still DEFAULT OFF): the
# v4 matrix cleared every engineering gate (zero eaten frames, dropped 0/7,
# B-runs byte-deterministic, in-feed blocking BA -93%) but its point delta
# could not be attributed — v4 changed propagation AND scheduling at once,
# and the async arm runs MORE global BA than sync (harvest-less ticks leave
# the publish-policy baselines unreset, so it re-kicks back-to-back; more BA
# = more FilterPoints/FilterFrames deletions). Two knobs isolate the causes:
# OFFICIAL_AETHER_ASYNC_PREVIEW_BA_PROPAGATE=0 disables only the correction
# propagation (= v3 semantics); _MATCH_CADENCE=1 kicks at most one
# background pass per successful publish (BA workload parity with sync).
# apvba_summary now records both flags.
# 2026-07-27 A1b-v6 (_PARAM_ONLY knob, still DEFAULT OFF): the v5 2x2
# isolated the async delta to a STRUCTURAL residual (2-view deletions +
# track merges decided on a stale snapshot); cadence and propagation each
# measured ~0. v6 therefore lets the background pass solve parameters only
# (one official AdjustGlobalBundle; no CompleteAndMergeTracks, no
# FilterPoints/FilterFrames, no retriangulation) and defers every
# structural decision to the synchronous finalize, which redoes them from
# scratch over the full db anyway. Late-arriving parameter perturbations
# wash out in stage-1/2 convergence; structural divergence does not.
# 2026-07-28 reviewed delta (BA-THREADS-POST, EXACT): the finalize thread
# budget drops its two-core camera reserve — min(6,hw-2) -> min(6,hw),
# A16 4 -> 6 — because finalize runs strictly after capture (same rationale
# as the matcher sprint mode and the signed stage-1 full-thread knife).
# Quality evidence: thread-count bit-equality signed 07-11 and re-proven on
# host 07-28 (_host_fixtures/prepay_threads_exact: T4/T6 x2 delivered PLYs
# byte-identical, identical iteration counts; finalize wall -16.1%/-12.8%).
# The capture-period windowed incremental BA keeps the reserve via the new
# LiveBaThreads() (env OFFICIAL_AETHER_LIVE_BA_THREADS). Same experiment
# also killed the QUAD-PREPAY revival: prepay is NOT byte-exact (the
# earlier TVG estimation shifts the RANSAC stream — 1375-1556 of ~2000
# two_view_geometries rows differ, both arms individually deterministic)
# and bought zero net finalize time; it stays disabled.
# [RE-BLESSED 2026-07-29 用户签决] 95ea7fb6… → 12eefda9…
#
# 为什么这次是"更新钉死值"而不是"改回去":本文件顶部的契约是「官方拷贝只能在
# 命名上与自研拷贝不同」,它守的是"两条采集路线并存"时期的等价性。**那个前提
# 已经不成立**:线上只剩一条采集路由(ar_capture_page.dart:2593 的 UI 签决注释
# 记录了另一条 lib/ui/capture/ar_capture_page.dart 早已删除),且逐帧遥测
# frame_split 的字符串只存在于官方框架二进制里、自研的 libglomap_core.a 里为 0
# —— 出货跑的是官方路线,自研路线不再是需要保持镜像的对象。
#
# 本次真实差异(LIVE-LBA-THREADS + AETHER-T2,均在 official_aether_sfm_c.cc):
#   • 拍摄期 local BA 的 num_threads 由上游默认 -1 改为 LiveBaThreads()(A16→4),
#     多线程门槛 50000→6000。host 四臂对照几何逐位相同,local BA −20%。
#   • 逐帧 local BA 内部计时计数器(纯观测,不改控制流、不消耗 PRNG)。
# 其余闸仍然全绿:ABI 签名 26/26 一致、边界 27 导出 TWOLEVEL/NOUNDEFS 隔离。
#
# ⚠️ 这道闸本身保留:它继续监测**今后**的意外漂移,只是基线换成了新值。
# [GPU-TIMESTAMP-PROBE V1 2026-07-30] The independently accepted algorithm
# actual writer now serializes the private, consume-once GPU timestamp probe
# into the existing frame_split sidecar. This is observation-only and keeps
# product Dart/Swift plus the stable framework ABI unchanged. Pin the complete
# normalized endpoint at the accepted 71d0e0b1… identity; do not relax the gate.
# 2026-08-07 reviewed delta (IDLE-PREPAY, signed): when the official quadratic
# prepay finds no debt, the same capture-idle window now pays the starved-window
# debt instead of returning 0. Gate: IdlePrepayEnabled(), default ON, killed by
# OFFICIAL_AETHER_IDLE_PREPAY=0. Rationale: two device telemetry runs showed
# idle_prepay_ticks=0 / repay_calls=0 — the official channel never fired on a
# real capture because the user keeps tapping the shutter, so disconnected
# frames were only repaired at finalize, by which time the user has left the
# scene and what gets repaired is pairs, not observations.
#
# 2026-08-08 reviewed delta (TVG-SPLIT, signed 2026-08-22): the official route's
# two-view geometry is split into TWO independent RANSACs per pair —
#   • POSE  ← aether::sfm::EstimateUprightRelativePoseV1 (gravity-constrained
#             upright relative pose, mandatory_gravity_tvg_v1.cc:125). This
#             REPLACES colmap::EstimateTwoViewGeometry for everything that gets
#             persisted; a pair with no usable ARKit gravity is dropped outright.
#   • LABEL ← colmap::EstimateTwoViewGeometry with force_H_use
#             (mandatory_gravity_tvg_v1.cc:143), kept only to classify planar
#             degeneracy. This half is unchanged official semantics.
# ⚠️ NO kill switch: all 14 call sites of EstimateMandatoryFrameTwoViewGeometry
# route through it unconditionally. Recorded here because the ledger is the only
# audit surface for an un-gated replacement of an official estimator.
# Contract test: test/official_per_image_pinhole_contract_test.dart pins both
# halves and asserts this ledger entry exists.
#
# 2026-08-14 reviewed delta (STARVED-ALWAYS, 用户签): capture-period repair of
# disconnected frames no longer waits for an idle window and no longer backs off
# on thermals. Original design required ">2000ms since the previous frame
# finished + thermal < serious"; on a real capture that window is never reached.
# Gates kept: OFFICIAL_AETHER_STARVED_ALWAYS (rollback) and
# OFFICIAL_AETHER_STARVED_THERMAL_STOP (thermal cutoff), plus
# OFFICIAL_AETHER_PROBE_DEBT_GROW_LIVE for the on-the-spot track growth
# (GrowLiveTracksFromTvgInliers writes live_recon in place — the leg the
# finalize-time variant does not have). GROW_MERGE / GROW_OBS stay default OFF
# (cap201: merge cost −1.54% delivered points).
# Contract test: test/official_stop_production_contract_test.dart pins all
# three gates plus the live_recon entry-point count.
OFFICIAL_PRODUCTION_ENDPOINT_SHA256 = (
    "71d0e0b1da2c4d2caf09da33900e5abd0c193033f10f4c8197c6a18f8504ec6d"
)
# [PORTABLE-CANONICAL-SELECTOR V1 2026-07-31] The official and bench GPU-SIFT
# ABI sources remain byte-identical after adding the default-off canonical
# selector policy, fail-closed canonical status 2, Stable-ID validation, and
# the existing caller-thread timestamp handoff. Pin the reviewed complete
# source; absent/invalid policy values still execute the legacy route.
OFFICIAL_DSP_SIFT_GPU_SHA256 = (
    "c602cb53286a7a1666cf092d8a0ee3587122ded90769e1cd4e59edbe046eb9b0"
)
# [BA-RING 2026-07-26] Pin for src/official_bundle_adjustment_ceres.cc (see
# the reviewed-delta comment at its branch in main()).
OFFICIAL_BA_CERES_WRAPPER_SHA256 = (
    "411d1307963f8ca12ac596975fb1ab942490bbc73572c7fdeab0022fc9b2b2ab"
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
        if official_relative == "src/official_dsp_sift_gpu_c.cc":
            actual_hash = sha256(actual)
            if actual_hash != OFFICIAL_DSP_SIFT_GPU_SHA256:
                fail(
                    "official GPU-SIFT ABI source identity changed: "
                    f"{actual_hash}"
                )
            print(
                "PASS source src/official_dsp_sift_gpu_c.cc "
                "(pinned consume-once timestamp handoff)"
            )
            continue
        # 2026-07-26 reviewed delta (BA-RING, signed): the solver wrapper
        # carries a per-solve observation ring (AetherBaSolveRec +
        # aether_ba_ring_reset/count/get, appended inside the existing
        # AetherLastBaSolveInfo stash lock) so finalize can attribute each
        # BA round's iterations/jacobian/linear-solver time. Telemetry only —
        # solve options and numerics untouched. Pinned like the sfm_c
        # endpoint so this exception cannot grow silently.
        if official_relative == "src/official_bundle_adjustment_ceres.cc":
            actual_hash = sha256(actual)
            if actual_hash != OFFICIAL_BA_CERES_WRAPPER_SHA256:
                fail(
                    "BA solver wrapper source identity changed: "
                    f"{actual_hash}"
                )
            for marker in (b"aether_ba_ring_reset", b"aether_ba_ring_get",
                           b"kAetherBaRingCap"):
                if marker not in actual:
                    fail(f"missing BA-ring marker: {marker!r}")
            print(
                "PASS source src/official_bundle_adjustment_ceres.cc "
                "(pinned solver wrapper + ba_rounds ring)"
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
