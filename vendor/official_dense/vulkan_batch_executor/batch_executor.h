// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_BATCH_EXECUTOR_BATCH_EXECUTOR_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_BATCH_EXECUTOR_BATCH_EXECUTOR_H_

#include "../vulkan_resource_arena/resource_arena.h"
#include "../vulkan_runtime/vulkan_runtime.h"

namespace pocketworld::official_dense::vulkan::batch_executor {

inline constexpr std::int32_t kOfficialWindowRadius = 5;
inline constexpr std::int32_t kOfficialWindowStep = 1;

struct BatchExecuteRequest {
  const resource_arena::ResourceArenaBatch *arena = nullptr;
  runtime::NativeContext native{};
  runtime::ShaderBundle shaders{};
  PlanOptions plan_options{};
  // [BATCH-REF] 一次 sweep dispatch 覆盖的 reference 数,必须与建 arena 时
  // 传给 ResourceArenaInput::batch_count 的值一致。
  std::uint32_t batch_count = 1;
};

// Creates the canonical five-iteration dispatch plan for the complete arena
// batch and records it through the production runtime. Certification and
// canonical-binary gates remain owned by runtime::Record and cannot be
// overridden through this API.
[[nodiscard]] runtime::RecordResult
ExecuteResourceArenaBatch(const BatchExecuteRequest &request) noexcept;

#if defined(PW_OFFICIAL_DENSE_VULKAN_DIAGNOSTIC)

// Dedicated benchmark-App seam. It is absent from normal builds and leaves the
// production certification path in ExecuteResourceArenaBatch unchanged.
[[nodiscard]] runtime::RecordResult ExecuteResourceArenaBatchForDiagnostic(
    const BatchExecuteRequest &request) noexcept;

#endif

#if defined(PW_OFFICIAL_DENSE_VULKAN_RUNTIME_TESTING)

// Test-only end-to-end seam. Production cannot supply certifications or a fake
// backend because both types and this entry point are macro-gated.
[[nodiscard]] runtime::RecordResult ExecuteResourceArenaBatchForTesting(
    const BatchExecuteRequest &request,
    const runtime::TestCertifications &certifications,
    runtime::FakeDispatchBackend *backend) noexcept;

#endif

}  // namespace pocketworld::official_dense::vulkan::batch_executor

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_BATCH_EXECUTOR_BATCH_EXECUTOR_H_
