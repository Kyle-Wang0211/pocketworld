// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../vulkan_resource_arena/resource_arena_plan.h"

namespace arena =
    pocketworld::official_dense::vulkan::resource_arena;
using pocketworld::official_dense::vulkan::PlanPhase;

namespace {

bool ParseU64(const char* const text, std::uint64_t* const output) noexcept {
  if (text == nullptr || output == nullptr || text[0] == '\0') return false;
  const char* const end = text + std::strlen(text);
  const auto parsed = std::from_chars(text, end, *output);
  return parsed.ec == std::errc{} && parsed.ptr == end && *output != 0U;
}

bool ParsePhase(const char* const text, PlanPhase* const output) noexcept {
  if (text == nullptr || output == nullptr) return false;
  if (std::strcmp(text, "photo") == 0) {
    *output = PlanPhase::kPhotometricOnly;
    return true;
  }
  if (std::strcmp(text, "geometric") == 0) {
    *output = PlanPhase::kGeometricOnly;
    return true;
  }
  if (std::strcmp(text, "full") == 0) {
    *output = PlanPhase::kFull;
    return true;
  }
  return false;
}

}  // namespace

int main(const int argc, char** const argv) {
  std::uint64_t width = 0U;
  std::uint64_t height = 0U;
  std::uint64_t sources = 0U;
  PlanPhase phase = PlanPhase::kFull;
  bool saw_phase = false;
  bool streamed_source_depth = false;
  for (int index = 1; index < argc; ++index) {
    if (std::strcmp(argv[index], "--streamed-source-depth") == 0) {
      streamed_source_depth = true;
      continue;
    }
    if (index + 1 >= argc) {
      std::fprintf(stderr, "missing option value\n");
      return 2;
    }
    const char* const option = argv[index];
    const char* const value = argv[++index];
    if (std::strcmp(option, "--width") == 0) {
      if (!ParseU64(value, &width)) return 2;
    } else if (std::strcmp(option, "--height") == 0) {
      if (!ParseU64(value, &height)) return 2;
    } else if (std::strcmp(option, "--sources") == 0) {
      if (!ParseU64(value, &sources)) return 2;
    } else if (std::strcmp(option, "--phase") == 0) {
      if (!ParsePhase(value, &phase)) return 2;
      saw_phase = true;
    } else {
      std::fprintf(stderr, "unknown option: %s\n", option);
      return 2;
    }
  }
  if (width == 0U || height == 0U || sources == 0U || !saw_phase ||
      (phase == PlanPhase::kPhotometricOnly && streamed_source_depth)) {
    std::fprintf(stderr, "invalid resource memory report request\n");
    return 2;
  }

  const arena::ResourceArenaInput input{
      width, height, width, height, sources, std::max(width, height), phase,
      streamed_source_depth,
      phase == PlanPhase::kGeometricOnly && streamed_source_depth};
  arena::ResourceArenaPlan plan;
  arena::ResourceArenaMemorySummary memory;
  if (!arena::BuildResourceArenaPlan(input, &plan) ||
      !arena::SummarizeResourceArenaMemory(plan, &memory)) {
    std::fprintf(stderr, "resource memory plan failed\n");
    return 1;
  }
  std::printf(
      "{\"width\":%llu,\"height\":%llu,\"source_count\":%llu,"
      "\"device_local_bytes\":%llu,\"host_upload_bytes\":%llu,"
      "\"host_readback_bytes\":%llu,\"host_values_bytes\":%llu,"
      "\"total_bytes\":%llu,\"allocation_count\":%zu}\n",
      static_cast<unsigned long long>(width),
      static_cast<unsigned long long>(height),
      static_cast<unsigned long long>(sources),
      static_cast<unsigned long long>(memory.device_local_bytes),
      static_cast<unsigned long long>(memory.host_upload_bytes),
      static_cast<unsigned long long>(memory.host_readback_bytes),
      static_cast<unsigned long long>(memory.host_values_bytes),
      static_cast<unsigned long long>(memory.total_bytes),
      memory.allocation_count);
  return 0;
}
