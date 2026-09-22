// Copyright (c) 2026, PocketWorld contributors.
//
// SPDX-License-Identifier: BSD-3-Clause
//
// Host-side resource ABI for the mechanical Vulkan translation of COLMAP
// 4.1.1 PatchMatch at revision a0d785fba74b2664f31edc4a29026a8b27c00f67.
// This file defines layout only. It does not change the upstream algorithm.

#ifndef POCKETWORLD_OFFICIAL_DENSE_PATCH_MATCH_ABI_H_
#define POCKETWORLD_OFFICIAL_DENSE_PATCH_MATCH_ABI_H_

#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace pocketworld::official_dense::vulkan {

// Descriptor set 0. Values are part of the shader/host ABI and must not be
// reordered or compacted.
enum class Binding : std::uint32_t {
  kDepth = 0,
  kNormal = 1,
  kCost = 2,
  kSelProb = 3,
  kPrevSelProb = 4,
  kConsistencyMask = 5,
  kRngState = 6,
  kWorkspace = 7,
  kRawRefBytes = 8,
  kFilteredRefBytes = 9,
  kRefWeightedSum = 10,
  kRefWeightedSquaredSum = 11,
  kSourceDepth = 12,
  kActivePoseTable = 13,
  kSourceGrayImage = 14,
};

inline constexpr std::uint32_t kBindingCount = 15;

// COLMAP GpuMat logical indexing. CUDA pitch is an implementation detail and
// is deliberately absent from this external ABI.
constexpr std::size_t GpuMatIndex(const std::size_t slice,
                                  const std::size_t row,
                                  const std::size_t col,
                                  const std::size_t width,
                                  const std::size_t height) noexcept {
  return slice * width * height + row * width + col;
}

inline constexpr std::size_t kNormalPlaneCount = 3;

constexpr std::size_t NormalIndex(const std::size_t component,
                                  const std::size_t row,
                                  const std::size_t col,
                                  const std::size_t width,
                                  const std::size_t height) noexcept {
  return GpuMatIndex(component, row, col, width, height);
}

constexpr std::size_t SourceIndex(const std::size_t layer,
                                  const std::size_t row,
                                  const std::size_t col,
                                  const std::size_t source_width,
                                  const std::size_t source_height) noexcept {
  return layer * source_width * source_height + row * source_width + col;
}

// Workspace is a tightly packed [2][D][N] array. It intentionally does not
// inherit GpuMat pitch.
constexpr std::size_t WorkspaceIndex(const std::size_t kind,
                                     const std::size_t col,
                                     const std::size_t source,
                                     const std::size_t workspace_max_dim,
                                     const std::size_t num_sources) noexcept {
  return kind * workspace_max_dim * num_sources + col * num_sources + source;
}

// Active-pose table layout, in floats, for each source image.
inline constexpr std::size_t kPoseFloatCount = 43;

// [BATCH-REF 2026-08-30] 每个 reference 的位姿区尾部再挂 8 个 float:
//   [0..3] = ref_k.xyzw, [4..7] = ref_inv_k.xyzw
// 为什么不放 push constant:一次 dispatch 只有一份 push constant,而实测
// 冻结场景 132 帧的**内参逐帧都不同**(132 个不同组合),深度范围也逐帧不同
// (depth_min ∈ [0.79, 3.78],depth_max ∈ [4.61, 28.36])。批处理时 N 个
// reference 共享一次 dispatch ⇒ 逐 reference 的参数必须按 RefIndex() 寻址。
// 这就是 cuBLAS strided-batched / llama.cpp 的同一条原则,只是对象从数据
// 换成了参数块。
//
// 为什么挂在位姿表尾部而不是新开一个 descriptor binding:
// descriptor 布局上挂着一整套 fail-closed 契约检查(ValidModeResources /
// 契约测试 / shader_bundle 哈希),动它的代价远大于把 stride 从
//   num_sources * 43  改成  num_sources * 43 + 8。
// sweep 只用到 ref_k / ref_inv_k 两个 vec4(12 处),depth_min/max 它根本
// 不读——那两个在非批处理的 kernel 里,那些 kernel 按 reference 逐次
// dispatch,各自带自己的 push constant,一行 shader 都不用改。
inline constexpr std::size_t kPerReferencePoseTailFloats = 8;
inline constexpr std::size_t kPoseFloatsPerReference(
    const std::size_t source_count) noexcept {
  return source_count * kPoseFloatCount + kPerReferencePoseTailFloats;
}
inline constexpr std::size_t kPoseIntrinsicsOffset = 0;
inline constexpr std::size_t kPoseRotationOffset = 4;
inline constexpr std::size_t kPoseTranslationOffset = 13;
inline constexpr std::size_t kPoseProjectionCenterOffset = 16;
inline constexpr std::size_t kPoseProjectionMatrixOffset = 19;
inline constexpr std::size_t kPoseInverseProjectionMatrixOffset = 31;

