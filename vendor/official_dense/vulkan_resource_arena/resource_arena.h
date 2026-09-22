// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_H_

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "resource_arena_plan.h"
#include "../vulkan_host/vulkan_host.h"
#include "../vulkan_runtime/vulkan_runtime.h"

namespace pocketworld::official_dense::vulkan::resource_arena {

// Provider results deliberately carry an opaque lifetime token. The production
// adapter stores the VulkanHost allocation in that token; deterministic tests
// can supply the same ownership contract without constructing Vulkan handles.
struct ProviderBufferAllocation {
  std::uint64_t buffer_handle = 0U;
  std::uint64_t byte_count = 0U;
  void *mapped_pointer = nullptr;
  bool host_coherent = false;
  std::shared_ptr<void> lifetime;
};

struct ProviderSampledImageAllocation {
  std::uint64_t image_handle = 0U;
  std::uint64_t image_view_handle = 0U;
  std::uint64_t sampler_handle = 0U;
  SampledImageSpec spec{};
  std::shared_ptr<void> lifetime;
};

class ResourceAllocationProvider {
 public:
  virtual ~ResourceAllocationProvider() = default;
  [[nodiscard]] virtual bool CreateBufferAllocation(
      const BufferAllocationSpec &spec,
      ProviderBufferAllocation *out,
      std::string *detail) noexcept = 0;
  [[nodiscard]] virtual bool CreateSampledImageAllocation(
      const SampledImageSpec &spec,
      ProviderSampledImageAllocation *out,
      std::string *detail) noexcept = 0;
};

// Thin mechanical adapter. It adds no allocation policy and submits no work.
class VulkanHostResourceAllocationProvider final
    : public ResourceAllocationProvider {
 public:
  explicit VulkanHostResourceAllocationProvider(VulkanHost *host) noexcept;
  [[nodiscard]] bool CreateBufferAllocation(
      const BufferAllocationSpec &spec,
      ProviderBufferAllocation *out,
      std::string *detail) noexcept override;
  [[nodiscard]] bool CreateSampledImageAllocation(
      const SampledImageSpec &spec,
      ProviderSampledImageAllocation *out,
      std::string *detail) noexcept override;

 private:
  VulkanHost *host_ = nullptr;
};

struct SourceResourceRef {
  std::uint32_t image_slot = UINT32_MAX;
  std::int32_t image_index = -1;
  std::uint32_t width = 0U;
  std::uint32_t height = 0U;
};

struct ResourceArenaImageInput {
  std::int32_t image_index = -1;
  ResourceArenaInput resources{};
  runtime::CalibrationBuildInput calibration{};
  // [BATCH-REF 2026-08-30] batch_count > 1 时,逐 reference 的标定。
  // 为空表示 N 个槽装的是同一个 reference(把 calibration 复制 N 份),
  // 这是验收用的形态;真跑 N 份不同输入时必须提供,长度 = batch_count。
  // 各数组(reference_u32 / source_gray_*)也随之变成 N 份首尾相接,
  // 顺序必须与 shader 的 stride 约定一致:
  //   reference_u32   : [ref0 的 W*H][ref1 的 W*H]...
  //   source_gray_*   : [ref0 的 10 个源][ref1 的 10 个源]...
  const runtime::CalibrationBuildInput *batch_calibrations = nullptr;
  std::size_t batch_calibration_count = 0U;
  // [BATCH-REF] N 个 reference 各自的源清单,长度 = num_sources * batch_count,
  // 顺序 [ref0 的 S 个][ref1 的 S 个]...(与 shader 的 SourceLayer 一致)。
  // 为空表示 N 个槽装同一个 reference(把 sources 复制 N 份)。
  // 它同时喂两处:一致性图的源索引表,和 source depth 的逐层拷贝清单。
  const SourceResourceRef *batch_sources = nullptr;
  std::size_t batch_source_count = 0U;

