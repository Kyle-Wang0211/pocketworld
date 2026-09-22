// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#ifndef POCKETWORLD_OFFICIAL_DENSE_VULKAN_SHADER_BUNDLE_SHADER_BUNDLE_H_
#define POCKETWORLD_OFFICIAL_DENSE_VULKAN_SHADER_BUNDLE_SHADER_BUNDLE_H_

#include <array>
#include <cstddef>

#include "../vulkan_runtime/vulkan_runtime.h"

namespace pocketworld::official_dense::vulkan::shader_bundle {

struct FrozenShaderIdentity {
  runtime::PipelineKind kind;
  const char *source_path;
  const char *source_sha256;
  const char *spirv_sha256;
  std::size_t word_count;
};

// These identities are immutable build facts, not caller declarations.
[[nodiscard]] const std::array<FrozenShaderIdentity, runtime::kShaderCount> &
FrozenShaderManifest() noexcept;

// Owns all words for process lifetime. No path, bytes, or digest is accepted
// from a caller, and runtime certification gates remain authoritative.
[[nodiscard]] const runtime::ShaderBundle &CanonicalShaderBundle() noexcept;

}  // namespace pocketworld::official_dense::vulkan::shader_bundle

#endif  // POCKETWORLD_OFFICIAL_DENSE_VULKAN_SHADER_BUNDLE_SHADER_BUNDLE_H_
