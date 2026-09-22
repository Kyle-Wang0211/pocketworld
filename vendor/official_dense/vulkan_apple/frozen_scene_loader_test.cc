// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "frozen_scene_loader.h"

#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc != 3) {
    std::fprintf(stderr, "usage: %s PACKET FIRST_PGM\n", argv[0]);
    return 2;
  }
  pocketworld::official_dense::vulkan::FrozenScene scene;
  std::string detail;
  if (!pocketworld::official_dense::vulkan::LoadFrozenScene(argv[1], &scene,
                                                              &detail) ||
      scene.images.size() != 132U || scene.images.front().index != 0U ||
      scene.images.front().source_indices.size() != 10U ||
      !(scene.images.front().depth_min > 0.0F) ||
      !(scene.images.front().depth_max >= scene.images.front().depth_min)) {
    std::fprintf(stderr, "scene: %s\n", detail.c_str());
    return 1;
  }
  std::vector<std::uint8_t> pixels;
  if (!pocketworld::official_dense::vulkan::LoadFrozenGrayPgm(
          argv[2], scene.images.front().width, scene.images.front().height,
          &pixels, &detail) || pixels.size() != 768U * 576U) {
    std::fprintf(stderr, "pgm: %s\n", detail.c_str());
    return 1;
  }
  std::printf("ok images=%zu width=%u height=%u sources=%zu pixels=%zu\n",
              scene.images.size(), scene.images.front().width,
              scene.images.front().height,
              scene.images.front().source_indices.size(), pixels.size());
  return 0;
}
