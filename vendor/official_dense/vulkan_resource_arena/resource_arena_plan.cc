// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <map>
#include <utility>
#include "resource_arena_plan.h"

#include <algorithm>
#include <limits>

namespace pocketworld::official_dense::vulkan::resource_arena {
namespace {

constexpr std::uint32_t Bits(const Usage left) noexcept {
  return static_cast<std::uint32_t>(left);
}

constexpr std::uint32_t Bits(const Usage left, const Usage right) noexcept {
  return Bits(left) | Bits(right);
}

constexpr std::uint32_t Bits(const Usage first, const Usage second,
                             const Usage third) noexcept {
  return Bits(first) | Bits(second) | Bits(third);
}

bool CheckedMultiply(const std::uint64_t left, const std::uint64_t right,
                     std::uint64_t *const output) noexcept {
  if (output == nullptr ||
      (left != 0U &&
       right > std::numeric_limits<std::uint64_t>::max() / left)) {
    return false;
  }
  *output = left * right;
  return true;
}

bool CheckedAdd(const std::uint64_t left, const std::uint64_t right,
                std::uint64_t *const output) noexcept {
  if (output == nullptr ||
      right > std::numeric_limits<std::uint64_t>::max() - left) {
    return false;
  }
  *output = left + right;
  return true;
}

constexpr bool FitsSizeT(const std::uint64_t value) noexcept {
  if constexpr (sizeof(std::size_t) >= sizeof(std::uint64_t)) {
    return true;
  } else {
    return value <= static_cast<std::uint64_t>(
                        std::numeric_limits<std::size_t>::max());
  }
}

struct AliasCounter {
  std::uint64_t next = 1U;

  [[nodiscard]] std::uint64_t Take() noexcept { return next++; }
};

// [ROT-2 2026-08-30] rotation 只需要 2 份物理缓冲,不是 4 份。
//
// 官方依据(patch_match_cuda.cu:1810 PatchMatchCuda::Rotate):每次只
// new **一个**临时目标,rotate 后 swap,旧的随 unique_ptr 立刻析构 ——
//   std::unique_ptr<GpuMat<float>> rotated(new GpuMat<float>(w, h));
//   depth_map_->Rotate(rotated.get());
//   depth_map_.swap(rotated);      // 旧的析构
// ⇒ 官方峰值 = current + destination 两块。我们分配 4 块是移植时的
//   过度分配(实测每块 0.918GB,4 块 3.67GB,占单 ref 3.31GB 的绝大部分)。
//
// 安全性:运行时三处 rotation 索引全是 (rotation_before + 1) & 3
// (vulkan_runtime.cc:1082/1123/1168),只跨相邻。按 parity 分两组后:
//   0→1 读 slot0 写 slot1;1→2 读 slot1 写 slot0;
//   2→3 读 slot0 写 slot1;3→0 读 slot1 写 slot0   ⇒ 读写恒在不同 slot
// 且偶数 rotation 恒为 W×H、奇数恒为 H×W,尺寸自动对齐。
//
// 实现:同一 (binding 序号, rotation 奇偶) 复用同一个 alias_group。
// AliasKey{image, alias_group} 相同 ⇒ resource_arena.cc 的 AddPlan 去重成
// 同一块 buffer(并经 SamePlan 校验形状一致,不一致会 fail-closed)。
struct ParityAliasPool {
  AliasCounter *counter = nullptr;
  std::map<std::pair<std::size_t, std::size_t>, std::uint64_t> groups;

