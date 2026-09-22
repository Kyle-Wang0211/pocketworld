#include "dispatch_plan.h"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

using pocketworld::official_dense::vulkan::CreateDispatchPlan;
using pocketworld::official_dense::vulkan::Dispatch;
using pocketworld::official_dense::vulkan::DispatchReadiness;
using pocketworld::official_dense::vulkan::DispatchStatus;
using pocketworld::official_dense::vulkan::Mode;
using pocketworld::official_dense::vulkan::Operation;
using pocketworld::official_dense::vulkan::PlanOptions;
using pocketworld::official_dense::vulkan::PlanPhase;
using pocketworld::official_dense::vulkan::PlanStatus;
using pocketworld::official_dense::vulkan::RotatedResource;
using pocketworld::official_dense::vulkan::kSweepFilterGeomConsistency;
using pocketworld::official_dense::vulkan::kSweepFilterPhotoConsistency;
using pocketworld::official_dense::vulkan::kSweepGeomConsistencyTerm;

namespace {

bool Near(const float actual, const float expected) {
  return std::abs(actual - expected) <= 1e-6F;
}

}  // namespace

int main() {
  constexpr std::uint32_t kImages = 2;
  const auto plan = CreateDispatchPlan(kImages);
  if (plan.status != PlanStatus::kReady || !plan.Validate()) return 1;
  if (plan.image_count != kImages || plan.iterations != 5) return 2;
  // [INTERLEAVE 2026-08-30] N>1 走交错形态:同一个 (iteration, sweep) 上
  // N 个 image 的 sweep 共享**一个** barrier,而不是各自一个。
  //   串行 N=2: 1103 步(每 image 20 个 barrier,共 40 个)
  //   交错 N=2: 1063 步(20 个共享 barrier)  ⇒ 省 40 个重复 barrier
  // barrier 语义未被削弱(仍是"全部 sweep 写完才 rotate"),减少的是
  // 冗余的 submit+wait —— 每次 wait 都会把 GPU 流水线抽干。
  // 实测步数:N=1→552, N=2→1063, N=3→1574, N=4→2085(公差 511)。
  if (plan.steps.size() != 1063) return 3;
  // N=1 必须仍是原串行形态,逐字不变(回归安全网)。
  if (CreateDispatchPlan(1).steps.size() != 552) return 3;

  PlanOptions unsupported_iterations;
  unsupported_iterations.iterations = 4;
  const auto rejected_iterations =
      CreateDispatchPlan(kImages, unsupported_iterations);
  if (rejected_iterations.status != PlanStatus::kUnsupportedOptions ||
      rejected_iterations.Validate() || !rejected_iterations.steps.empty()) {
    return 4;
  }
  PlanOptions unsupported_filter;
  unsupported_filter.filter = false;
  if (CreateDispatchPlan(kImages, unsupported_filter).status !=
      PlanStatus::kUnsupportedOptions) {
    return 5;
  }
  PlanOptions unsupported_geometry;
  unsupported_geometry.geom_consistency = false;
  if (CreateDispatchPlan(kImages, unsupported_geometry).status !=
          PlanStatus::kUnsupportedOptions ||
      CreateDispatchPlan(0).status != PlanStatus::kInvalidImageCount) {
    return 35;
  }

  constexpr std::array<RotatedResource, 10> kRotationOrder = {
      RotatedResource::kRng,
      RotatedResource::kDepth,
      RotatedResource::kNormalVector,
      RotatedResource::kNormalPlanes,
      RotatedResource::kReferenceBytes,
      RotatedResource::kReferenceWeightedSum,
      RotatedResource::kReferenceWeightedSquaredSum,
      RotatedResource::kSelectionToPrevious,
      RotatedResource::kAllocateSelection,
      RotatedResource::kCost,
  };

  bool saw_global_wait = false;
  bool saw_geometric = false;
  std::uint32_t random_depth_inits = 0;
  std::uint32_t random_normal_inits = 0;
  std::uint32_t copied_depth_inits = 0;
  std::uint32_t copied_normal_inits = 0;
  std::uint32_t photometric_sweeps = 0;
  std::uint32_t geometric_sweeps = 0;
  std::uint32_t consistency_mask_allocations = 0;
  std::uint32_t consistency_mask_clears = 0;
  std::uint32_t final_mask_rotations = 0;
  std::uint32_t depth_readbacks = 0;
  std::uint32_t normal_readbacks = 0;
  std::uint32_t mask_readbacks = 0;

  for (std::size_t index = 0; index < plan.steps.size(); ++index) {
    const auto& step = plan.steps[index];
    if (step.mode == Mode::kGeometric) {
      saw_geometric = true;
      if (!saw_global_wait) return 6;
    }
    if (step.operation == Operation::kWaitPhotometricAll) {
      if (saw_geometric || saw_global_wait) return 7;
      saw_global_wait = true;
    }
    switch (step.operation) {
      case Operation::kInitializeRandomDepth:
        if (step.mode != Mode::kPhotometric) return 8;
        ++random_depth_inits;
        break;
      case Operation::kInitializeRandomNormal:
        if (step.mode != Mode::kPhotometric) return 9;
        ++random_normal_inits;
        break;
      case Operation::kCopyPhotometricDepth:
        if (step.mode != Mode::kGeometric) return 10;
        ++copied_depth_inits;
        break;
      case Operation::kCopyPhotometricNormal:
        if (step.mode != Mode::kGeometric) return 11;
        ++copied_normal_inits;
        break;
      case Operation::kAllocateConsistencyMask:
        if (step.mode != Mode::kGeometric || step.iteration != 4 ||
            step.sweep != 3) {
          return 12;
        }
        ++consistency_mask_allocations;
        break;
      case Operation::kClearConsistencyMask:
        if (step.mode != Mode::kGeometric || step.iteration != 4 ||
            step.sweep != 3) {
          return 34;
        }
        ++consistency_mask_clears;
        break;
      case Operation::kRotateFinalMask:
        if (step.mode != Mode::kGeometric || step.iteration != 4 ||
            step.sweep != 3 || step.rotation_after != 0) {
          return 13;
        }
        ++final_mask_rotations;
        break;
      case Operation::kReadbackDepth:
        ++depth_readbacks;
        break;
      case Operation::kReadbackNormal:
        ++normal_readbacks;
        break;
      case Operation::kReadbackMask:
        if (step.mode != Mode::kGeometric) return 14;
        ++mask_readbacks;
        break;
      case Operation::kSweep: {
        if (step.iteration >= 5 || step.sweep >= 4) return 15;
        if (step.rotation_before != step.sweep ||
            step.calibration_rotation != step.rotation_before ||
            step.rotation_after != ((step.rotation_before + 1U) & 3U)) {
          return 16;
        }
        const std::uint32_t flat_step = step.iteration * 4U + step.sweep;
        const float expected_perturbation =
            1.0F / std::pow(2.0F, static_cast<float>(step.iteration) +
                                      static_cast<float>(step.sweep) / 4.0F);
        if (!Near(step.perturbation, expected_perturbation) ||
            !Near(step.prev_sel_prob_weight,
                  static_cast<float>(flat_step) / 20.0F)) {
          return 17;
        }
        const bool last = step.iteration == 4 && step.sweep == 3;
        if (step.mode == Mode::kPhotometric) {
          ++photometric_sweeps;
          if (step.sweep_flags != 0) return 18;
        } else {
          ++geometric_sweeps;
          const std::uint8_t expected_flags =
              last ? static_cast<std::uint8_t>(
                         kSweepGeomConsistencyTerm |
                         kSweepFilterPhotoConsistency |
                         kSweepFilterGeomConsistency)
                   : kSweepGeomConsistencyTerm;
          if (step.sweep_flags != expected_flags) return 19;
        }
        // [INTERLEAVE 2026-08-30] 原断言按**固定偏移** index+2 找 rotate,
        // 那隐含了"sweep 后紧跟 barrier 再紧跟本 image 的 rotate"这个串行
        // 假设。交错形态下,两者之间隔着其他 image 的 sweep。
        // 改为按语义查找:在本 sweep 之后,找到**本 image 本轮**的第一个
        // rotate,从那里开始仍然要求全套 kRotationOrder 顺序 + 选标定。
        // 严格性不变(顺序、资源种类、rotation_after 全都照查),只是不再
        // 把"紧邻"当成规范的一部分。
        std::size_t rotate_begin = plan.steps.size();
        for (std::size_t probe = index + 1U; probe < plan.steps.size();
             ++probe) {
          const auto& candidate = plan.steps[probe];
          if (candidate.operation == Operation::kRotateResource &&
              candidate.image == step.image &&
              candidate.iteration == step.iteration &&
              candidate.sweep == step.sweep) {
            rotate_begin = probe;
            break;
          }
        }
        if (rotate_begin + kRotationOrder.size() >= plan.steps.size()) {
          return 20;
        }
        for (std::size_t resource = 0; resource < kRotationOrder.size();
             ++resource) {
          const auto& rotate = plan.steps[rotate_begin + resource];
          if (rotate.operation != Operation::kRotateResource ||
              rotate.resource != kRotationOrder[resource] ||
              rotate.image != step.image) {
            return 21;
          }
        }
        const auto& select_pose =
            plan.steps[rotate_begin + kRotationOrder.size()];
        if (select_pose.operation != Operation::kSelectCalibrationAndPose ||
            select_pose.image != step.image ||
            select_pose.calibration_rotation != step.rotation_after) {
          return 22;
        }
        break;
      }
      default:
        break;
    }
  }

  if (!saw_global_wait || !saw_geometric) return 23;
  if (random_depth_inits != kImages || random_normal_inits != kImages ||
      copied_depth_inits != kImages || copied_normal_inits != kImages) {
    return 24;
  }
  if (photometric_sweeps != kImages * 20U ||
      geometric_sweeps != kImages * 20U) {
    return 25;
  }
  if (consistency_mask_allocations != kImages ||
      consistency_mask_clears != kImages ||
      final_mask_rotations != kImages) {
    return 26;
  }
  if (depth_readbacks != kImages * 2U ||
      normal_readbacks != kImages * 2U || mask_readbacks != kImages) {
    return 27;
  }
  if (plan.final_rotation != 0) return 28;

  const PlanOptions photometric_options{5U, false, false,
                                        PlanPhase::kPhotometricOnly};
  const PlanOptions geometric_options{5U, true, true,
                                      PlanPhase::kGeometricOnly};
  const auto photometric_plan =
      CreateDispatchPlan(kImages, photometric_options);
  const auto geometric_plan = CreateDispatchPlan(kImages, geometric_options);
  if (!photometric_plan.Validate() || !geometric_plan.Validate() ||
      photometric_plan.steps.size() + geometric_plan.steps.size() + 1U !=
          plan.steps.size()) {
    return 36;
  }
  for (std::size_t index = 0U; index < photometric_plan.steps.size(); ++index) {
    if (!(photometric_plan.steps[index] == plan.steps[index])) return 37;
  }
  const std::size_t geometric_offset = photometric_plan.steps.size() + 1U;
  if (plan.steps[photometric_plan.steps.size()].operation !=
      Operation::kWaitPhotometricAll) {
    return 38;
  }
  for (std::size_t index = 0U; index < geometric_plan.steps.size(); ++index) {
    if (!(geometric_plan.steps[index] == plan.steps[geometric_offset + index])) {
      return 39;
    }
  }

  DispatchReadiness readiness;
  if (Dispatch(plan, readiness) != DispatchStatus::kLoaderNotReady) return 29;
  readiness.loader_ready = true;
  if (Dispatch(plan, readiness) != DispatchStatus::kRngNotReady) return 30;
  readiness.rng_ready = true;
  if (Dispatch(plan, readiness) != DispatchStatus::kCostSamplerNotReady) {
    return 31;
  }
  readiness.cost_sampler_ready = true;
  if (Dispatch(plan, readiness) != DispatchStatus::kExecutionNotImplemented) {
    return 32;
  }
  auto corrupted = plan;
  corrupted.steps[0].operation = Operation::kBarrier;
  if (corrupted.Validate() ||
      Dispatch(corrupted, readiness) != DispatchStatus::kInvalidPlan) {
    return 33;
  }
  return 0;
}
