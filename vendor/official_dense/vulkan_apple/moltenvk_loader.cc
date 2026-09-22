// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "moltenvk_loader.h"

#include <cstring>

#include <vulkan/vulkan.h>

namespace pocketworld::official_dense::vulkan {

ExternalLoader MoltenVkExternalLoader() noexcept {
  // ExternalLoader deliberately avoids exposing Vulkan SDK types. Copying the
  // representation avoids a non-portable function-pointer-to-object-pointer
  // cast while retaining a strong link-time reference to MoltenVK's loader.
  const PFN_vkGetInstanceProcAddr entry_point = &vkGetInstanceProcAddr;
  void* address = nullptr;
  static_assert(sizeof(address) == sizeof(entry_point));
  std::memcpy(&address, &entry_point, sizeof(address));
  return ExternalLoader{address};
}

}  // namespace pocketworld::official_dense::vulkan
