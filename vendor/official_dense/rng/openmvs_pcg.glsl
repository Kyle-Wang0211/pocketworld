/*
 * Copyright (c) 2014-2026 SEACAVE
 * Copyright (c) 2026, PocketWorld contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * GLSL translation of the uint32 seed and RNG expressions pinned in
 * third_party/openmvs_pcg/provenance.json. Integer overflow is deliberately
 * uint32 modulo arithmetic on every supported Vulkan target.
 */

#ifndef POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_GLSL_
#define POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_GLSL_

uint openmvs_pcg_seed(uvec2 pixel) {
  return pixel.x * 1973u + pixel.y * 9277u + 1234u;
}

uint openmvs_pcg_next_state(uint state) {
  return state * 747796405u + 2891336453u;
}

uint openmvs_pcg_output(uint state) {
  uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
  return (word >> 22u) ^ word;
}

uint openmvs_pcg_uniform_bits(uint output_value) {
  return output_value & 0x00ffffffu;
}

float openmvs_pcg_uniform(uint output_value) {
  return float(openmvs_pcg_uniform_bits(output_value)) /
         float(0x01000000u);
}

uint openmvs_pcg_next(inout uint state) {
  state = openmvs_pcg_next_state(state);
  return openmvs_pcg_output(state);
}

float openmvs_pcg_next_uniform(inout uint state) {
  return openmvs_pcg_uniform(openmvs_pcg_next(state));
}

#endif  // POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_GLSL_