  // slot = binding 序号(同一 mode 内唯一),parity = rotation & 1
  [[nodiscard]] std::uint64_t Take(const std::size_t slot,
                                   const std::size_t parity) {
    const auto key = std::make_pair(slot, parity);
    const auto found = groups.find(key);
    if (found != groups.end()) return found->second;
    const std::uint64_t group = counter->Take();
    groups.emplace(key, group);
    return group;
  }
};

AllocationPlan Allocation(const std::uint64_t exact_bytes,
                          const std::uint64_t array_layers,
                          const ScalarType scalar_type,
                          const MemoryClass memory_class,
                          const std::uint32_t usage,
                          const std::uint64_t alias_group) noexcept {
  return {exact_bytes, array_layers, scalar_type, memory_class, usage,
          alias_group};
}

AllocationPlan DeviceBuffer(const std::uint64_t exact_bytes,
                            const std::uint64_t array_layers,
                            const ScalarType scalar_type,
                            const std::uint32_t usage,
                            AliasCounter *const aliases) noexcept {
  return Allocation(exact_bytes, array_layers, scalar_type,
                    MemoryClass::kDeviceLocal, usage, aliases->Take());
}

// [ROT-2] 显式指定 alias_group 的重载,供 rotation 按 parity 复用。
AllocationPlan DeviceBufferAliased(const std::uint64_t exact_bytes,
                                   const std::uint64_t array_layers,
                                   const ScalarType scalar_type,
                                   const std::uint32_t usage,
                                   const std::uint64_t alias_group) noexcept {
  return Allocation(exact_bytes, array_layers, scalar_type,
                    MemoryClass::kDeviceLocal, usage, alias_group);
}

AllocationPlan UploadBuffer(const std::uint64_t exact_bytes,
                            const ScalarType scalar_type,
                            AliasCounter *const aliases) noexcept {
  return Allocation(exact_bytes, 1U, scalar_type, MemoryClass::kHostUpload,
                    Bits(kUsageTransferSource), aliases->Take());
}

AllocationPlan ReadbackBuffer(const std::uint64_t exact_bytes,
                              const std::uint64_t array_layers,
                              const ScalarType scalar_type,
                              AliasCounter *const aliases) noexcept {
  return Allocation(exact_bytes, array_layers, scalar_type,
                    MemoryClass::kHostReadback,
                    Bits(kUsageTransferDestination), aliases->Take());
}

}  // namespace

bool BuildResourceArenaPlan(const ResourceArenaInput &input,
                            ResourceArenaPlan *const output) noexcept {
  if (output == nullptr || input.width == 0U || input.height == 0U ||
      input.source_width == 0U || input.source_height == 0U ||
      input.num_sources == 0U || input.workspace_max_dim == 0U ||
      input.batch_count == 0U ||
      input.workspace_max_dim < std::max(input.width, input.height) ||
      (input.phase == PlanPhase::kPhotometricOnly &&
       (input.streamed_source_depth || input.streamed_reference_state)) ||
      (input.phase == PlanPhase::kFull && input.streamed_reference_state) ||
      (input.phase == PlanPhase::kGeometricOnly &&
       (!input.streamed_source_depth || !input.streamed_reference_state))) {
    return false;
  }

  std::uint64_t pixels = 0U;
  std::uint64_t source_pixels = 0U;
  std::uint64_t layered_pixels = 0U;
  std::uint64_t graph_stride = 0U;
  std::uint64_t graph_values = 0U;
  if (!CheckedMultiply(input.width, input.height, &pixels) ||
      !CheckedMultiply(input.source_width, input.source_height,
                       &source_pixels) ||
      !CheckedMultiply(source_pixels, input.num_sources, &layered_pixels) ||
      !CheckedAdd(input.num_sources, 3U, &graph_stride) ||
      !CheckedMultiply(pixels, graph_stride, &graph_values) ||
      graph_values > std::numeric_limits<std::size_t>::max()) {
    return false;
  }

  std::uint64_t bytes_4p = 0U;
  std::uint64_t bytes_24p = 0U;
  std::uint64_t bytes_12p = 0U;
  std::uint64_t bytes_4np = 0U;
  std::uint64_t bytes_8dn = 0U;
  std::uint64_t bytes_4nsp = 0U;
  std::uint64_t bytes_172n = 0U;
  std::uint64_t graph_bytes = 0U;
  std::uint64_t workspace_elements = 0U;
  if (!CheckedMultiply(pixels, 4U, &bytes_4p) ||
      !CheckedMultiply(pixels, 24U, &bytes_24p) ||
      !CheckedMultiply(pixels, 12U, &bytes_12p) ||
      !CheckedMultiply(pixels, input.num_sources, &bytes_4np) ||
      !CheckedMultiply(bytes_4np, 4U, &bytes_4np) ||
      !CheckedMultiply(input.workspace_max_dim, input.num_sources,
                       &workspace_elements) ||
      !CheckedMultiply(workspace_elements, 8U, &bytes_8dn) ||
      !CheckedMultiply(layered_pixels, 4U, &bytes_4nsp) ||
      // [BATCH-REF] 每 reference 的位姿区 = num_sources*43 + 8 个 float,
      // 尾部 8 个是 ref_k / ref_inv_k(见 patch_match_abi.h 的说明)。
      !CheckedMultiply(input.num_sources, 172U, &bytes_172n) ||
      !CheckedAdd(bytes_172n,
                  static_cast<std::uint64_t>(kPerReferencePoseTailFloats) * 4U,
                  &bytes_172n) ||
      !CheckedMultiply(graph_values, 4U, &graph_bytes) ||
      !FitsSizeT(pixels) || !FitsSizeT(source_pixels) ||
      !FitsSizeT(layered_pixels) || !FitsSizeT(bytes_4p) ||
      !FitsSizeT(bytes_24p) ||
      !FitsSizeT(bytes_12p) || !FitsSizeT(bytes_4np) ||
      !FitsSizeT(bytes_8dn) || !FitsSizeT(bytes_4nsp) ||
      !FitsSizeT(bytes_172n) || !FitsSizeT(graph_bytes)) {
    return false;
  }

  // [BATCH-REF] 把「每 reference 一份」的量整体乘以 batch_count。
  // 逐条对应 shader 里的索引函数:
  //   bytes_4p / bytes_12p / bytes_24p ← PixelIndex()  : ref*W*H + ...
  //   bytes_4np                        ← GpuMatIndex() : ref*S*W*H + ...
  //   bytes_8dn                        ← WorkspaceIndex(): ref*2*D*S + ...
  //   bytes_172n                       ← PoseIndex()   : (ref*S+s)*43 + ...
  //   bytes_4nsp / layered_pixels      ← SourceLayer() : ref*S + s
  //   layers_n                         ← 纹理数组层数 = ref*S + s 的上界
  // graph_* 只在 geometric 用,同样按 reference 分片。
  const std::uint64_t batch = input.batch_count;
  std::uint64_t layers_n = 0U;
  // [BATCH-REF] 非「按源分层」的 binding 也必须把层数乘以 batch,否则
  // buffer 已经 N× 大、array_layers 却还是 1/3/6 ⇒
  //   · plane_bytes = range / array_layers 会算成 N 个 ref 的总量;
  //   · rotate 的 z 维 = array_layers 只会转到 ref 0 那一份。
  // 乘上去之后「每层 = 每 ref 的一个平面」这条不变量对所有 binding 成立。
  const std::uint64_t layers_1 = batch;
  const std::uint64_t layers_3 = 3U * batch;
  const std::uint64_t layers_6 = 6U * batch;
  std::uint64_t batched_graph_values = 0U;
  if (!CheckedMultiply(bytes_4p, batch, &bytes_4p) ||
      !CheckedMultiply(bytes_24p, batch, &bytes_24p) ||
      !CheckedMultiply(bytes_12p, batch, &bytes_12p) ||
      !CheckedMultiply(bytes_4np, batch, &bytes_4np) ||
      !CheckedMultiply(bytes_8dn, batch, &bytes_8dn) ||
      !CheckedMultiply(bytes_4nsp, batch, &bytes_4nsp) ||
      !CheckedMultiply(bytes_172n, batch, &bytes_172n) ||
      !CheckedMultiply(layered_pixels, batch, &layered_pixels) ||
      !CheckedMultiply(graph_bytes, batch, &graph_bytes) ||
      !CheckedMultiply(graph_values, batch, &batched_graph_values) ||
      !CheckedMultiply(input.num_sources, batch, &layers_n) ||
      !FitsSizeT(layered_pixels) || !FitsSizeT(bytes_4p) ||
      !FitsSizeT(bytes_24p) || !FitsSizeT(bytes_12p) ||
      !FitsSizeT(bytes_4np) || !FitsSizeT(bytes_8dn) ||
      !FitsSizeT(bytes_4nsp) || !FitsSizeT(bytes_172n) ||
      !FitsSizeT(graph_bytes) || !FitsSizeT(layers_n) ||
      batched_graph_values > std::numeric_limits<std::size_t>::max()) {
    return false;
  }

  ResourceArenaPlan candidate;
  candidate.input = input;
  AliasCounter aliases;

  // Immutable, per-image inputs. Their aliases are shared only inside this
  // plan; separate BuildResourceArenaPlan calls remain distinct arenas.
  const AllocationPlan reference = DeviceBuffer(
      bytes_4p, layers_1, ScalarType::kUint32,
      Bits(kUsageStorage, kUsageTransferDestination), &aliases);
  // The official PatchMatch descriptor layout always includes the source-depth
  // sampler.  A photometric-only pass does not upload or sample its contents,
  // but Vulkan still requires a valid image view and sampler to be bound for
  // the declared descriptor.  Keep this small immutable binding allocation;
  // phase-aware planning eliminates the much larger geometric state instead.
  const AllocationPlan source_depth =
      Allocation(bytes_4nsp, layers_n, ScalarType::kFloat32,
                 MemoryClass::kDeviceLocal,
                 Bits(kUsageSampled, kUsageTransferDestination),
                 aliases.Take());
  const AllocationPlan source_gray_buffer = DeviceBuffer(
      bytes_4nsp, layers_n, ScalarType::kUint32,
      Bits(kUsageStorage, kUsageTransferDestination), &aliases);
  const AllocationPlan source_gray_image = Allocation(
      layered_pixels, layers_n, ScalarType::kUint8,
      MemoryClass::kDeviceLocal,
      Bits(kUsageSampled, kUsageTransferDestination), aliases.Take());
  const AllocationPlan reference_staging =
      UploadBuffer(bytes_4p, ScalarType::kUint32, &aliases);
  const AllocationPlan reference_depth_staging =
      UploadBuffer(bytes_4p, ScalarType::kFloat32, &aliases);
  const AllocationPlan reference_normal_staging =
      UploadBuffer(bytes_12p, ScalarType::kFloat32, &aliases);
  const AllocationPlan source_depth_staging =
      UploadBuffer(bytes_4nsp, ScalarType::kFloat32, &aliases);
  const AllocationPlan source_gray_buffer_staging =
      UploadBuffer(bytes_4nsp, ScalarType::kUint32, &aliases);
  const AllocationPlan source_gray_image_staging =
      UploadBuffer(layered_pixels, ScalarType::kUint8, &aliases);

  std::array<AllocationPlan, kRotationCount> active_poses{};
  for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
    active_poses[rotation] = DeviceBuffer(
        bytes_172n, layers_1, ScalarType::kFloat32,
        Bits(kUsageStorage, kUsageTransferDestination), &aliases);
    candidate.poses[rotation].active_pose_table = active_poses[rotation];
    candidate.poses[rotation].pose_upload_staging =
        UploadBuffer(bytes_172n, ScalarType::kFloat32, &aliases);
  }

