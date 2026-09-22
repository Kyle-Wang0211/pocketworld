/*
 * Copyright (c) 2014-2026 SEACAVE
 * Copyright (c), ETH Zurich and UNC Chapel Hill.
 * Copyright (c) 2026, PocketWorld contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * C++17 oracle for the
 * COLMAP initialization control flow + OpenMVS-PCG adaptation.
 * This is not exact CUDA/XORWOW parity. It is also not byte-
 * identical OpenMVS Metal native initialization because that path initializes
 * the normal before the depth.
 *
 * Order under test: state init -> depth consumes exactly one draw.
 * Then normal continues the persisted state and consumes Marsaglia pairs.
 * The corresponding GLSL uses precise values so SPIR-V emits NoContraction.
 * Transcendental sqrt and GPU FMA implementation details mean normal float bits
 * are diagnostic only; no CUDA/Metal bit-parity claim is made for them.
 * COLMAP 4.1.1 revision: a0d785fba74b2664f31edc4a29026a8b27c00f67.
 * OpenMVS PCG revision: 8efd9c48e7249b4256ca3a778cb6bf062b871771.
 */

#ifndef POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_INITIALIZATION_REFERENCE_H_
#define POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_INITIALIZATION_REFERENCE_H_

#include "openmvs_pcg_reference.h"

#include <cmath>
#include <cstdint>

namespace pocketworld::official_dense::vulkan::rng::openmvs_pcg {

struct InitializationResult {
  std::uint32_t state;
  std::uint32_t draw_count;
  std::uint32_t rejected_pairs;
  float depth;
  float normal[3];
};

// Volatile round trips model distinct float32 SPIR-V operations and prevent a
// host compiler from silently introducing an FMA into this reference oracle.
inline float F32Add(const float lhs, const float rhs) noexcept {
  const volatile float result = lhs + rhs;
  return result;
}
inline float F32Sub(const float lhs, const float rhs) noexcept {
  const volatile float result = lhs - rhs;
  return result;
}
inline float F32Mul(const float lhs, const float rhs) noexcept {
  const volatile float result = lhs * rhs;
  return result;
}

inline InitializationResult InitializePixel(
    const std::uint32_t x,
    const std::uint32_t y,
    const float depth_min,
    const float depth_max,
    const float ref_inv_fx,
    const float ref_inv_neg_cx_fx,
    const float ref_inv_fy,
    const float ref_inv_neg_cy_fy) noexcept {
  InitializationResult result{};
  result.state = SeedForPixel(x, y);

  const float depth_uniform = NextUniform(&result.state);
  ++result.draw_count;
  result.depth = F32Add(
      F32Mul(depth_uniform, F32Sub(depth_max, depth_min)), depth_min);

  float v1 = 0.0f;
  float v2 = 0.0f;
  float s = 2.0f;
  while (s >= 1.0f) {
    v1 = F32Sub(F32Mul(2.0f, NextUniform(&result.state)), 1.0f);
    v2 = F32Sub(F32Mul(2.0f, NextUniform(&result.state)), 1.0f);
    result.draw_count += 2u;
    s = F32Add(F32Mul(v1, v1), F32Mul(v2, v2));
    if (s >= 1.0f) {
      ++result.rejected_pairs;
    }
  }

  const float s_norm = std::sqrt(F32Sub(1.0f, s));
  result.normal[0] = F32Mul(F32Mul(2.0f, v1), s_norm);
  result.normal[1] = F32Mul(F32Mul(2.0f, v2), s_norm);
  result.normal[2] = F32Sub(1.0f, F32Mul(2.0f, s));

  const float view_ray[3] = {
      F32Add(F32Mul(ref_inv_fx, static_cast<float>(x)),
             ref_inv_neg_cx_fx),
      F32Add(F32Mul(ref_inv_fy, static_cast<float>(y)),
             ref_inv_neg_cy_fy),
      1.0f,
  };
  const float dot = F32Add(
      F32Add(F32Mul(result.normal[0], view_ray[0]),
             F32Mul(result.normal[1], view_ray[1])),
      F32Mul(result.normal[2], view_ray[2]));
  if (dot > 0.0f) {
    result.normal[0] = -result.normal[0];
    result.normal[1] = -result.normal[1];
    result.normal[2] = -result.normal[2];
  }
  return result;
}

}  // namespace pocketworld::official_dense::vulkan::rng::openmvs_pcg

#endif
