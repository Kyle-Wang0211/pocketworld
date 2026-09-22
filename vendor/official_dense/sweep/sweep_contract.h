// Copyright (c) 2026, PocketWorld contributors.
//
// SPDX-License-Identifier: BSD-3-Clause
//
// Fail-closed host contract for the mechanical Vulkan translation of COLMAP
// 4.1.1 SweepFromTopToBottom. This is not dispatchable until the exact CUDA
// XORWOW stream and target texture-sampling parity have both been proven.

#ifndef POCKETWORLD_OFFICIAL_DENSE_SWEEP_CONTRACT_H_
#define POCKETWORLD_OFFICIAL_DENSE_SWEEP_CONTRACT_H_

#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstring>

#include "../rng/openmvs_pcg_reference.h"

namespace pocketworld::official_dense::vulkan::sweep {

inline constexpr char kUpstreamCommit[] =
    "a0d785fba74b2664f31edc4a29026a8b27c00f67";
inline constexpr char kPatchMatchCudaSha256[] =
    "1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448";
inline constexpr char kOpenMvsCommit[] =
    "8efd9c48e7249b4256ca3a778cb6bf062b871771";
inline constexpr char kPatchMatchMetalSha256[] =
    "1e614e559d1b7ae6fb29e2525bae784023fc0b3b5f068dc46c24027cab9e6a68";

inline constexpr std::uint32_t kLocalSizeX = 32;
inline constexpr std::uint32_t kLocalSizeY = 1;
inline constexpr std::uint32_t kLocalSizeZ = 1;
inline constexpr std::uint32_t kCandidatesPerPixel = 5;
inline constexpr std::uint32_t kRngReadRow = 0;
inline constexpr std::uint32_t kRngWriteRow = 0;
inline constexpr std::uint32_t kDefaultNumSamples = 15;
inline constexpr float kBinary32Epsilon = 1.1920928955078125e-7f;

// Specialization IDs 2/3/4 are independent booleans. Host mask 7 enables all
// three on the existing final scheduled sweep; it never requests sweep 21.
inline constexpr std::uint32_t kGeomConsistencySpecializationId = 2;
inline constexpr std::uint32_t kFilterPhotoSpecializationId = 3;
inline constexpr std::uint32_t kFilterGeomSpecializationId = 4;
inline constexpr std::uint32_t kGeomConsistencyMaskBit = 1;
inline constexpr std::uint32_t kFilterPhotoMaskBit = 2;
inline constexpr std::uint32_t kFilterGeomMaskBit = 4;
inline constexpr std::uint32_t kFinalGeometricMask = 7;
inline constexpr bool kFinalMaskRequiresAdditionalSweep = false;

// PatchPC::reserved is the uint32 field at byte 28. Sweep consumes those same
// four bytes as the precomputed float32 NCC normalization factor. These helpers
// give the host a C++17-safe, non-numeric bit conversion; casting is forbidden.
inline constexpr std::size_t kNccNormFactorPatchPcByteOffset = 28;

inline float ComputeNccCostNormFactor(const float ncc_sigma) noexcept {
  constexpr float kPi = 3.14159265358979323846f;
  return 2.0f /
         (std::sqrt(2.0f * kPi) * ncc_sigma *
          std::erf(2.0f / (ncc_sigma * 1.414213562f)));
}

inline std::uint32_t EncodeNccNormFactorForPatchPcReservedBits(
    const float normalization) noexcept {
  std::uint32_t bits = 0;
  std::memcpy(&bits, &normalization, sizeof(bits));
  return bits;
}

inline float DecodeNccNormFactorFromPatchPcReservedBits(
    const std::uint32_t bits) noexcept {
  float normalization = 0.0f;
  std::memcpy(&normalization, &bits, sizeof(normalization));
  return normalization;
}

// Frozen order of the five {depth, normal} candidates in the CUDA kernel.
enum Candidate : std::uint32_t {
  kCurrentDepthCurrentNormal = 0,
  kPreviousDepthPreviousNormal = 1,
  kRandomDepthRandomNormal = 2,
  kCurrentDepthRandomNormal = 3,
  kRandomDepthCurrentNormal = 4,
};

template <std::size_t kCount>
constexpr std::size_t FindMinCostLastTie(
    const float (&costs)[kCount]) noexcept {
  float min_cost = costs[0];
  std::size_t min_cost_idx = 0;
  for (std::size_t idx = 1; idx < kCount; ++idx) {
    if (costs[idx] <= min_cost) {
      min_cost = costs[idx];
      min_cost_idx = idx;
    }
  }
  return min_cost_idx;
}

// Literal two-pass translation. Deliberately no zero-sum special case.
inline void TransformPDFToCDF(float* const probs,
                              const std::size_t num_probs) noexcept {
  float prob_sum = 0.0f;
  for (std::size_t index = 0; index < num_probs; ++index) {
    prob_sum += probs[index];
  }
  const float inv_prob_sum = 1.0f / prob_sum;

  float cumulative_probability = 0.0f;
  for (std::size_t index = 0; index < num_probs; ++index) {
    const float probability = probs[index] * inv_prob_sum;
    cumulative_probability += probability;
    probs[index] = cumulative_probability;
  }
}

// CUDA scans low-to-high and accepts the first CDF value strictly greater
// than curand_uniform(state) - FLT_EPSILON. Equality advances to the next item.
inline std::int32_t StrictCDFSelection(const float* const cdf,
                                       const std::size_t num_probs,
                                       const float draw) noexcept {
  for (std::size_t index = 0; index < num_probs; ++index) {
    if (cdf[index] > draw) {
      return static_cast<std::int32_t>(index);
    }
  }
  return -1;
}

constexpr std::uint32_t PcgDrawsPerRow(
    const std::uint32_t perturb_normal_trials,
    const std::uint32_t num_samples) noexcept {
  return 1u + 3u * perturb_normal_trials + num_samples;
}

constexpr float SelectionDrawFromPcgUniform(const float uniform) noexcept {
  return uniform - kBinary32Epsilon;
}

constexpr std::uint32_t AdvancePcgStateForDraws(
    std::uint32_t state,
    const std::uint32_t draw_count) noexcept {
  for (std::uint32_t draw = 0; draw < draw_count; ++draw) {
    state = rng::openmvs_pcg::NextState(state);
  }
  return state;
}

constexpr std::uint32_t AdvancePcgStateForRow(
    const std::uint32_t state,
    const std::uint32_t perturb_normal_trials,
    const std::uint32_t num_samples) noexcept {
  return AdvancePcgStateForDraws(
      state, PcgDrawsPerRow(perturb_normal_trials, num_samples));
}

constexpr std::uint32_t AdvancePcgStateForRows(
    std::uint32_t state,
    const std::uint32_t row_count,
    const std::uint32_t perturb_normal_trials,
    const std::uint32_t num_samples) noexcept {
  for (std::uint32_t row = 0; row < row_count; ++row) {
    state = AdvancePcgStateForRow(
        state, perturb_normal_trials, num_samples);
  }
  return state;
}

constexpr std::uint32_t AdvancePcgStateForRowWithModes(
    const std::uint32_t state,
    const std::uint32_t perturb_normal_trials,
    const std::uint32_t num_samples,
    const bool /* geometric_consistency */,
    const bool /* filter_photo_consistency */,
    const bool /* filter_geometric_consistency */) noexcept {
  return AdvancePcgStateForRow(
      state, perturb_normal_trials, num_samples);
}

enum class BackendStatus : std::uint32_t {
  kUnavailableUntilCudaXorwowAndTextureParity = 0,
};

inline constexpr BackendStatus kBackendStatus =
    BackendStatus::kUnavailableUntilCudaXorwowAndTextureParity;

constexpr bool CanDispatchSweepBackend() noexcept {
  return false;
}

}  // namespace pocketworld::official_dense::vulkan::sweep

#endif  // POCKETWORLD_OFFICIAL_DENSE_SWEEP_CONTRACT_H_
