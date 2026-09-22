/*
 * Copyright (c) 2014-2026 SEACAVE
 * Copyright (c) 2026, PocketWorld contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Test-only compute entry point. It includes the production-reference GLSL and
 * exposes deterministic values for execution by the focused SPIR-V verifier.
 */

#version 450
#extension GL_GOOGLE_include_directive : require

#include "openmvs_pcg.glsl"

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) writeonly buffer VectorResults {
  uint values[];
} results;

void main() {
  uint state = openmvs_pcg_seed(uvec2(0u, 0u));
  results.values[0] = state;
  uint output_value = openmvs_pcg_next(state);
  results.values[1] = state;
  results.values[2] = output_value;
  results.values[3] = openmvs_pcg_uniform_bits(output_value);
  results.values[4] = floatBitsToUint(openmvs_pcg_uniform(output_value));

  results.values[5] = openmvs_pcg_seed(uvec2(0xffffffffu, 0xffffffffu));

  state = openmvs_pcg_seed(uvec2(1u, 0u));
  output_value = openmvs_pcg_next(state);
  results.values[6] = state;
  results.values[7] = output_value;
  output_value = openmvs_pcg_next(state);
  results.values[8] = state;
  results.values[9] = output_value;
  results.values[10] = openmvs_pcg_uniform_bits(output_value);
  results.values[11] = floatBitsToUint(
      openmvs_pcg_uniform(output_value));

  state = openmvs_pcg_seed(uvec2(37u, 19u));
  results.values[12] = state;
  output_value = openmvs_pcg_next(state);
  results.values[13] = state;
  results.values[14] = output_value;
  results.values[15] = floatBitsToUint(
      openmvs_pcg_uniform(output_value));
}
