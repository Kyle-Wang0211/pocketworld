#include "resource_arena_plan.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace arena = pocketworld::official_dense::vulkan::resource_arena;

namespace {

int Require(const bool condition, const int code) {
  return condition ? 0 : code;
}

constexpr std::uint32_t Usage(const arena::Usage first) {
  return static_cast<std::uint32_t>(first);
}

constexpr std::uint32_t Usage(const arena::Usage first,
                              const arena::Usage second) {
  return Usage(first) | Usage(second);
}

constexpr std::uint32_t Usage(const arena::Usage first,
                              const arena::Usage second,
                              const arena::Usage third) {
  return Usage(first) | Usage(second) | Usage(third);
}

arena::AllocationPlan Expected(const std::uint64_t bytes,
                               const std::uint64_t layers,
                               const arena::ScalarType scalar,
                               const arena::MemoryClass memory,
                               const std::uint32_t usage) {
  // One is only a present marker. Alias identities are verified separately.
  return {bytes, layers, scalar, memory, usage, 1U};
}

bool SameAllocation(const arena::AllocationPlan &left,
                    const arena::AllocationPlan &right) {
  return left.exact_bytes == right.exact_bytes &&
         left.array_layers == right.array_layers &&
         left.scalar_type == right.scalar_type &&
         left.memory_class == right.memory_class &&
         left.usage == right.usage &&
         left.alias_group == right.alias_group;
}

bool MatchesTuple(const arena::AllocationPlan &actual,
                  const arena::AllocationPlan &expected) {
  if (!expected.present()) return SameAllocation(actual, expected);
  return actual.exact_bytes == expected.exact_bytes &&
         actual.array_layers == expected.array_layers &&
         actual.scalar_type == expected.scalar_type &&
         actual.memory_class == expected.memory_class &&
         actual.usage == expected.usage && actual.alias_group != 0U;
}

bool SameBinding(const arena::BindingPlan &left,
                 const arena::BindingPlan &right) {
  return SameAllocation(left.buffer, right.buffer) &&
         SameAllocation(left.sampled_image, right.sampled_image);
}

bool SameInput(const arena::ResourceArenaInput &left,
               const arena::ResourceArenaInput &right) {
  return left.width == right.width && left.height == right.height &&
         left.source_width == right.source_width &&
         left.source_height == right.source_height &&
         left.num_sources == right.num_sources &&
         left.workspace_max_dim == right.workspace_max_dim &&
         left.phase == right.phase &&
         left.streamed_source_depth == right.streamed_source_depth &&
         left.streamed_reference_state == right.streamed_reference_state;
}

bool SameRotation(const arena::RotationPlan &left,
                  const arena::RotationPlan &right) {
  if (left.width != right.width || left.height != right.height) return false;
  for (std::size_t binding = 0U; binding < left.bindings.size(); ++binding) {
    if (!SameBinding(left.bindings[binding], right.bindings[binding])) {
      return false;
    }
  }
  return true;
}

bool SameMode(const arena::ModePlan &left, const arena::ModePlan &right) {
  for (std::size_t rotation = 0U; rotation < left.rotations.size(); ++rotation) {
    if (!SameRotation(left.rotations[rotation], right.rotations[rotation])) {
      return false;
    }
  }
  return SameAllocation(left.reference_upload_staging,
                        right.reference_upload_staging) &&
         SameAllocation(left.reference_depth_upload_staging,
                        right.reference_depth_upload_staging) &&
         SameAllocation(left.reference_normal_upload_staging,
                        right.reference_normal_upload_staging) &&
         SameAllocation(left.source_depth_upload_staging,
                        right.source_depth_upload_staging) &&
         SameAllocation(left.source_gray_buffer_upload_staging,
                        right.source_gray_buffer_upload_staging) &&
         SameAllocation(left.source_gray_image_upload_staging,
                        right.source_gray_image_upload_staging) &&
         SameAllocation(left.depth_readback, right.depth_readback) &&
         SameAllocation(left.normal_readback, right.normal_readback) &&
         SameAllocation(left.mask_readback, right.mask_readback);
}

bool SamePlan(const arena::ResourceArenaPlan &left,
              const arena::ResourceArenaPlan &right) {
  if (!SameInput(left.input, right.input) ||
      left.consistency_graph_value_capacity !=
          right.consistency_graph_value_capacity ||
      left.alias_groups_are_plan_local != right.alias_groups_are_plan_local ||
      !SameAllocation(left.consistency_graph_values,
                      right.consistency_graph_values)) {
    return false;
  }
  for (std::size_t mode = 0U; mode < left.modes.size(); ++mode) {
    if (!SameMode(left.modes[mode], right.modes[mode])) return false;
  }
  for (std::size_t rotation = 0U; rotation < left.poses.size(); ++rotation) {
    if (!SameAllocation(left.poses[rotation].active_pose_table,
                        right.poses[rotation].active_pose_table) ||
        !SameAllocation(left.poses[rotation].pose_upload_staging,
                        right.poses[rotation].pose_upload_staging)) {
      return false;
    }
  }
  return true;
}

}  // namespace