  for (std::size_t mode = 0U; mode < kModeCount; ++mode) {
    const bool enabled =
        input.phase == PlanPhase::kFull ||
        (input.phase == PlanPhase::kPhotometricOnly && mode == 0U) ||
        (input.phase == PlanPhase::kGeometricOnly && mode == 1U);
    if (!enabled) continue;
    ModePlan &mode_plan = candidate.modes[mode];
    mode_plan.reference_upload_staging = reference_staging;
    if (mode == 1U && input.streamed_reference_state) {
      mode_plan.reference_depth_upload_staging = reference_depth_staging;
      mode_plan.reference_normal_upload_staging = reference_normal_staging;
    }
    if (mode == 1U && input.streamed_source_depth) {
      mode_plan.source_depth_upload_staging = source_depth_staging;
    }
    mode_plan.source_gray_buffer_upload_staging =
        source_gray_buffer_staging;
    mode_plan.source_gray_image_upload_staging = source_gray_image_staging;
    mode_plan.depth_readback =
        ReadbackBuffer(bytes_4p, layers_1, ScalarType::kFloat32, &aliases);
    mode_plan.normal_readback =
        ReadbackBuffer(bytes_12p, layers_3, ScalarType::kFloat32, &aliases);
    mode_plan.mask_readback = ReadbackBuffer(
        bytes_4np, layers_n, ScalarType::kUint32, &aliases);

    const AllocationPlan workspace = DeviceBuffer(
        bytes_8dn, layers_1, ScalarType::kFloat32, Bits(kUsageStorage), &aliases);
    // [ROT-2] 每个 mode 一个池:同 (binding, rotation 奇偶) 复用同一块。
    ParityAliasPool rot_pool{&aliases, {}};
    for (std::size_t rotation = 0U; rotation < kRotationCount; ++rotation) {
      RotationPlan &rotation_plan = mode_plan.rotations[rotation];
      const bool swapped = (rotation & 1U) != 0U;
      rotation_plan.width = swapped ? input.height : input.width;
      rotation_plan.height = swapped ? input.width : input.height;
      // [ROT-2] rotation 2/3 复用 0/1 的物理缓冲(同奇偶 ⇒ 同尺寸)。
      const std::size_t parity = static_cast<std::size_t>(rotation & 1U);
      auto &binding = rotation_plan.bindings;
      binding[0].buffer = DeviceBufferAliased(
          bytes_4p, layers_1, ScalarType::kFloat32,
          Bits(kUsageStorage, kUsageTransferSource,
               kUsageTransferDestination), rot_pool.Take(0U, parity));
      binding[1].buffer = DeviceBufferAliased(
          bytes_12p, layers_3, ScalarType::kFloat32,
          Bits(kUsageStorage, kUsageTransferSource,
               kUsageTransferDestination), rot_pool.Take(1U, parity));
      binding[2].buffer = DeviceBufferAliased(bytes_4np, layers_n,
                                       ScalarType::kFloat32,
                                       Bits(kUsageStorage), rot_pool.Take(2U, parity));
      binding[3].buffer = DeviceBufferAliased(bytes_4np, layers_n,
                                       ScalarType::kFloat32,
                                       Bits(kUsageStorage), rot_pool.Take(3U, parity));
      binding[4].buffer = DeviceBufferAliased(
          bytes_4np, layers_n, ScalarType::kFloat32,
          Bits(kUsageStorage, kUsageTransferDestination), rot_pool.Take(4U, parity));
      binding[5].buffer = DeviceBufferAliased(
          bytes_4np, layers_n, ScalarType::kUint32,
          Bits(kUsageStorage, kUsageTransferSource,
               kUsageTransferDestination), rot_pool.Take(5U, parity));
      binding[6].buffer = DeviceBufferAliased(
          bytes_24p, layers_6, ScalarType::kUint32,
          Bits(kUsageStorage, kUsageTransferSource,
               kUsageTransferDestination), rot_pool.Take(6U, parity));
      binding[7].buffer = workspace;
      binding[8].buffer = reference;
      binding[9].buffer = DeviceBufferAliased(
          bytes_4p, layers_1, ScalarType::kUint32,
          Bits(kUsageStorage, kUsageTransferSource,
               kUsageTransferDestination), rot_pool.Take(9U, parity));
      binding[10].buffer = DeviceBufferAliased(bytes_4p, layers_1, ScalarType::kFloat32,
                                        Bits(kUsageStorage), rot_pool.Take(10U, parity));
      binding[11].buffer = DeviceBufferAliased(bytes_4p, layers_1, ScalarType::kFloat32,
                                        Bits(kUsageStorage), rot_pool.Take(11U, parity));
      binding[12].sampled_image = source_depth;
      binding[13].buffer = active_poses[rotation];
      binding[14].buffer = source_gray_buffer;
      binding[14].sampled_image = source_gray_image;
    }
  }

