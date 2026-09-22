// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <vector>
#include "dispatch_plan.h"

#include <array>
#include <cmath>
#include <cstddef>

namespace pocketworld::official_dense::vulkan {
namespace {

// Frozen from COLMAP 4.1.1 patch_match_cuda.cu at revision
// a0d785fba74b2664f31edc4a29026a8b27c00f67, especially lines 1412-1503
// (sweep/filter control flow) and 1761-1889 (initialization/rotation).
inline constexpr std::uint32_t kFrozenIterations = 5;
inline constexpr std::uint32_t kSweepCount = 4;
inline constexpr std::array<RotatedResource, 10> kRotationOrder = {
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

bool IsFrozenDefault(const PlanOptions& options) noexcept {
  if (options.iterations != kFrozenIterations) return false;
  switch (options.phase) {
    case PlanPhase::kFull:
    case PlanPhase::kGeometricOnly:
      return options.geom_consistency && options.filter;
    case PlanPhase::kPhotometricOnly:
      // Exact temporary options used by PatchMatchController::Run().
      return !options.geom_consistency && !options.filter;
  }
  return false;
}

PlanStep BasicStep(const Operation operation,
                   const Mode mode,
                   const std::uint32_t image,
                   const std::uint32_t rotation) noexcept {
  PlanStep step;
  step.operation = operation;
  step.mode = mode;
  step.image = image;
  step.rotation_before = rotation;
  step.rotation_after = rotation;
  step.calibration_rotation = rotation;
  return step;
}

void AppendBasic(DispatchPlan* plan,
                 const Operation operation,
                 const Mode mode,
                 const std::uint32_t image,
                 const std::uint32_t rotation) {
  plan->steps.push_back(BasicStep(operation, mode, image, rotation));
}

void AppendInitialization(DispatchPlan* plan,
                          const Mode mode,
                          const std::uint32_t image,
                          const std::uint32_t rotation) {
  AppendBasic(plan, Operation::kUploadReferenceImage, mode, image, rotation);
  AppendBasic(plan, Operation::kReferenceFilter, mode, image, rotation);
  AppendBasic(plan, Operation::kUploadSourceImages, mode, image, rotation);
  if (mode == Mode::kGeometric) {
    AppendBasic(plan, Operation::kUploadSourceDepthMaps, mode, image, rotation);
  }
  AppendBasic(plan, Operation::kUploadTransformsAndCalibrations, mode, image,
              rotation);
  AppendBasic(plan, Operation::kInitializeRng, mode, image, rotation);
  if (mode == Mode::kPhotometric) {
    AppendBasic(plan, Operation::kInitializeRandomDepth, mode, image, rotation);
    AppendBasic(plan, Operation::kInitializeRandomNormal, mode, image,
                rotation);
  } else {
    AppendBasic(plan, Operation::kCopyPhotometricDepth, mode, image, rotation);
    AppendBasic(plan, Operation::kCopyPhotometricNormal, mode, image, rotation);
  }
  AppendBasic(plan, Operation::kInitializeSelectionAndWorkspace, mode, image,
              rotation);

  // RunWithWindowSizeAndStep starts with CUDA_SYNC_AND_CHECK after constructor
  // initialization, then synchronizes again after ComputeInitialCost.
  AppendBasic(plan, Operation::kBarrier, mode, image, rotation);
  AppendBasic(plan, Operation::kInitialCost, mode, image, rotation);
  AppendBasic(plan, Operation::kBarrier, mode, image, rotation);
}

PlanStep SweepStep(const Mode mode,
                   const std::uint32_t image,
                   const std::uint32_t iteration,
                   const std::uint32_t sweep,
                   const std::uint32_t rotation) noexcept {
  PlanStep step = BasicStep(Operation::kSweep, mode, image, rotation);
  step.iteration = iteration;
  step.sweep = sweep;
  step.rotation_after = (rotation + 1U) & 3U;
  step.perturbation =
      1.0F / std::pow(2.0F, static_cast<float>(iteration) +
                                static_cast<float>(sweep) / 4.0F);
  step.prev_sel_prob_weight =
      static_cast<float>(iteration * kSweepCount + sweep) /
      static_cast<float>(kFrozenIterations * kSweepCount);
  if (mode == Mode::kGeometric) {
    step.sweep_flags = kSweepGeomConsistencyTerm;
    if (iteration == kFrozenIterations - 1U && sweep == kSweepCount - 1U) {
      step.sweep_flags = static_cast<std::uint8_t>(
          kSweepGeomConsistencyTerm | kSweepFilterPhotoConsistency |
          kSweepFilterGeomConsistency);
    }
  }
  return step;
}

// [INTERLEAVE 2026-08-30] 交错批处理用的两个半步。
//
// 背景:官方 PatchMatch 的并行度 = 图像宽度(ahojnnes 在 issue #2536 亲口
// 确认的架构性约束),2000 宽的图只有 63 个 workgroup。Metal 微基准实测
// (同算术密度):63 wg → 1.89ms,504 wg → 2.49ms —— workgroup 涨 8 倍耗时
// 只涨 32%,即现状下 GPU 闲置约 85%。
//
// 解药是官方给的那一条:增加**在飞的 reference 数**。但 reference 内部
// 的 sweep→Rotate 有真实数据依赖(官方 patch_match_cuda.cu:1491 的
// CUDA_SYNC_AND_CHECK 就在每个 sweep 之后、Rotate 之前),去不掉。
// 而 **reference 之间零依赖** —— 所以把 N 个 reference 的 sweep 挤进
// 同一个 barrier 之前,barrier 语义仍然满足,GPU 却拿到 N 倍工作。
//
// 🔴 无损:每个 reference 的步骤序列、rotation 推进、RNG、资源都与单独
//    跑时逐字相同,只是**多个 reference 的同名步骤在时间上并排**。
//    barrier 处仍保证"全部 sweep 完成才 rotate"。
void AppendSweepDispatchOnly(DispatchPlan* plan,
                             const Mode mode,
                             const std::uint32_t image,
                             const std::uint32_t iteration,
                             const std::uint32_t sweep,
                             const std::uint32_t rotation) {
  const bool final_filtered_sweep =
      mode == Mode::kGeometric && iteration == kFrozenIterations - 1U &&
      sweep == kSweepCount - 1U;
  if (final_filtered_sweep) {
    PlanStep allocate = BasicStep(Operation::kAllocateConsistencyMask, mode,
                                  image, rotation);
    allocate.iteration = iteration;
    allocate.sweep = sweep;
    plan->steps.push_back(allocate);
    PlanStep clear = BasicStep(Operation::kClearConsistencyMask, mode, image,
                               rotation);
    clear.iteration = iteration;
    clear.sweep = sweep;
    plan->steps.push_back(clear);
  }
  plan->steps.push_back(SweepStep(mode, image, iteration, sweep, rotation));
}

// barrier 之后的收尾:rotate 全部资源 + 选标定 + (末轮)旋转掩码。
void AppendSweepTail(DispatchPlan* plan,
                     const Mode mode,
                     const std::uint32_t image,
                     const std::uint32_t iteration,
                     const std::uint32_t sweep,
                     std::uint32_t* rotation) {
  const PlanStep sweep_step =
      SweepStep(mode, image, iteration, sweep, *rotation);
  for (const RotatedResource resource : kRotationOrder) {
    PlanStep rotate = BasicStep(Operation::kRotateResource, mode, image,
                                *rotation);
    rotate.resource = resource;
    rotate.iteration = iteration;
    rotate.sweep = sweep;
    rotate.rotation_after = sweep_step.rotation_after;
    plan->steps.push_back(rotate);
  }
  *rotation = sweep_step.rotation_after;
  PlanStep calibration = BasicStep(Operation::kSelectCalibrationAndPose, mode,
                                   image, *rotation);
  calibration.iteration = iteration;
  calibration.sweep = sweep;
  plan->steps.push_back(calibration);
  const bool final_filtered_sweep =
      mode == Mode::kGeometric && iteration == kFrozenIterations - 1U &&
      sweep == kSweepCount - 1U;
  if (final_filtered_sweep) {
    PlanStep mask = BasicStep(Operation::kRotateFinalMask, mode, image,
                              *rotation);
    mask.iteration = iteration;
    mask.sweep = sweep;
    plan->steps.push_back(mask);
  }
}

void AppendSweep(DispatchPlan* plan,
                 const Mode mode,
                 const std::uint32_t image,
                 const std::uint32_t iteration,
                 const std::uint32_t sweep,
                 std::uint32_t* rotation) {
  const bool final_filtered_sweep =
      mode == Mode::kGeometric && iteration == kFrozenIterations - 1U &&
      sweep == kSweepCount - 1U;
  if (final_filtered_sweep) {
    PlanStep allocate = BasicStep(Operation::kAllocateConsistencyMask, mode,
                                  image, *rotation);
    allocate.iteration = iteration;
    allocate.sweep = sweep;
    plan->steps.push_back(allocate);
    PlanStep clear = BasicStep(Operation::kClearConsistencyMask, mode, image,
                               *rotation);
    clear.iteration = iteration;
    clear.sweep = sweep;
    plan->steps.push_back(clear);
  }

  const PlanStep sweep_step = SweepStep(mode, image, iteration, sweep, *rotation);
  plan->steps.push_back(sweep_step);

  // The upstream CUDA_SYNC_AND_CHECK occurs immediately after every sweep.
  PlanStep barrier = BasicStep(Operation::kBarrier, mode, image, *rotation);
  barrier.iteration = iteration;
  barrier.sweep = sweep;
  plan->steps.push_back(barrier);

  for (const RotatedResource resource : kRotationOrder) {
    PlanStep rotate = BasicStep(Operation::kRotateResource, mode, image,
                                *rotation);
    rotate.resource = resource;
    rotate.iteration = iteration;
    rotate.sweep = sweep;
    rotate.rotation_after = sweep_step.rotation_after;
    plan->steps.push_back(rotate);
  }

  *rotation = sweep_step.rotation_after;
  PlanStep calibration = BasicStep(Operation::kSelectCalibrationAndPose, mode,
                                   image, *rotation);
  calibration.iteration = iteration;
  calibration.sweep = sweep;
  plan->steps.push_back(calibration);

  // Upstream rotates the consistency mask after Rotate() on the final sweep.
  if (final_filtered_sweep) {
    PlanStep mask = BasicStep(Operation::kRotateFinalMask, mode, image,
                              *rotation);
    mask.iteration = iteration;
    mask.sweep = sweep;
    plan->steps.push_back(mask);
  }
}

void AppendImage(DispatchPlan* plan,
                 const Mode mode,
                 const std::uint32_t image,
                 std::uint32_t* rotation) {
  AppendInitialization(plan, mode, image, *rotation);
  for (std::uint32_t iteration = 0; iteration < kFrozenIterations;
       ++iteration) {
    for (std::uint32_t sweep = 0; sweep < kSweepCount; ++sweep) {
      AppendSweep(plan, mode, image, iteration, sweep, rotation);
    }
  }
  AppendBasic(plan, Operation::kReadbackDepth, mode, image, *rotation);
  AppendBasic(plan, Operation::kReadbackNormal, mode, image, *rotation);
  if (mode == Mode::kGeometric) {
    AppendBasic(plan, Operation::kReadbackMask, mode, image, *rotation);
  }
}

// [INTERLEAVE 2026-08-30] N 个 reference 交错推进同一条官方序列。
//
// 与串行 AppendImage 的唯一差别:同一个 (iteration, sweep) 上,
// 先把**全部 N 个 image** 的 sweep dispatch 发出去,再发一次 barrier,
// 然后做全部 N 个 image 的 rotate 收尾。
//
//   串行: A.sweep A.barrier A.rot | B.sweep B.barrier B.rot
//   交错: A.sweep B.sweep barrier | A.rot B.rot
//
// barrier 的语义没有被削弱(仍然是"所有 sweep 写完才 rotate"),
// 但每个 barrier 之间的在飞工作从 63 个 workgroup 变成 N×63 个。
//
// 初始化与回读仍逐 image 串行 —— 它们是上传/下载,不是 GPU 计算热点,
// 交错它们只会增加峰值内存而无收益。
void AppendImagesInterleaved(DispatchPlan* plan,
                             const Mode mode,
                             const std::uint32_t image_count,
                             std::uint32_t* rotation) {
  const std::uint32_t base_rotation = *rotation;
  for (std::uint32_t image = 0; image < image_count; ++image) {
    AppendInitialization(plan, mode, image, base_rotation);
  }
  // 每个 image 各自持有 rotation 游标 —— 它们本来就同步推进
  // (同样的 5 迭代 × 4 sweep),这里只是让类型系统看得见这一点。
  std::vector<std::uint32_t> rotations(image_count, base_rotation);
  for (std::uint32_t iteration = 0; iteration < kFrozenIterations;
       ++iteration) {
    for (std::uint32_t sweep = 0; sweep < kSweepCount; ++sweep) {
      for (std::uint32_t image = 0; image < image_count; ++image) {
        AppendSweepDispatchOnly(plan, mode, image, iteration, sweep,
                                rotations[image]);
      }
      // 一次 barrier 覆盖全部 N 个 image 的 sweep
      // (官方 CUDA_SYNC_AND_CHECK 是 stream 级同步,本就覆盖全部在飞工作)
      PlanStep barrier =
          BasicStep(Operation::kBarrier, mode, 0U, rotations[0]);
      barrier.iteration = iteration;
      barrier.sweep = sweep;
      plan->steps.push_back(barrier);
      for (std::uint32_t image = 0; image < image_count; ++image) {
        AppendSweepTail(plan, mode, image, iteration, sweep,
                        &rotations[image]);
      }
    }
  }
  for (std::uint32_t image = 0; image < image_count; ++image) {
    AppendBasic(plan, Operation::kReadbackDepth, mode, image,
                rotations[image]);
    AppendBasic(plan, Operation::kReadbackNormal, mode, image,
                rotations[image]);
    if (mode == Mode::kGeometric) {
      AppendBasic(plan, Operation::kReadbackMask, mode, image,
                  rotations[image]);
    }
  }
  *rotation = rotations[0];
}

bool StepMatches(const PlanStep& actual,
                 const PlanStep& expected) noexcept {
  return actual == expected;
}

}  // namespace

bool PlanStep::operator==(const PlanStep& other) const noexcept {
  return operation == other.operation && mode == other.mode &&
         resource == other.resource && image == other.image &&
         iteration == other.iteration && sweep == other.sweep &&
         rotation_before == other.rotation_before &&
         rotation_after == other.rotation_after &&
         calibration_rotation == other.calibration_rotation &&
         perturbation == other.perturbation &&
         prev_sel_prob_weight == other.prev_sel_prob_weight &&
         sweep_flags == other.sweep_flags;
}

bool DispatchPlan::Validate() const noexcept {
  if (status != PlanStatus::kReady || image_count == 0 ||
      iterations != kFrozenIterations || final_rotation != 0) {
    return false;
  }

  std::size_t cursor = 0;
  std::uint32_t rotation = 0;
  const auto expect = [this, &cursor](const PlanStep& expected) noexcept {
    if (cursor >= steps.size() || !StepMatches(steps[cursor], expected)) {
      return false;
    }
    ++cursor;
    return true;
  };
  const auto validate_initialization =
      [&expect](const Mode mode, const std::uint32_t image,
                const std::uint32_t current_rotation) noexcept {
        if (!expect(BasicStep(Operation::kUploadReferenceImage, mode, image,
                              current_rotation)) ||
            !expect(BasicStep(Operation::kReferenceFilter, mode, image,
                              current_rotation)) ||
            !expect(BasicStep(Operation::kUploadSourceImages, mode, image,
                              current_rotation))) {
          return false;
        }
        if (mode == Mode::kGeometric &&
            !expect(BasicStep(Operation::kUploadSourceDepthMaps, mode, image,
                              current_rotation))) {
          return false;
        }
        if (!expect(BasicStep(Operation::kUploadTransformsAndCalibrations, mode,
                              image, current_rotation)) ||
            !expect(BasicStep(Operation::kInitializeRng, mode, image,
                              current_rotation))) {
          return false;
        }
        if (mode == Mode::kPhotometric) {
          if (!expect(BasicStep(Operation::kInitializeRandomDepth, mode, image,
                                current_rotation)) ||
              !expect(BasicStep(Operation::kInitializeRandomNormal, mode, image,
                                current_rotation))) {
            return false;
          }
        } else if (!expect(BasicStep(Operation::kCopyPhotometricDepth, mode,
                                     image, current_rotation)) ||
                   !expect(BasicStep(Operation::kCopyPhotometricNormal, mode,
                                     image, current_rotation))) {
          return false;
        }
        return expect(BasicStep(Operation::kInitializeSelectionAndWorkspace,
                                mode, image, current_rotation)) &&
               expect(BasicStep(Operation::kBarrier, mode, image,
                                current_rotation)) &&
               expect(BasicStep(Operation::kInitialCost, mode, image,
                                current_rotation)) &&
               expect(BasicStep(Operation::kBarrier, mode, image,
                                current_rotation));
      };
  // [INTERLEAVE 2026-08-30] 交错形态的校验:与 AppendImagesInterleaved 一一对应。
  // 仍然是 fail-closed 的逐步比对,只是承认"N 个 image 的 sweep 并排在一个
  // barrier 前"这种合法形态。任何步骤缺失、乱序、rotation 不同步都会被拒。
  const auto validate_images_interleaved =
      [&expect, &validate_initialization, &rotation, this](
          const Mode mode) noexcept {
        const std::uint32_t base = rotation;
        for (std::uint32_t image = 0; image < image_count; ++image) {
          if (!validate_initialization(mode, image, base)) return false;
        }
        std::vector<std::uint32_t> rots(image_count, base);
        for (std::uint32_t iteration = 0; iteration < kFrozenIterations;
             ++iteration) {
          for (std::uint32_t sweep = 0; sweep < kSweepCount; ++sweep) {
            const bool final_filtered_sweep =
                mode == Mode::kGeometric &&
                iteration == kFrozenIterations - 1U &&
                sweep == kSweepCount - 1U;
            for (std::uint32_t image = 0; image < image_count; ++image) {
              if (final_filtered_sweep) {
                PlanStep allocate = BasicStep(
                    Operation::kAllocateConsistencyMask, mode, image,
                    rots[image]);
                allocate.iteration = iteration;
                allocate.sweep = sweep;
                PlanStep clear = BasicStep(Operation::kClearConsistencyMask,
                                           mode, image, rots[image]);
                clear.iteration = iteration;
                clear.sweep = sweep;
                if (!expect(allocate) || !expect(clear)) return false;
              }
              if (!expect(SweepStep(mode, image, iteration, sweep,
                                    rots[image]))) {
                return false;
              }
            }
            PlanStep barrier = BasicStep(Operation::kBarrier, mode, 0U,
                                         rots[0]);
            barrier.iteration = iteration;
            barrier.sweep = sweep;
            if (!expect(barrier)) return false;
            for (std::uint32_t image = 0; image < image_count; ++image) {
              const PlanStep expected_sweep =
                  SweepStep(mode, image, iteration, sweep, rots[image]);
              for (const RotatedResource resource : kRotationOrder) {
                PlanStep rotate = BasicStep(Operation::kRotateResource, mode,
                                            image, rots[image]);
                rotate.resource = resource;
                rotate.iteration = iteration;
                rotate.sweep = sweep;
                rotate.rotation_after = expected_sweep.rotation_after;
                if (!expect(rotate)) return false;
              }
              rots[image] = expected_sweep.rotation_after;
              PlanStep calibration = BasicStep(
                  Operation::kSelectCalibrationAndPose, mode, image,
                  rots[image]);
              calibration.iteration = iteration;
              calibration.sweep = sweep;
              if (!expect(calibration)) return false;
              if (final_filtered_sweep) {
                PlanStep mask = BasicStep(Operation::kRotateFinalMask, mode,
                                          image, rots[image]);
                mask.iteration = iteration;
                mask.sweep = sweep;
                if (!expect(mask)) return false;
              }
            }
          }
        }
        for (std::uint32_t image = 0; image < image_count; ++image) {
          if (!expect(BasicStep(Operation::kReadbackDepth, mode, image,
                                rots[image])) ||
              !expect(BasicStep(Operation::kReadbackNormal, mode, image,
                                rots[image]))) {
            return false;
          }
          if (mode == Mode::kGeometric &&
              !expect(BasicStep(Operation::kReadbackMask, mode, image,
                                rots[image]))) {
            return false;
          }
        }
        rotation = rots[0];
        return true;
      };

  const auto validate_image =
      [&expect, &validate_initialization, &rotation](
          const Mode mode, const std::uint32_t image) noexcept {
        if (!validate_initialization(mode, image, rotation)) return false;
        for (std::uint32_t iteration = 0; iteration < kFrozenIterations;
             ++iteration) {
          for (std::uint32_t sweep = 0; sweep < kSweepCount; ++sweep) {
            const bool final_filtered_sweep =
                mode == Mode::kGeometric &&
                iteration == kFrozenIterations - 1U &&
                sweep == kSweepCount - 1U;
            if (final_filtered_sweep) {
              PlanStep allocate = BasicStep(
                  Operation::kAllocateConsistencyMask, mode, image, rotation);
              allocate.iteration = iteration;
              allocate.sweep = sweep;
              PlanStep clear = BasicStep(Operation::kClearConsistencyMask, mode,
                                         image, rotation);
              clear.iteration = iteration;
              clear.sweep = sweep;
              if (!expect(allocate) || !expect(clear)) return false;
            }

            const PlanStep expected_sweep =
                SweepStep(mode, image, iteration, sweep, rotation);
            if (!expect(expected_sweep)) return false;
            PlanStep barrier =
                BasicStep(Operation::kBarrier, mode, image, rotation);
            barrier.iteration = iteration;
            barrier.sweep = sweep;
            if (!expect(barrier)) return false;
            for (const RotatedResource resource : kRotationOrder) {
              PlanStep rotate =
                  BasicStep(Operation::kRotateResource, mode, image, rotation);
              rotate.resource = resource;
              rotate.iteration = iteration;
              rotate.sweep = sweep;
              rotate.rotation_after = expected_sweep.rotation_after;
              if (!expect(rotate)) return false;
            }
            rotation = expected_sweep.rotation_after;
            PlanStep calibration = BasicStep(
                Operation::kSelectCalibrationAndPose, mode, image, rotation);
            calibration.iteration = iteration;
            calibration.sweep = sweep;
            if (!expect(calibration)) return false;
            if (final_filtered_sweep) {
              PlanStep mask =
                  BasicStep(Operation::kRotateFinalMask, mode, image, rotation);
              mask.iteration = iteration;
              mask.sweep = sweep;
              if (!expect(mask)) return false;
            }
          }
        }
        if (!expect(BasicStep(Operation::kReadbackDepth, mode, image,
                              rotation)) ||
            !expect(BasicStep(Operation::kReadbackNormal, mode, image,
                              rotation))) {
          return false;
        }
        return mode != Mode::kGeometric ||
               expect(BasicStep(Operation::kReadbackMask, mode, image,
                                rotation));
      };

  if (phase == PlanPhase::kFull || phase == PlanPhase::kPhotometricOnly) {
    if (image_count > 1U) {
      if (!validate_images_interleaved(Mode::kPhotometric)) return false;
    } else if (!validate_image(Mode::kPhotometric, 0U)) {
      return false;
    }
  }
  if (phase == PlanPhase::kFull) {
    if (!expect(BasicStep(Operation::kWaitPhotometricAll, Mode::kPhotometric,
                          UINT32_MAX, rotation))) {
      return false;
    }
  }
  if (phase == PlanPhase::kFull || phase == PlanPhase::kGeometricOnly) {
    if (image_count > 1U) {
      if (!validate_images_interleaved(Mode::kGeometric)) return false;
    } else if (!validate_image(Mode::kGeometric, 0U)) {
      return false;
    }
  }
  return cursor == steps.size() && rotation == 0;
}

DispatchPlan CreateDispatchPlan(const std::uint32_t image_count,
                                const PlanOptions& options) {
  DispatchPlan plan;
  plan.image_count = image_count;
  plan.iterations = options.iterations;
  plan.phase = options.phase;
  if (image_count == 0) {
    plan.status = PlanStatus::kInvalidImageCount;
    return plan;
  }
  if (!IsFrozenDefault(options)) {
    plan.status = PlanStatus::kUnsupportedOptions;
    return plan;
  }
  plan.status = PlanStatus::kReady;

  // The full phase is the unmodified controller sequence. The two individual
  // phases are its exact persisted-map split for one-reference mobile runs.
  plan.steps.reserve(static_cast<std::size_t>(image_count) * 551U + 1U);
  std::uint32_t rotation = 0;
  // N=1 走原串行路径(逐字保持官方形态);N>1 走交错,喂满 GPU。
  if (options.phase == PlanPhase::kFull ||
      options.phase == PlanPhase::kPhotometricOnly) {
    if (image_count > 1U) {
      AppendImagesInterleaved(&plan, Mode::kPhotometric, image_count,
                              &rotation);
    } else {
      AppendImage(&plan, Mode::kPhotometric, 0U, &rotation);
    }
  }
  if (options.phase == PlanPhase::kFull) {
    AppendBasic(&plan, Operation::kWaitPhotometricAll, Mode::kPhotometric,
                UINT32_MAX, rotation);
  }
  if (options.phase == PlanPhase::kFull ||
      options.phase == PlanPhase::kGeometricOnly) {
    if (image_count > 1U) {
      AppendImagesInterleaved(&plan, Mode::kGeometric, image_count, &rotation);
    } else {
      AppendImage(&plan, Mode::kGeometric, 0U, &rotation);
    }
  }
  plan.final_rotation = rotation;
  return plan;
}

DispatchStatus Dispatch(const DispatchPlan& plan,
                        const DispatchReadiness& readiness) noexcept {
  if (!plan.Validate()) return DispatchStatus::kInvalidPlan;
  if (!readiness.loader_ready) return DispatchStatus::kLoaderNotReady;
  if (!readiness.rng_ready) return DispatchStatus::kRngNotReady;
  if (!readiness.cost_sampler_ready) {
    return DispatchStatus::kCostSamplerNotReady;
  }
  return DispatchStatus::kExecutionNotImplemented;
}

}  // namespace pocketworld::official_dense::vulkan
