// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_DISPATCH_PLAN_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_DISPATCH_PLAN_H_

#include <cstdint>
#include <vector>

namespace pocketworld::official_dense::vulkan {

enum class Mode : std::uint8_t {
  kPhotometric,
  kGeometric,
};

// This mirrors PatchMatchController::Run(): when geometric consistency is
// requested, it first completes every photometric problem, persists those
// maps, and only then schedules geometric problems. A phone has one active
// reference arena, so these are separate command submissions rather than a
// simultaneous batch of complete PatchMatch states.
enum class PlanPhase : std::uint8_t {
  kFull,
  kPhotometricOnly,
  kGeometricOnly,
};

enum class Operation : std::uint8_t {
  kUploadReferenceImage,
  kReferenceFilter,
  kUploadSourceImages,
  kUploadSourceDepthMaps,
  kUploadTransformsAndCalibrations,
  kInitializeRng,
  kInitializeRandomDepth,
  kInitializeRandomNormal,
  kCopyPhotometricDepth,
  kCopyPhotometricNormal,
  kInitializeSelectionAndWorkspace,
  kBarrier,
  kInitialCost,
  kAllocateConsistencyMask,
  kClearConsistencyMask,
  kSweep,
  kRotateResource,
  kSelectCalibrationAndPose,
  kRotateFinalMask,
  kReadbackDepth,
  kReadbackNormal,
  kReadbackMask,
  kWaitPhotometricAll,
};

// This order is a mechanical representation of PatchMatchCuda::Rotate().
enum class RotatedResource : std::uint8_t {
  kNone,
  kRng,
  kDepth,
  kNormalVector,
  kNormalPlanes,
  kReferenceBytes,
  kReferenceWeightedSum,
  kReferenceWeightedSquaredSum,
  kSelectionToPrevious,
  kAllocateSelection,
  kCost,
};

inline constexpr std::uint8_t kSweepGeomConsistencyTerm = 1U << 0U;
inline constexpr std::uint8_t kSweepFilterPhotoConsistency = 1U << 1U;
inline constexpr std::uint8_t kSweepFilterGeomConsistency = 1U << 2U;

// Only the frozen official full pipeline is accepted in this phase. Supporting
// another official switch requires a separately frozen canonical plan.
struct PlanOptions {
  std::uint32_t iterations = 5;
  bool geom_consistency = true;
  bool filter = true;
  PlanPhase phase = PlanPhase::kFull;
};

enum class PlanStatus : std::uint8_t {
  kReady,
  kInvalidImageCount,
  kUnsupportedOptions,
};

struct PlanStep {
  Operation operation = Operation::kBarrier;
  Mode mode = Mode::kPhotometric;
  RotatedResource resource = RotatedResource::kNone;
  std::uint32_t image = UINT32_MAX;
  std::uint32_t iteration = UINT32_MAX;
  std::uint32_t sweep = UINT32_MAX;
  std::uint32_t rotation_before = 0;
  std::uint32_t rotation_after = 0;
  std::uint32_t calibration_rotation = 0;
  float perturbation = 0.0F;
  float prev_sel_prob_weight = 0.0F;
  std::uint8_t sweep_flags = 0;

  [[nodiscard]] bool operator==(const PlanStep& other) const noexcept;
};

struct DispatchPlan {
  PlanStatus status = PlanStatus::kInvalidImageCount;
  std::uint32_t image_count = 0;
  std::uint32_t iterations = 0;
  std::uint32_t final_rotation = 0;
  PlanPhase phase = PlanPhase::kFull;
  std::vector<PlanStep> steps;

  // Validation checks the complete canonical operation sequence and sweep
  // parameters without allocating another plan.
  [[nodiscard]] bool Validate() const noexcept;
};

[[nodiscard]] DispatchPlan CreateDispatchPlan(
    std::uint32_t image_count,
    const PlanOptions& options = PlanOptions{});

struct DispatchReadiness {
  bool loader_ready = false;
  bool rng_ready = false;
  bool cost_sampler_ready = false;
};

enum class DispatchStatus : std::uint8_t {
  kInvalidPlan,
  kLoaderNotReady,
  kRngNotReady,
  kCostSamplerNotReady,
  // This module intentionally records no Vulkan commands yet.
  kExecutionNotImplemented,
};

// Fail-closed gate for the future command recorder. It never executes GPU work.
[[nodiscard]] DispatchStatus Dispatch(
    const DispatchPlan& plan,
    const DispatchReadiness& readiness) noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_HOST_DISPATCH_PLAN_H_
