// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "batch_executor.h"

#include <limits>

#include "../vulkan_host/dispatch_plan.h"

namespace pocketworld::official_dense::vulkan::batch_executor {
namespace {

runtime::RecordResult InvalidBatch(const char *const detail) noexcept {
  runtime::RecordResult result;
  result.status = runtime::RuntimeStatus::kInvalidRequest;
  result.detail = detail;
  return result;
}

bool BuildRuntimeRequest(const BatchExecuteRequest &input,
                         DispatchPlan *const plan,
                         runtime::RecordRequest *const output) {
  if (plan == nullptr || output == nullptr || input.arena == nullptr ||
      input.arena->empty() || input.arena->images() == nullptr ||
      input.arena->image_count() >
          static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max())) {
    return false;
  }
  *plan = CreateDispatchPlan(
      static_cast<std::uint32_t>(input.arena->image_count()),
      input.plan_options);
  if (plan->status != PlanStatus::kReady) return false;
  runtime::RecordRequest request;
  request.plan = plan;
  request.native = input.native;
  request.shaders = input.shaders;
  request.images = input.arena->images();
  request.image_count = input.arena->image_count();
  request.window_radius = kOfficialWindowRadius;
  request.window_step = kOfficialWindowStep;
  request.batch_count = input.batch_count == 0U ? 1U : input.batch_count;
  *output = request;
  return true;
}

}  // namespace

runtime::RecordResult
ExecuteResourceArenaBatch(const BatchExecuteRequest &request) noexcept {
  try {
    DispatchPlan plan;
    runtime::RecordRequest runtime_request;
    if (!BuildRuntimeRequest(request, &plan, &runtime_request)) {
      return InvalidBatch("resource arena batch cannot form a canonical plan");
    }
    return runtime::Record(runtime_request);
  } catch (...) {
    return InvalidBatch("resource arena batch execution setup failed");
  }
}

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

runtime::RecordResult ExecuteResourceArenaBatchForDiagnostic(
    const BatchExecuteRequest &request) noexcept {
  try {
    DispatchPlan plan;
    runtime::RecordRequest runtime_request;
    if (!BuildRuntimeRequest(request, &plan, &runtime_request)) {
      return InvalidBatch("resource arena batch cannot form a canonical plan");
    }
    return runtime::RecordNativeForDiagnostic(runtime_request);
  } catch (...) {
    return InvalidBatch("diagnostic resource arena execution setup failed");
  }
}

#endif

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

runtime::RecordResult ExecuteResourceArenaBatchForTesting(
    const BatchExecuteRequest &request,
    const runtime::TestCertifications &certifications,
    runtime::FakeDispatchBackend *const backend) noexcept {
  try {
    DispatchPlan plan;
    runtime::RecordRequest runtime_request;
    if (!BuildRuntimeRequest(request, &plan, &runtime_request)) {
      return InvalidBatch("resource arena batch cannot form a canonical plan");
    }
    return runtime::RecordForTesting(runtime_request, certifications, backend);
  } catch (...) {
    return InvalidBatch("resource arena batch execution setup failed");
  }
}

#endif

}  // namespace pocketworld::official_dense::vulkan::batch_executor