  const std::uint32_t *reference_u32 = nullptr;
  std::size_t reference_u32_count = 0U;
  const std::uint32_t *source_gray_u32 = nullptr;
  std::size_t source_gray_u32_count = 0U;
  const std::uint8_t *source_gray_u8 = nullptr;
  std::size_t source_gray_u8_count = 0U;
  // Optional official geometric-pass input, laid out as one tightly packed
  // float depth plane per selected source in source order. This is the
  // streaming equivalent of COLMAP reading previously written photometric
  // depth maps before the geometric pass.
  const float *source_depth_f32 = nullptr;
  std::size_t source_depth_f32_count = 0U;
  // Exact photometric result for the active reference. COLMAP loads these two
  // maps into the geometric PatchMatch workspace before ComputeInitialCost.
  const float *reference_depth_f32 = nullptr;
  std::size_t reference_depth_f32_count = 0U;
  const float *reference_normal_f32 = nullptr;
  std::size_t reference_normal_f32_count = 0U;

  std::uint64_t reference_content_identity = 0U;
  std::uint64_t reference_depth_content_identity = 0U;
  std::uint64_t reference_normal_content_identity = 0U;
  std::uint64_t source_depth_content_identity = 0U;
  std::uint64_t source_gray_content_identity = 0U;
  std::array<std::uint64_t, kRotationCount> pose_content_identities{};

  const SourceResourceRef *sources = nullptr;
  std::size_t source_count = 0U;
};

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

// Benchmark-only views of host-coherent output allocations after the native
// queue has completed. Production builds do not expose pointers to internals.
struct DiagnosticImageReadback {
  std::uint32_t width = 0U;
  std::uint32_t height = 0U;
  std::uint32_t source_count = 0U;
  const float *photometric_depth = nullptr;
  const float *photometric_normal = nullptr;
  const float *geometric_depth = nullptr;
  const float *geometric_normal = nullptr;
  const std::uint32_t *geometric_mask = nullptr;
  const std::int32_t *consistency_graph_values = nullptr;
  std::size_t consistency_graph_value_count = 0U;
  // [BATCH-REF 2026-08-31] 批处理时逐 reference 的一致性图:
  // 第 r 份写在 consistency_graph_values + r * value_capacity_per_reference,
  // 长度是 value_counts[r]。batch_count == 1 时与上面两个字段等价。
  const std::size_t *consistency_graph_value_counts = nullptr;
  std::size_t consistency_graph_batch_count = 0U;
  std::size_t consistency_graph_value_capacity_per_reference = 0U;
};

#endif

class ResourceArenaBatch final {
 public:
  ResourceArenaBatch() noexcept;
  ResourceArenaBatch(const ResourceArenaBatch &) = delete;
  ResourceArenaBatch &operator=(const ResourceArenaBatch &) = delete;
  ResourceArenaBatch(ResourceArenaBatch &&) noexcept;
  ResourceArenaBatch &operator=(ResourceArenaBatch &&) noexcept;
  ~ResourceArenaBatch();

  [[nodiscard]] const runtime::ImageResources *images() const noexcept;
  [[nodiscard]] std::size_t image_count() const noexcept;
  [[nodiscard]] bool empty() const noexcept;
  void Reset() noexcept;

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

  // Valid only while this batch remains alive and after diagnostic execution
  // has returned successfully from its queue wait.
  [[nodiscard]] bool DiagnosticReadbackForImage(
      std::size_t image_slot, DiagnosticImageReadback *out) const noexcept;

#endif

 private:
  struct Impl;
  explicit ResourceArenaBatch(std::unique_ptr<Impl> impl) noexcept;
  friend bool BuildResourceArenaBatch(
      const ResourceArenaImageInput *, std::size_t,
      ResourceAllocationProvider *, ResourceArenaBatch *,
      std::string *) noexcept;
  std::unique_ptr<Impl> impl_;
};

// Builds a complete batch transactionally. No upload command or queue submit is
// performed here. The output is unchanged on every failure path.
[[nodiscard]] bool BuildResourceArenaBatch(
    const ResourceArenaImageInput *inputs,
    std::size_t input_count,
    ResourceAllocationProvider *provider,
    ResourceArenaBatch *out,
    std::string *detail) noexcept;

}  // namespace pocketworld::official_dense::vulkan::resource_arena

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_RESOURCE_ARENA_RESOURCE_ARENA_H_
