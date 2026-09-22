// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DIAGNOSTIC_MAP_EXPORT_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DIAGNOSTIC_MAP_EXPORT_H_

#include <filesystem>
#include <string>

#include "../vulkan_resource_arena/resource_arena.h"

namespace pocketworld::official_dense::vulkan {

// Benchmark-only export of already-completed host-coherent diagnostic buffers.
// The file representation is the exact COLMAP dense-workspace matrix/graph
// representation. This function adds no filtering, fusion, resampling, or
// map value transformation.
[[nodiscard]] bool WriteDiagnosticColmapMaps(
    const std::filesystem::path& workspace_root,
    const std::string& image_name,
    const resource_arena::DiagnosticImageReadback& readback,
    std::string* detail) noexcept;

// Exact first pass of PatchMatchController::Run(). The caller persists every
// reference image's photometric maps before it permits any geometric pass.
[[nodiscard]] bool WriteDiagnosticPhotometricMaps(
    const std::filesystem::path& workspace_root,
    const std::string& image_name,
    const resource_arena::DiagnosticImageReadback& readback,
    std::string* detail) noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_DIAGNOSTIC_MAP_EXPORT_H_