// Shared 128-byte push-constant block for the principal PatchMatch kernels.
// Fixed-width scalar fields mirror GLSL uint/int/float values exactly.
struct PatchPC {
  std::uint32_t width;
  std::uint32_t height;
  std::uint32_t num_sources;
  std::uint32_t workspace_max_dim;
  std::uint32_t source_width;
  std::uint32_t source_height;
  std::uint32_t rotation_0_to_3;
  std::uint32_t reserved;

  float ref_K_fx;
  float ref_K_cx;
  float ref_K_fy;
  float ref_K_cy;
  float ref_inv_fx;
  float ref_inv_neg_cx_fx;
  float ref_inv_fy;
  float ref_inv_neg_cy_fy;

  float perturbation;
  float depth_min;
  float depth_max;
  std::int32_t num_samples;
  float sigma_spatial;
  float sigma_color;
  float ncc_sigma;
  float min_triangulation_angle_rad;
  float incident_angle_sigma;
  float prev_sel_prob_weight;
  float geom_consistency_regularizer;
  float geom_consistency_max_cost;
  float filter_min_ncc;
  float filter_min_triangulation_angle_rad;
  std::int32_t filter_min_num_consistent;
  float filter_geom_consistency_max_cost;
};

static_assert(sizeof(std::uint32_t) == 4);
static_assert(sizeof(std::int32_t) == 4);
static_assert(sizeof(float) == 4);
static_assert(std::is_standard_layout_v<PatchPC>);
static_assert(alignof(PatchPC) == 4);
static_assert(sizeof(PatchPC) == 128);

#define PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(member, expected) \
  static_assert(offsetof(PatchPC, member) == expected)

PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(width, 0);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(height, 4);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(num_sources, 8);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(workspace_max_dim, 12);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(source_width, 16);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(source_height, 20);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(rotation_0_to_3, 24);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(reserved, 28);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_K_fx, 32);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_K_cx, 36);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_K_fy, 40);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_K_cy, 44);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_inv_fx, 48);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_inv_neg_cx_fx, 52);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_inv_fy, 56);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ref_inv_neg_cy_fy, 60);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(perturbation, 64);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(depth_min, 68);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(depth_max, 72);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(num_samples, 76);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(sigma_spatial, 80);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(sigma_color, 84);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(ncc_sigma, 88);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(min_triangulation_angle_rad, 92);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(incident_angle_sigma, 96);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(prev_sel_prob_weight, 100);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(geom_consistency_regularizer, 104);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(geom_consistency_max_cost, 108);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(filter_min_ncc, 112);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(filter_min_triangulation_angle_rad, 116);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(filter_min_num_consistent, 120);
PW_OFFICIAL_DENSE_PATCH_PC_OFFSET(filter_geom_consistency_max_cost, 124);

#undef PW_OFFICIAL_DENSE_PATCH_PC_OFFSET

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_PATCH_MATCH_ABI_H_
