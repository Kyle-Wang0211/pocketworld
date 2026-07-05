// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether_depth_tile — C ABI for Plan G post-W1 D5 depth/mask math.
//
// Exposes the cross-platform algorithms from aether/pipeline/{mask_post,
// scale_align}.h to Swift (iOS, via bridging header) / Kotlin (Android, via
// JNI thin shim) / Dart FFI (Flutter direct) / JS (Web, via WASM).
//
// CoreML / TFLite / NNAPI / ONNX Runtime inference itself stays in per-
// platform thin shims — these C functions only run the deterministic math
// (mask post-process / scale alignment) that should be bit-equal across all
// platforms.
//
// History: tile_layout + tile_blend C ABI was originally part of this header
// for the Plan G W1 D3 tile-based DA3 inference path. That whole path was
// removed in Plan G W1 D5+ after we discovered DA3 official InputProcessor
// is single-pass (no tiling), and our 4×3 tile blend produced visible block
// seam artifacts no alignment could fix. The "depth_tile" name is kept for
// header / FFI surface stability across rebuilds (renaming touches podspec
// + bridging-header + xcframework rebuild script).
//
// Memory: ALL buffers are caller-allocated. No malloc/free crosses the FFI
// boundary. Sizes are passed alongside pointers; functions return rc code.

#ifndef AETHER_DEPTH_TILE_C_H
#define AETHER_DEPTH_TILE_C_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─── Result codes ───────────────────────────────────────────────────
// Stable across versions — keep adding new codes at the end, never renumber.
typedef enum {
    AETHER_DEPTH_TILE_OK = 0,
    AETHER_DEPTH_TILE_ERR_BAD_ARGS = 1,          ///< Null pointer / nonsensical dims.
    AETHER_DEPTH_TILE_ERR_BUFFER_TOO_SMALL = 2,  ///< Caller buffer < required capacity.
    AETHER_DEPTH_TILE_ERR_TILE_SIZE = 3,         ///< (Reserved — was used by tile API.)
} aether_depth_tile_rc_t;

// ─── Mask post-process ──────────────────────────────────────────────

/// Apply sigmoid in-place: x ← 1 / (1 + exp(-x)). Stable for large negative x.
void aether_sigmoid_inplace(float* data, int32_t count);

/// Pick the hypothesis index with the highest IoU prediction.
/// Returns 0 if iou_pred is NULL or count <= 0.
int32_t aether_pick_best_iou(const float* iou_pred, int32_t count);

/// Bilinear resize (half-pixel-center convention, matches PIL/OpenCV INTER_LINEAR).
void aether_bilinear_resize(
    const float* src, int32_t src_w, int32_t src_h,
    float* dst, int32_t dst_w, int32_t dst_h);

/// EdgeTAM post-process: pick best of N hypotheses, sigmoid → [0, 1] mask.
///
/// @param masks_logits         n_hypotheses × mask_h × mask_w fp32 logits.
/// @param iou_pred             n_hypotheses fp32 IoU predictions.
/// @param n_hypotheses         Number of mask hypotheses (typically 3 for SAM 2 family).
/// @param mask_h/w             Mask dims (typically 256×256 for EdgeTAM).
/// @param out_mask             OUT: mask_h × mask_w fp32 probability map.
/// @param out_best_idx         OUT: picked hypothesis index. Optional (may be NULL).
/// @param force_hypothesis_idx -1 = argmax(IoU) (legacy / bench). 0..n-1 =
///                             force that hypothesis index, skip argmax.
///                             Plan G W6 production passes 0 (whole-object) —
///                             see feedback_w2_d1_edgetam_prompt_design.md.
/// @return AETHER_DEPTH_TILE_OK on success.
int32_t aether_edgetam_post_process(
    const float* masks_logits, const float* iou_pred,
    int32_t n_hypotheses, int32_t mask_h, int32_t mask_w,
    float* out_mask, int32_t* out_best_idx,
    int32_t force_hypothesis_idx);

/// Binarize a fp32 probability mask in place at the given threshold.
/// `mask[i] = (mask[i] >= threshold) ? 1.0 : 0.0`.
/// Plan G W2 P3 step 5: 0.5 is the SAM 2 canonical threshold; 0.55–0.65 reduces
/// background bleed on dome captures with high subject/background imbalance.
void aether_binarize_mask(
    float* mask, int32_t mask_h, int32_t mask_w, float threshold);