  candidate.consistency_graph_values = Allocation(
      graph_bytes, layers_1, ScalarType::kInt32, MemoryClass::kHostValues,
      Bits(kUsageHostValues), aliases.Take());
  candidate.consistency_graph_value_capacity =
      static_cast<std::size_t>(batched_graph_values);
  *output = candidate;
  return true;
}

bool SummarizeResourceArenaMemory(
    const ResourceArenaPlan &plan,
    ResourceArenaMemorySummary *const output) noexcept {
  if (output == nullptr || !plan.alias_groups_are_plan_local) return false;

  constexpr std::size_t kMaximumVisitedAllocations =
      kModeCount * (kRotationCount * kBindingCount * 2U + 9U) +
      kRotationCount * 2U + 1U;
  std::array<AllocationPlan, kMaximumVisitedAllocations> unique{};
  ResourceArenaMemorySummary candidate;

  const auto add = [&](const AllocationPlan &allocation) -> bool {
    if (!allocation.present()) return true;
    for (std::size_t index = 0U; index < candidate.allocation_count; ++index) {
      if (unique[index].alias_group != allocation.alias_group) continue;
      return unique[index].exact_bytes == allocation.exact_bytes &&
             unique[index].array_layers == allocation.array_layers &&
             unique[index].scalar_type == allocation.scalar_type &&
             unique[index].memory_class == allocation.memory_class &&
             unique[index].usage == allocation.usage;
    }
    if (candidate.allocation_count >= unique.size()) return false;

    std::uint64_t *class_total = nullptr;
    switch (allocation.memory_class) {
      case MemoryClass::kDeviceLocal:
        class_total = &candidate.device_local_bytes;
        break;
      case MemoryClass::kHostUpload:
        class_total = &candidate.host_upload_bytes;
        break;
      case MemoryClass::kHostReadback:
        class_total = &candidate.host_readback_bytes;
        break;
      case MemoryClass::kHostValues:
        class_total = &candidate.host_values_bytes;
        break;
    }
    if (class_total == nullptr ||
        !CheckedAdd(*class_total, allocation.exact_bytes, class_total) ||
        !CheckedAdd(candidate.total_bytes, allocation.exact_bytes,
                    &candidate.total_bytes)) {
      return false;
    }
    unique[candidate.allocation_count] = allocation;
    ++candidate.allocation_count;
    return true;
  };

  for (const ModePlan &mode : plan.modes) {
    for (const RotationPlan &rotation : mode.rotations) {
      for (const BindingPlan &binding : rotation.bindings) {
        if (!add(binding.buffer) || !add(binding.sampled_image)) return false;
      }
    }
    if (!add(mode.reference_upload_staging) ||
        !add(mode.reference_depth_upload_staging) ||
        !add(mode.reference_normal_upload_staging) ||
        !add(mode.source_depth_upload_staging) ||
        !add(mode.source_gray_buffer_upload_staging) ||
        !add(mode.source_gray_image_upload_staging) ||
        !add(mode.depth_readback) || !add(mode.normal_readback) ||
        !add(mode.mask_readback)) {
      return false;
    }
  }
  for (const RotationPosePlan &pose : plan.poses) {
    if (!add(pose.active_pose_table) || !add(pose.pose_upload_staging)) {
      return false;
    }
  }
  if (!add(plan.consistency_graph_values)) return false;

  *output = candidate;
  return true;
}

}  // namespace pocketworld::official_dense::vulkan::resource_arena
