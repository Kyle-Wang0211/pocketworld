/*
 * Copyright (c) 2014-2026 SEACAVE
 * Copyright (c) 2026, PocketWorld contributors
 *
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Cross-platform C++17 reference for the uint32 RNG expressions in OpenMVS
 * libs/MVS/PatchMatchMetal.metal. This is a compatibility reference, not the
 * unrelated canonical 64-bit PCG family implementation.
 */

#ifndef POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_REFERENCE_H_
#define POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_REFERENCE_H_

#include <cstdint>

namespace pocketworld::official_dense::vulkan::rng::openmvs_pcg {

inline constexpr char kUpstreamRepository[] =
    "https://github.com/cdcseacave/openMVS";
inline constexpr char kUpstreamCommit[] =
    "8efd9c48e7249b4256ca3a778cb6bf062b871771";
inline constexpr char kUpstreamSourcePath[] =
    "libs/MVS/PatchMatchMetal.metal";
inline constexpr char kUpstreamSourceSha256[] =
    "1e614e559d1b7ae6fb29e2525bae784023fc0b3b5f068dc46c24027cab9e6a68";
inline constexpr char kUpstreamLicenseSha256[] =
    "0f072d4a0ef59e7f6864bb45629c37417ccef63025b58f4073109d1c830bc55f";

inline constexpr std::uint32_t kSeedXMultiplier = 1973u;
inline constexpr std::uint32_t kSeedYMultiplier = 9277u;
inline constexpr std::uint32_t kSeedIncrement = 1234u;
inline constexpr std::uint32_t kStateMultiplier = 747796405u;
inline constexpr std::uint32_t kStateIncrement = 2891336453u;
inline constexpr std::uint32_t kOutputMultiplier = 277803737u;
inline constexpr std::uint32_t kUniformMask = 0x00ffffffu;
inline constexpr float kUniformDenominator = 16777216.0f;

// std::uint32_t arithmetic specifies the required modulo-2^32 behavior.
constexpr std::uint32_t SeedForPixel(const std::uint32_t x,
                                     const std::uint32_t y) noexcept {
  return x * kSeedXMultiplier + y * kSeedYMultiplier + kSeedIncrement;
}

constexpr std::uint32_t NextState(const std::uint32_t state) noexcept {
  return state * kStateMultiplier + kStateIncrement;
}

constexpr std::uint32_t OutputFromState(const std::uint32_t state) noexcept {
  const std::uint32_t word =
      ((state >> ((state >> 28u) + 4u)) ^ state) * kOutputMultiplier;
  return (word >> 22u) ^ word;
}

constexpr std::uint32_t UniformBits(const std::uint32_t output) noexcept {
  return output & kUniformMask;
}

constexpr float UniformFromOutput(const std::uint32_t output) noexcept {
  return static_cast<float>(UniformBits(output)) / kUniformDenominator;
}

constexpr std::uint32_t Next(std::uint32_t* const state) noexcept {
  *state = NextState(*state);
  return OutputFromState(*state);
}

constexpr float NextUniform(std::uint32_t* const state) noexcept {
  return UniformFromOutput(Next(state));
}

}  // namespace pocketworld::official_dense::vulkan::rng::openmvs_pcg

#endif  // POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_REFERENCE_H_
