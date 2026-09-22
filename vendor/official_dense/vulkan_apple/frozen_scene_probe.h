// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_PROBE_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_PROBE_H_

#include <array>

namespace pocketworld::official_dense::vulkan {

struct FrozenSceneProbeResult {
  bool ok = false;
  std::array<char, 1024> json{};
};

// Benchmark-only real-input execution. The first reference uses the source
// ordering exported by COLMAP; its resulting geometric map is intentionally
// not presented as a full-132-view CUDA parity result until the all-view
// scheduler and map persistence gate have passed.
[[nodiscard]] FrozenSceneProbeResult RunFrozenSceneInputProbe(
    const char* executable_path) noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_PROBE_H_
