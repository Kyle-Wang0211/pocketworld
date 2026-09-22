// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_PLAN_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_PLAN_H_

#include <array>
#include <cstddef>
#include <cstdint>

#include "../vulkan_host/dispatch_plan.h"
#include "../include/official_dense/patch_match_abi.h"

namespace pocketworld::official_dense::vulkan::resource_arena {

inline constexpr std::size_t kModeCount = 2U;
inline constexpr std::size_t kRotationCount = 4U;

enum class ScalarType : std::uint8_t {
  kFloat32,
  kUint32,
  kInt32,
  kUint8,
};

enum class MemoryClass : std::uint8_t {
  kDeviceLocal,
  kHostUpload,
  kHostReadback,
  kHostValues,
};

enum Usage : std::uint32_t {
  kUsageNone = 0U,
  kUsageStorage = 1U << 0U,
  kUsageSampled = 1U << 1U,
  kUsageTransferSource = 1U << 2U,
  kUsageTransferDestination = 1U << 3U,
  kUsageHostValues = 1U << 4U,
};

struct AllocationPlan {
  std::uint64_t exact_bytes = 0U;
  std::uint64_t array_layers = 0U;
  ScalarType scalar_type = ScalarType::kUint8;
  MemoryClass memory_class = MemoryClass::kDeviceLocal;
  std::uint32_t usage = kUsageNone;
  // Alias identities are local to one ResourceArenaPlan. Separate image plans
  // must never be coalesced, even if their local identities happen to match.
  std::uint64_t alias_group = 0U;

  [[nodiscard]] bool present() const noexcept {
    return exact_bytes != 0U && array_layers != 0U &&
           alias_group != 0U && usage != kUsageNone;
  }
};

struct BindingPlan {
  AllocationPlan buffer;
  AllocationPlan sampled_image;
};

struct RotationPlan {
  std::uint64_t width = 0U;
  std::uint64_t height = 0U;
  std::array<BindingPlan, kBindingCount> bindings{};
};

struct ModePlan {
  std::array<RotationPlan, kRotationCount> rotations{};
  AllocationPlan reference_upload_staging;
  AllocationPlan reference_depth_upload_staging;
  AllocationPlan reference_normal_upload_staging;
  AllocationPlan source_depth_upload_staging;
  AllocationPlan source_gray_buffer_upload_staging;
  AllocationPlan source_gray_image_upload_staging;
  AllocationPlan depth_readback;
  AllocationPlan normal_readback;
  AllocationPlan mask_readback;
};

struct RotationPosePlan {
  AllocationPlan active_pose_table;
  AllocationPlan pose_upload_staging;
};

struct ResourceArenaInput {
  std::uint64_t width = 0U;
  std::uint64_t height = 0U;
  std::uint64_t source_width = 0U;
  std::uint64_t source_height = 0U;
  std::uint64_t num_sources = 0U;
  std::uint64_t workspace_max_dim = 0U;
  PlanPhase phase = PlanPhase::kFull;
  bool streamed_source_depth = false;
  bool streamed_reference_state = false;
  // [BATCH-REF 2026-08-30] 一次 dispatch 同时跑几个独立 reference。
  // 布局是「连续大 buffer + 固定 stride」(抄 cuBLAS strided-batched /
  // llama.cpp Vulkan 后端),不是 descriptor array —— 后者在 Android 上
  // 支持度只有 76.71%,与本产品「100% 跨端」的硬约束冲突。
  // stride 由 shader 从 push constant 的 width/height/num_sources 推出
  // (见 sweep_full_openmvs_pcg.comp 的 PixelIndex/GpuMatIndex/
  // WorkspaceIndex/PoseIndex/SourceLayer),所以这里**只**放大字节数与
  // 数组层数,width/height/num_sources 本身一个字都不能动。
  std::uint64_t batch_count = 1U;
};

struct ResourceArenaPlan {
  ResourceArenaInput input;
  std::array<ModePlan, kModeCount> modes{};
  std::array<RotationPosePlan, kRotationCount> poses{};
  AllocationPlan consistency_graph_values;
  std::size_t consistency_graph_value_capacity = 0U;
  // Alias groups are intentionally plan-local: first version never aliases
  // allocations belonging to different input images.
  bool alias_groups_are_plan_local = true;
};

struct ResourceArenaMemorySummary {
  std::uint64_t device_local_bytes = 0U;
  std::uint64_t host_upload_bytes = 0U;
  std::uint64_t host_readback_bytes = 0U;
  std::uint64_t host_values_bytes = 0U;
  std::uint64_t total_bytes = 0U;
  std::size_t allocation_count = 0U;
};

// Pure checked arithmetic. This function performs no Vulkan calls and does not
// modify output on failure.
[[nodiscard]] bool BuildResourceArenaPlan(
    const ResourceArenaInput &input,
    ResourceArenaPlan *output) noexcept;

// Sums each alias group exactly once, matching ResourceArenaBatch allocation
// ownership. A conflicting reuse of one alias identity fails without modifying
// output.
[[nodiscard]] bool SummarizeResourceArenaMemory(
    const ResourceArenaPlan &plan,
    ResourceArenaMemorySummary *output) noexcept;

}  // namespace pocketworld::official_dense::vulkan::resource_arena

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_PLAN_H_
