/*
 * Copyright (c) 2014-2026 SEACAVE
 * Copyright (c), ETH Zurich and UNC Chapel Hill.
 * Copyright (c) 2026, PocketWorld contributors
 * SPDX-License-Identifier: AGPL-3.0-or-later
 *
 * Shared reference-only state and parameter ABI for the three-stage
 * COLMAP initialization control flow + OpenMVS-PCG adaptation.
 */

#ifndef POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_INITIALIZATION_LAYOUT_GLSL_
#define POCKETWORLD_OFFICIAL_DENSE_OPENMVS_PCG_INITIALIZATION_LAYOUT_GLSL_

layout(set = 0, binding = 6, std430) buffer XorwowStateWords {
  uint values[];
} xorwow_state_words;

#include "colmap_xorwow.glsl"

// This deliberately retains the existing cross-stage PatchPC ABI. Fields not
// used during initialization remain present so all three mobile targets consume
// one parameter layout rather than platform-specific adapters.
layout(push_constant) uniform PatchPC {
  uint width;
  uint height;
  uint num_sources;
  uint workspace_max_dim;
  uint source_width;
  uint source_height;
  uint rotation_0_to_3;
  uint reserved;

  float ref_K_fx;
  float ref_K_cx;
  float ref_K_fy;
  float ref_K_cy;
  float ref_inv_fx;
  float ref_inv_neg_cx_fx;
  float ref_inv_fy;
  float ref_inv_neg_cy_fy;

  float perturbation;
  float depth_min;
  float depth_max;
  int num_samples;
  float sigma_spatial;
  float sigma_color;
  float ncc_sigma;
  float min_triangulation_angle_rad;
  float incident_angle_sigma;
  float prev_sel_prob_weight;
  float geom_consistency_regularizer;
  float geom_consistency_max_cost;
  float filter_min_ncc;
  float filter_min_triangulation_angle_rad;
  int filter_min_num_consistent;
  float filter_geom_consistency_max_cost;
} pc;

uint colmap_xorwow_pixel_index(uvec2 pixel) {
  return pixel.y * pc.width + pixel.x;
}

#endif
