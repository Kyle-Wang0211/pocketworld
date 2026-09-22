// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DEVICE_PROBE_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DEVICE_PROBE_H_

#include <array>

namespace pocketworld::official_dense::vulkan {

struct DeviceProbeResult {
  bool ok = false;
  std::array<char, 512> json{};
};

// Diagnostic only. This does not change any production runtime certification
// gate and uses a dedicated application bundle identifier.
[[nodiscard]] DeviceProbeResult RunMoltenVkDeviceProbe() noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DEVICE_PROBE_H_
