// Copyright (c), ETH Zurich and UNC Chapel Hill.
// All rights reserved.
//
// Host reference for the curandStateXORWOW behavior used by the pinned
// COLMAP 4.1.1 PatchMatch implementation when sequence == offset == 0.

#ifndef POCKETWORLD_OFFICIAL_DENSE_COLMAP_XORWOW_REFERENCE_H_
#define POCKETWORLD_OFFICIAL_DENSE_COLMAP_XORWOW_REFERENCE_H_

#include <cstdint>

namespace pocketworld::official_dense::vulkan::rng::colmap_xorwow {

struct State {
  std::uint32_t v0;
  std::uint32_t v1;
  std::uint32_t v2;
  std::uint32_t v3;
  std::uint32_t v4;
  std::uint32_t d;
};

constexpr State Initialize(const std::uint64_t seed) noexcept {
  const std::uint32_t seed_low =
      static_cast<std::uint32_t>(seed) ^ 0xaad26b49U;
  const std::uint32_t seed_high =
      static_cast<std::uint32_t>(seed >> 32U) ^ 0xf7dcefddU;
  const std::uint32_t mix_low = 1099087573U * seed_low;
  const std::uint32_t mix_high = 2591861531U * seed_high;
  return {
      123456789U + mix_low,
      362436069U ^ mix_low,
      521288629U + mix_high,
      88675123U ^ mix_high,
      5783321U + mix_low,
      6615241U + mix_low + mix_high,
  };
}

constexpr std::uint32_t Next(State* const state) noexcept {
  const std::uint32_t t = state->v0 ^ (state->v0 >> 2U);
  state->v0 = state->v1;
  state->v1 = state->v2;
  state->v2 = state->v3;
  state->v3 = state->v4;
  state->v4 = (state->v4 ^ (state->v4 << 4U)) ^ (t ^ (t << 1U));
  state->d += 362437U;
  return state->v4 + state->d;
}

inline float UniformFromOutput(const std::uint32_t output) noexcept {
  constexpr float kTwoToMinus32 = 2.3283064365386963e-10F;
  return static_cast<float>(output) * kTwoToMinus32 + kTwoToMinus32;
}

inline float Uniform(State* const state) noexcept {
  return UniformFromOutput(Next(state));
}

}  // namespace pocketworld::official_dense::vulkan::rng::colmap_xorwow

#endif  // POCKETWORLD_OFFICIAL_DENSE_COLMAP_XORWOW_REFERENCE_H_
