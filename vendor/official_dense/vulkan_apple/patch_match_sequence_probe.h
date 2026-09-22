// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_PATCH_MATCH_SEQUENCE_PROBE_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_PATCH_MATCH_SEQUENCE_PROBE_H_

#include <array>

namespace pocketworld::official_dense::vulkan {

struct PatchMatchSequenceProbeResult {
  bool ok = false;
  std::array<char, 1024> json{};
};

// Runs the real resource arena and canonical five-iteration PatchMatch command
// sequence inside the isolated benchmark App. Production certification gates
// remain unchanged; the JSON explicitly labels the diagnostic override.
[[nodiscard]] PatchMatchSequenceProbeResult
RunMoltenVkPatchMatchSequenceProbe() noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_PATCH_MATCH_SEQUENCE_PROBE_H_