int main() {
  const arena::ResourceArenaInput input{64U, 48U, 80U, 61U, 2U, 64U};
  arena::ResourceArenaPlan plan;
  if (int e = Require(arena::BuildResourceArenaPlan(input, &plan), 1)) return e;
  constexpr std::uint64_t p = 64U * 48U;
  constexpr std::uint64_t sp = 80U * 61U;
  constexpr std::uint64_t n = 2U;
  constexpr std::uint32_t storage = Usage(arena::kUsageStorage);
  constexpr std::uint32_t storage_src_dst =
      Usage(arena::kUsageStorage, arena::kUsageTransferSource,
            arena::kUsageTransferDestination);
  constexpr std::uint32_t storage_dst =
      Usage(arena::kUsageStorage, arena::kUsageTransferDestination);
  constexpr std::uint32_t sampled_dst =
      Usage(arena::kUsageSampled, arena::kUsageTransferDestination);

  if (int e = Require(plan.modes[0].rotations[0].width == 64U &&
                          plan.modes[0].rotations[0].height == 48U &&
                          plan.modes[0].rotations[1].width == 48U &&
                          plan.modes[0].rotations[1].height == 64U &&
                          plan.modes[1].rotations[3].width == 48U &&
                          plan.modes[1].rotations[3].height == 64U,
                      2)) {
    return e;
  }

  const std::array<arena::BindingPlan,
                   pocketworld::official_dense::vulkan::kBindingCount>
      expected = {{
      {Expected(4U * p, 1U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage_src_dst), {}},
      {Expected(12U * p, 3U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage_src_dst), {}},
      {Expected(4U * n * p, n, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage), {}},
      {Expected(4U * n * p, n, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage), {}},
      {Expected(4U * n * p, n, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage_dst), {}},
      {Expected(4U * n * p, n, arena::ScalarType::kUint32,
                arena::MemoryClass::kDeviceLocal, storage_src_dst), {}},
      {Expected(24U * p, 6U, arena::ScalarType::kUint32,
                arena::MemoryClass::kDeviceLocal, storage_src_dst), {}},
      {Expected(8U * 64U * n, 1U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage), {}},
      {Expected(4U * p, 1U, arena::ScalarType::kUint32,
                arena::MemoryClass::kDeviceLocal, storage_dst), {}},
      {Expected(4U * p, 1U, arena::ScalarType::kUint32,
                arena::MemoryClass::kDeviceLocal, storage_src_dst), {}},
      {Expected(4U * p, 1U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage), {}},
      {Expected(4U * p, 1U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage), {}},
      {{}, Expected(4U * n * sp, n, arena::ScalarType::kFloat32,
                    arena::MemoryClass::kDeviceLocal, sampled_dst)},
      {Expected(172U * n, 1U, arena::ScalarType::kFloat32,
                arena::MemoryClass::kDeviceLocal, storage_dst), {}},
      {Expected(4U * n * sp, n, arena::ScalarType::kUint32,
                arena::MemoryClass::kDeviceLocal, storage_dst),
       Expected(n * sp, n, arena::ScalarType::kUint8,
                arena::MemoryClass::kDeviceLocal, sampled_dst)},
  }};
  for (std::size_t mode = 0U; mode < 2U; ++mode) {
    for (std::size_t rotation = 0U; rotation < 4U; ++rotation) {
      const auto &bindings = plan.modes[mode].rotations[rotation].bindings;
      for (std::size_t binding = 0U; binding < expected.size(); ++binding) {
        if (int e = Require(
                MatchesTuple(bindings[binding].buffer,
                             expected[binding].buffer) &&
                    MatchesTuple(bindings[binding].sampled_image,
                                 expected[binding].sampled_image),
                3)) {
          return e;
        }
      }
    }
  }

  for (const std::size_t binding :
       {0U, 1U, 2U, 3U, 4U, 5U, 6U, 9U, 10U, 11U}) {
    for (std::size_t allocation = 0U; allocation < 8U; ++allocation) {
      const std::size_t mode = allocation / 4U;
      const std::size_t rotation = allocation % 4U;
      const auto alias = plan.modes[mode].rotations[rotation]
                             .bindings[binding].buffer.alias_group;
      for (std::size_t other = allocation + 1U; other < 8U; ++other) {
        const std::size_t other_mode = other / 4U;
        const std::size_t other_rotation = other % 4U;
        if (int e = Require(
                alias != plan.modes[other_mode].rotations[other_rotation]
                             .bindings[binding].buffer.alias_group,
                4)) {
          return e;
        }
      }
    }
  }

  const auto &first = plan.modes[0].rotations[0].bindings;
  for (std::size_t mode = 0U; mode < 2U; ++mode) {
    for (std::size_t rotation = 0U; rotation < 4U; ++rotation) {
      const auto &binding = plan.modes[mode].rotations[rotation].bindings;
      if (int e = Require(
              binding[7].buffer.alias_group ==
                      plan.modes[mode].rotations[0]
                          .bindings[7].buffer.alias_group &&
                  binding[8].buffer.alias_group == first[8].buffer.alias_group &&
                  binding[12].sampled_image.alias_group ==
                      first[12].sampled_image.alias_group &&
                  binding[13].buffer.alias_group ==
                      plan.modes[0].rotations[rotation]
                          .bindings[13].buffer.alias_group &&
                  binding[14].buffer.alias_group ==
                      first[14].buffer.alias_group &&
                  binding[14].sampled_image.alias_group ==
                      first[14].sampled_image.alias_group,
              6)) {
        return e;
      }
    }
  }
  if (int e = Require(
          plan.modes[0].rotations[0].bindings[7].buffer.alias_group !=
                  plan.modes[1].rotations[0]
                      .bindings[7].buffer.alias_group &&
              first[12].sampled_image.alias_group !=
                  first[14].sampled_image.alias_group &&
              first[12].sampled_image.alias_group !=
                  first[14].buffer.alias_group &&
              first[14].buffer.alias_group !=
                  first[14].sampled_image.alias_group,
          7)) {
    return e;
  }
  for (std::size_t rotation = 0U; rotation < 4U; ++rotation) {
    const auto pose_alias = plan.modes[0].rotations[rotation]
                                .bindings[13].buffer.alias_group;
    if (int e = Require(
            pose_alias == plan.modes[1].rotations[rotation]
                              .bindings[13].buffer.alias_group,
            14)) {
      return e;
    }
    for (std::size_t other = rotation + 1U; other < 4U; ++other) {
      if (int e = Require(
              pose_alias != plan.modes[0].rotations[other]
                                .bindings[13].buffer.alias_group &&
                  pose_alias != plan.modes[1].rotations[other]
                                    .bindings[13].buffer.alias_group,
              15)) {
        return e;
      }
    }
  }

  const auto expected_ref_upload =
      Expected(4U * p, 1U, arena::ScalarType::kUint32,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  const auto expected_gray_buffer_upload =
      Expected(4U * n * sp, 1U, arena::ScalarType::kUint32,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  const auto expected_gray_image_upload =
      Expected(n * sp, 1U, arena::ScalarType::kUint8,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  const auto expected_depth_readback =
      Expected(4U * p, 1U, arena::ScalarType::kFloat32,
               arena::MemoryClass::kHostReadback,
               Usage(arena::kUsageTransferDestination));
  const auto expected_normal_readback =
      Expected(12U * p, 3U, arena::ScalarType::kFloat32,
               arena::MemoryClass::kHostReadback,
               Usage(arena::kUsageTransferDestination));
  const auto expected_mask_readback =
      Expected(4U * n * p, n, arena::ScalarType::kUint32,
               arena::MemoryClass::kHostReadback,
               Usage(arena::kUsageTransferDestination));
  for (const auto &mode : plan.modes) {
    if (int e = Require(
            MatchesTuple(mode.reference_upload_staging, expected_ref_upload) &&
                !mode.reference_depth_upload_staging.present() &&
                !mode.reference_normal_upload_staging.present() &&
                !mode.source_depth_upload_staging.present() &&
                MatchesTuple(mode.source_gray_buffer_upload_staging,
                             expected_gray_buffer_upload) &&
                MatchesTuple(mode.source_gray_image_upload_staging,
                             expected_gray_image_upload) &&
                MatchesTuple(mode.depth_readback, expected_depth_readback) &&
                MatchesTuple(mode.normal_readback,
                             expected_normal_readback) &&
                MatchesTuple(mode.mask_readback, expected_mask_readback),
            8)) {
      return e;
    }
  }

  arena::ResourceArenaInput streamed_input = input;
  streamed_input.phase = pocketworld::official_dense::vulkan::PlanPhase::kGeometricOnly;
  streamed_input.streamed_source_depth = true;
  streamed_input.streamed_reference_state = true;
  arena::ResourceArenaPlan streamed;
  const auto expected_depth_upload =
      Expected(4U * n * sp, 1U, arena::ScalarType::kFloat32,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  const auto expected_reference_depth_upload =
      Expected(4U * p, 1U, arena::ScalarType::kFloat32,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  const auto expected_reference_normal_upload =
      Expected(12U * p, 1U, arena::ScalarType::kFloat32,
               arena::MemoryClass::kHostUpload,
               Usage(arena::kUsageTransferSource));
  if (int e = Require(
          arena::BuildResourceArenaPlan(streamed_input, &streamed) &&
              !streamed.modes[0].reference_upload_staging.present() &&
              !streamed.modes[0].source_depth_upload_staging.present() &&
              MatchesTuple(streamed.modes[1].reference_depth_upload_staging,
                           expected_reference_depth_upload) &&
              MatchesTuple(streamed.modes[1].reference_normal_upload_staging,
                           expected_reference_normal_upload) &&
              MatchesTuple(streamed.modes[1].source_depth_upload_staging,
                           expected_depth_upload) &&
              streamed.modes[1].source_depth_upload_staging.exact_bytes ==
                  4U * n * sp,
          16)) {
    return e;
  }
  arena::ResourceArenaInput incomplete_geometric = streamed_input;
  incomplete_geometric.streamed_reference_state = false;
  arena::ResourceArenaPlan rejected_geometric = plan;
  if (int e = Require(
          !arena::BuildResourceArenaPlan(incomplete_geometric,
                                         &rejected_geometric) &&
              SamePlan(rejected_geometric, plan),
          19)) {
    return e;
  }
  for (std::size_t rotation = 0U; rotation < 4U; ++rotation) {
    if (int e = Require(
            MatchesTuple(
                plan.poses[rotation].active_pose_table,
                Expected(172U * n, 1U, arena::ScalarType::kFloat32,
                         arena::MemoryClass::kDeviceLocal, storage_dst)) &&
                MatchesTuple(
                    plan.poses[rotation].pose_upload_staging,
                    Expected(172U * n, 1U, arena::ScalarType::kFloat32,
                             arena::MemoryClass::kHostUpload,
                             Usage(arena::kUsageTransferSource))) &&
                plan.poses[rotation].active_pose_table.alias_group ==
                    plan.modes[0].rotations[rotation]
                        .bindings[13].buffer.alias_group,
            9)) {
      return e;
    }
  }
  if (int e = Require(
          MatchesTuple(
              plan.consistency_graph_values,
              Expected(4U * p * (n + 3U), 1U, arena::ScalarType::kInt32,
                       arena::MemoryClass::kHostValues,
                       Usage(arena::kUsageHostValues))) &&
              plan.consistency_graph_value_capacity == p * (n + 3U) &&
              plan.alias_groups_are_plan_local,
          10)) {
    return e;
  }

  arena::ResourceArenaPlan mixed;
  if (int e = Require(arena::BuildResourceArenaPlan(
                          {31U, 17U, 29U, 13U, 3U, 31U}, &mixed) &&
                          mixed.modes[0].rotations[1].width == 17U &&
                          mixed.modes[0].rotations[1].height == 31U &&
                          mixed.modes[0].rotations[0]
                                  .bindings[14].sampled_image.exact_bytes ==
                              29U * 13U * 3U,
                      11)) {
    return e;
  }

  arena::ResourceArenaInput photo_input = input;
  photo_input.phase =
      pocketworld::official_dense::vulkan::PlanPhase::kPhotometricOnly;
  arena::ResourceArenaPlan photo;
  arena::ResourceArenaMemorySummary full_memory;
  arena::ResourceArenaMemorySummary photo_memory;
  arena::ResourceArenaMemorySummary geometric_memory;
  if (int e = Require(
          arena::BuildResourceArenaPlan(photo_input, &photo) &&
              arena::SummarizeResourceArenaMemory(plan, &full_memory) &&
              arena::SummarizeResourceArenaMemory(photo, &photo_memory) &&
              arena::SummarizeResourceArenaMemory(streamed,
                                                  &geometric_memory) &&
              full_memory.total_bytes ==
                  full_memory.device_local_bytes +
                      full_memory.host_upload_bytes +
                      full_memory.host_readback_bytes +
                      full_memory.host_values_bytes &&
              full_memory.total_bytes > photo_memory.total_bytes &&
              full_memory.total_bytes > geometric_memory.total_bytes &&
              photo_memory.allocation_count > 0U &&
              geometric_memory.allocation_count > 0U,
          17)) {
    return e;
  }
  arena::ResourceArenaPlan conflicting_alias = plan;
  ++conflicting_alias.modes[0]
        .rotations[1]
        .bindings[8]
        .buffer.exact_bytes;
  const arena::ResourceArenaMemorySummary memory_sentinel{
      1U, 2U, 3U, 4U, 10U, 5U};
  arena::ResourceArenaMemorySummary invalid_memory = memory_sentinel;
  if (int e = Require(
          !arena::SummarizeResourceArenaMemory(conflicting_alias,
                                               &invalid_memory) &&
              invalid_memory.device_local_bytes ==
                  memory_sentinel.device_local_bytes &&
              invalid_memory.host_upload_bytes ==
                  memory_sentinel.host_upload_bytes &&
              invalid_memory.host_readback_bytes ==
                  memory_sentinel.host_readback_bytes &&
              invalid_memory.host_values_bytes ==
                  memory_sentinel.host_values_bytes &&
              invalid_memory.total_bytes == memory_sentinel.total_bytes &&
              invalid_memory.allocation_count ==
                  memory_sentinel.allocation_count &&
              !arena::SummarizeResourceArenaMemory(plan, nullptr),
          18)) {
    return e;
  }

  const auto max = std::numeric_limits<std::uint64_t>::max();
  const std::array<arena::ResourceArenaInput, 12U> invalid_inputs = {{
      {0U, 48U, 80U, 61U, 2U, 64U},
      {64U, 0U, 80U, 61U, 2U, 64U},
      {64U, 48U, 0U, 61U, 2U, 64U},
      {64U, 48U, 80U, 0U, 2U, 64U},
      {64U, 48U, 80U, 61U, 0U, 64U},
      {64U, 48U, 80U, 61U, 2U, 63U},
      {max, 2U, 1U, 1U, 1U, max},
      {1U, 1U, max, 2U, 1U, 1U},
      {1U, 1U, max, 1U, 2U, 1U},
      {1U, 1U, 1U, 1U, max, 1U},
      {1U, 1U, 1U, 1U, max / 100U, 1U},
      {1U, 1U, 1U, 1U, 2U, max},
  }};
  const arena::ResourceArenaPlan sentinel = plan;
  arena::ResourceArenaPlan output = sentinel;
  for (const auto &invalid : invalid_inputs) {
    if (int e = Require(!arena::BuildResourceArenaPlan(invalid, &output) &&
                            SamePlan(output, sentinel),
                        12)) {
      return e;
    }
  }
  if (int e = Require(!arena::BuildResourceArenaPlan(input, nullptr) &&
                          SamePlan(output, sentinel),
                      13)) {
    return e;
  }
  return 0;
}
