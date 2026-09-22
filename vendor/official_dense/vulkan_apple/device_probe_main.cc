// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "device_probe.h"
#include "device_probe_main.h"
#include "frozen_scene_probe.h"
#include "patch_match_sequence_probe.h"

#include <cstdlib>
#include <cstdio>

int RunDeviceProbeSequence(const char* const executable_path) noexcept {
#if defined(PW_DENSE_FROZEN_SCENE_BUNDLE)
  const char* const real_mode = std::getenv("PW_DENSE_PROBE_REAL_MODE");
  if (real_mode != nullptr && real_mode[0] != '\0') {
    const auto frozen_scene = pocketworld::official_dense::vulkan::
        RunFrozenSceneInputProbe(executable_path);
    std::printf("%s\n", frozen_scene.json.data());
    return frozen_scene.ok ? 0 : 1;
  }
#endif
  const auto reference =
      pocketworld::official_dense::vulkan::RunMoltenVkDeviceProbe();
  std::printf("%s\n", reference.json.data());
  if (!reference.ok) return 1;
  const auto patch_match = pocketworld::official_dense::vulkan::
      RunMoltenVkPatchMatchSequenceProbe();
  std::printf("%s\n", patch_match.json.data());
  if (!patch_match.ok) return 1;
#if defined(PW_DENSE_FROZEN_SCENE_BUNDLE)
  const char* const synthetic_only =
      std::getenv("PW_DENSE_PROBE_SYNTHETIC_ONLY");
  if (synthetic_only != nullptr && synthetic_only[0] != '\0') return 0;
  const auto frozen_scene = pocketworld::official_dense::vulkan::
      RunFrozenSceneInputProbe(executable_path);
  std::printf("%s\n", frozen_scene.json.data());
  return frozen_scene.ok ? 0 : 1;
#else
  return 0;
#endif
}
