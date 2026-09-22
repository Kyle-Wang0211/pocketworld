// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_LOADER_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_LOADER_H_

#include <array>
#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace pocketworld::official_dense::vulkan {

// This is a benchmark-fixture packet, generated only by the host helper that
// invokes COLMAP mvs::Model. It carries camera/source decisions verbatim and
// intentionally contains no view-selection or reconstruction logic.
struct FrozenSceneImage final {
  std::uint32_t index = 0U;
  std::uint32_t width = 0U;
  std::uint32_t height = 0U;
  std::string image_name;
  std::array<float, 9> K{};
  std::array<float, 9> R{};
  std::array<float, 3> T{};
  float depth_min = 0.0F;
  float depth_max = 0.0F;
  std::vector<std::int32_t> source_indices;
};

struct FrozenScene final {
  std::vector<FrozenSceneImage> images;
};

[[nodiscard]] bool LoadFrozenScene(const std::filesystem::path& packet_path,
                                   FrozenScene* out,
                                   std::string* detail) noexcept;

// Reads only frozen P5/8-bit PGM files written through COLMAP Bitmap::Write.
// No color conversion, resize, orientation transform, or decoder policy is
// present in this portable reader.
[[nodiscard]] bool LoadFrozenGrayPgm(
    const std::filesystem::path& path,
    std::uint32_t expected_width,
    std::uint32_t expected_height,
    std::vector<std::uint8_t>* out,
    std::string* detail) noexcept;

}  // namespace pocketworld::official_dense::vulkan

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_APPLE_FROZEN_SCENE_LOADER_H_