// ─── Scale alignment (W2 D2) ────────────────────────────────────────

/// Per-frame LSQ result: metric_depth ≈ scale · ai_depth + translation (meters).
typedef struct {
    float scale;
    float translation;
    float rmse;             ///< Root-mean-squared residual (meters).
    int32_t n_used;         ///< Anchors used in final fit (post-outlier-reject).
    int32_t n_input;        ///< Anchors caller passed in.
    int32_t ok;             ///< Non-zero if fit converged.
} aether_scale_align_result_t;

typedef struct {
    float inlier_dist_m;
    float prior_scale;
    float prior_translation;
    int32_t min_anchors;
    int32_t good_anchors;
    float min_depth_span_m;
    float good_depth_span_m;
    float good_rmse_m;
    float max_rmse_m;
    float min_inlier_ratio;
    float good_inlier_ratio;
    float translation_fit_gain;
    float max_translation_delta_m;
} aether_scale_align_options_t;

typedef struct {
    aether_scale_align_result_t raw;
    float scale;
    float translation;
    float reliability;
    float inlier_ratio;
    float ai_depth_span;
    float metric_depth_span;
    float scale_prior_weight;
    float translation_prior_weight;
    int32_t used_prior;
} aether_scale_align_adaptive_result_t;

/// Solve per-frame (scale, translation) by closed-form LSQ on N anchor pairs.
///
/// Use case: DA3 monocular depth is scale-invariant; ARKit gives sparse 3D
/// anchors with metric world positions. Project anchors → camera frame to
/// get z_metric_i; sample AI depth at projected (u, v) → z_ai_i. Pass pairs
/// to this function to recover per-frame s, t.
///
/// @param z_ai            N AI depth samples at anchor pixel coords.
/// @param z_metric        N metric depths from ARKit (meters).
/// @param n               Anchor count. Minimum 2; ideal ≥ 8 for stable fit.
/// @param outlier_thresh  If > 0, drop anchors with residual > thresh·rmse and
///                        re-fit once. Plan G suggested 2.5. Pass 0 to disable.
/// @param out_result      OUT: scale/translation/rmse/n_used/n_input/ok.
/// @return AETHER_DEPTH_TILE_OK on success (separate from out_result.ok).
int32_t aether_scale_align_lsq(
    const float* z_ai, const float* z_metric,
    int32_t n, float outlier_thresh,
    aether_scale_align_result_t* out_result);

void aether_scale_align_options_default(aether_scale_align_options_t* out_options);

/// P0/P1 adaptive alignment: robust LSQ + continuous reliability +
/// session/chunk prior blending. For global P0, pass all chunk/session pairs.
/// For P1, pass one frame's pairs and set options.prior_* to the P0 result.
int32_t aether_scale_align_adaptive(
    const float* z_ai, const float* z_metric,
    int32_t n,
    const aether_scale_align_options_t* options,
    aether_scale_align_adaptive_result_t* out_result);

// ─── Sparse-prior depth refinement (P2) ──────────────────────────────

typedef struct {
    aether_scale_align_options_t align;
    float residual_sigma_px;
    float residual_clip_m;
    float residual_gain;
    float min_metric_depth_m;
    float max_metric_depth_m;
    float conf_low;
    float conf_high;
    int32_t max_residual_points;
} aether_sparse_depth_prior_options_t;

typedef struct {
    aether_scale_align_adaptive_result_t alignment;
    int32_t sparse_input;
    int32_t sparse_used;
    float mean_abs_residual_m;
    float max_abs_residual_m;
    int32_t ok;
} aether_sparse_depth_prior_result_t;

void aether_sparse_depth_prior_options_default(
    aether_sparse_depth_prior_options_t* out_options);

/// Refine DA3 relative depth to metric depth using sparse metric anchors.
/// Sparse u/v coordinates are depth-map pixel coordinates.
int32_t aether_sparse_depth_prior_refine(
    const float* relative_depth,
    const float* conf,
    int32_t width,
    int32_t height,
    const float* sparse_u,
    const float* sparse_v,
    const float* sparse_metric_depth,
    int32_t sparse_count,
    const aether_sparse_depth_prior_options_t* options,
    float* out_metric_depth,
    aether_sparse_depth_prior_result_t* out_result);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // AETHER_DEPTH_TILE_C_H
