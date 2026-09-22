#ifndef POCKETWORLD_OFFICIAL_DENSE_COST_OPS_SAMPLER_CONTRACT_H_
#define POCKETWORLD_OFFICIAL_DENSE_COST_OPS_SAMPLER_CONTRACT_H_

// Copyright (c), ETH Zurich and UNC Chapel Hill.
// All rights reserved.
// See cost_ops.glsl for the complete retained COLMAP BSD license notice.

namespace pocketworld::official_dense::cost_ops {

// COLMAP 4.1.1 a0d785f texture contract for patch_match_cuda.cu.
// These names intentionally mirror Vulkan API constants without making this
// small fail-closed contract header depend on a platform Vulkan SDK.
inline constexpr const char* kSourceImageFormat = "VK_FORMAT_R8_UNORM";
inline constexpr const char* kSourceImageMinFilter = "VK_FILTER_LINEAR";
inline constexpr const char* kSourceImageMagFilter = "VK_FILTER_LINEAR";
inline constexpr const char* kSourceDepthFormat = "VK_FORMAT_R32_SFLOAT";
inline constexpr const char* kSourceDepthMinFilter = "VK_FILTER_NEAREST";
inline constexpr const char* kSourceDepthMagFilter = "VK_FILTER_NEAREST";
inline constexpr const char* kAddressMode =
    "VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER";
inline constexpr const char* kBorderColor =
    "VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK";
inline constexpr bool kUnnormalizedCudaCoordinates = true;
inline constexpr bool kVulkanShaderConvertsToNormalizedCoordinates = true;

// Vulkan permits implementation-dependent sub-texel filtering precision. Do
// not enable an equality/parity claim until the same frozen coordinates have
// been sampled by official CUDA on RTX 5090 and by every target Vulkan backend.
inline constexpr bool kRequiresCuda5090TextureFixture = true;
inline constexpr bool TextureFixtureAllowsParity() {
  return false;
}

}  // namespace pocketworld::official_dense::cost_ops

#endif  // POCKETWORLD_OFFICIAL_DENSE_COST_OPS_SAMPLER_CONTRACT_H_
