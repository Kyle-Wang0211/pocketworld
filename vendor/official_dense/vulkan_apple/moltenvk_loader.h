// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_MOLTENVK_LOADER_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_MOLTENVK_LOADER_H_

#include "../vulkan_host/vulkan_host.h"

namespace pocketworld::official_dense::vulkan {

// Returns the externally injected Vulkan entry point required by VulkanHost on
// Apple. This function is compiled only by the opt-in MoltenVK build closure.
[[nodiscard]] ExternalLoader MoltenVkExternalLoader() noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_MOLTENVK_LOADER_H_
