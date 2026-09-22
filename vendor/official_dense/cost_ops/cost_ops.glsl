// Copyright (c), ETH Zurich and UNC Chapel Hill.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//
//     * Neither the name of ETH Zurich and UNC Chapel Hill nor the names of
//       its contributors may be used to endorse or promote products derived
//       from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#ifndef POCKETWORLD_COLMAP411_COST_OPS_GLSL
#define POCKETWORLD_COLMAP411_COST_OPS_GLSL

// Mechanical Vulkan translation of COLMAP 4.1.1 a0d785f.
// patch_match_cuda.cu sha256 1aebd4482de0ea6f1f3aad45150c09e0479119c607a843959c8aaa381c0d4448
// gpu_mat_ref_image.h sha256 4e869dd8f099ed7765de2a37eb4312072e04ecace7aa2313fea3c71272803f48
// LocalRefImage layout is the literal COLMAP 4.1.1 shift-rows-up form
// (patch_match_cuda.cu struct LocalRefImage::Read). The circular-buffer
// variant from the maintainer's WIP PR #4124 (commit 112da5e) was benchmarked
// on 2026-08-29 and was SLOWER on MoltenVK/M3 Pro (57.590s -> 61.943s), so it
// is reverted here. PR #4124 is closed and unmerged; official 4.1.1 is the
// only authority for this file.

layout(constant_id = 0) const int kWindowRadius = 5;
layout(constant_id = 1) const int kWindowStep = 1;

const int kThreadsPerBlock = 32;
const int kThreadBlockRadius = 1;
const int kThreadBlockSize = 2 * kThreadBlockRadius + 1;
const int kWindowSize = 2 * kWindowRadius + 1;
const int kLocalRefNumRows = kWindowSize;
const int kLocalRefNumColumns = kThreadBlockSize * kThreadsPerBlock;
shared float local_ref_image[kLocalRefNumRows * kLocalRefNumColumns];

// Official 4.1.1 shifts rows up, so the logical row IS the physical row.
float LocalRefImageGet(int logical_row, int col_idx) {
  return local_ref_image[logical_row * kLocalRefNumColumns + col_idx];
}

// Implemented by the embedding shader. The Vulkan host-side requirements for
// these callbacks are frozen by sampler_contract.h. Vulkan permits
// implementation-specific filtering precision, so CUDA parity remains disabled
// until the RTX 5090 texture fixture has been captured and matched.
float SampleReferenceImage(int row, int col);
float SampleSourceImage(float col_plus_half, float row_plus_half, int layer);
float SampleSourceDepth(float col_plus_half, float row_plus_half, int layer);

float BilateralWeight(float row_diff,
                      float col_diff,
                      float color1,
                      float color2,
                      float spatial_normalization,
                      float color_normalization) {
  float spatial_dist_squared =
      row_diff * row_diff + col_diff * col_diff;
  float color_dist = color1 - color2;
  return exp(-spatial_dist_squared * spatial_normalization -
             color_dist * color_dist * color_normalization);
}

// Literal LocalRefImage::Read layout. All 32 invocations in the workgroup must
// call this function for consecutive rows and execute a workgroup barrier after
// every call, matching PhotoConsistencyCostComputer::Read.
void LocalRefImageRead(int row) {
  int thread_id = int(gl_LocalInvocationID.x);
  int thread_block_first_id =
      int(gl_WorkGroupSize.x * gl_WorkGroupID.x);

  int local_col_start = thread_id;
  int global_col_start = thread_block_first_id -
                         kThreadBlockRadius * kThreadsPerBlock + thread_id;

  if (row == 0) {
    int global_row = row - kWindowRadius;
    for (int local_row = 0;
         local_row < kLocalRefNumRows;
         ++local_row, ++global_row) {
      int local_col = local_col_start;
      int global_col = global_col_start;
      for (int block = 0; block < kThreadBlockSize; ++block) {
        local_ref_image[local_row * kLocalRefNumColumns + local_col] =
            SampleReferenceImage(global_row, global_col);
        local_col += kThreadsPerBlock;
        global_col += kThreadsPerBlock;
      }
    }
  } else {
    // Move rows in shared memory up by one row. Literal COLMAP 4.1.1: each
    // invocation owns a fixed set of columns, so the in-place shift is
    // race-free within the workgroup without an intervening barrier.
    for (int local_row = 1; local_row < kLocalRefNumRows; ++local_row) {
      int local_col = local_col_start;
      for (int block = 0; block < kThreadBlockSize; ++block) {
        local_ref_image[(local_row - 1) * kLocalRefNumColumns + local_col] =
            local_ref_image[local_row * kLocalRefNumColumns + local_col];
        local_col += kThreadsPerBlock;
      }
    }

    // Read next row into the last row of shared memory.
    int local_row = kLocalRefNumRows - 1;
    int global_row = row + kWindowRadius;
    int local_col = local_col_start;
    int global_col = global_col_start;
    for (int block = 0; block < kThreadBlockSize; ++block) {
      local_ref_image[local_row * kLocalRefNumColumns + local_col] =
          SampleReferenceImage(global_row, global_col);
      local_col += kThreadsPerBlock;
      global_col += kThreadsPerBlock;
    }
  }
}

void ComposeHomography(in float K[4],
                       in float R[9],
                       in float T[3],
                       in float ref_inv_K[4],
                       int row,
                       int col,
                       float depth,
                       in float normal[3],
                       out float H[9]) {
  float dist =
      depth * (normal[0] * (ref_inv_K[0] * col + ref_inv_K[1]) +
               normal[1] * (ref_inv_K[2] * row + ref_inv_K[3]) + normal[2]);
  float inv_dist = 1.0 / dist;

  float inv_dist_N0 = inv_dist * normal[0];
  float inv_dist_N1 = inv_dist * normal[1];
  float inv_dist_N2 = inv_dist * normal[2];

  H[0] = ref_inv_K[0] * (K[0] * (R[0] + inv_dist_N0 * T[0]) +
                         K[1] * (R[6] + inv_dist_N0 * T[2]));
  H[1] = ref_inv_K[2] * (K[0] * (R[1] + inv_dist_N1 * T[0]) +
                         K[1] * (R[7] + inv_dist_N1 * T[2]));
  H[2] = K[0] * (R[2] + inv_dist_N2 * T[0]) +
         K[1] * (R[8] + inv_dist_N2 * T[2]) +
         ref_inv_K[1] * (K[0] * (R[0] + inv_dist_N0 * T[0]) +
                         K[1] * (R[6] + inv_dist_N0 * T[2])) +
         ref_inv_K[3] * (K[0] * (R[1] + inv_dist_N1 * T[0]) +
                         K[1] * (R[7] + inv_dist_N1 * T[2]));
  H[3] = ref_inv_K[0] * (K[2] * (R[3] + inv_dist_N0 * T[1]) +
                         K[3] * (R[6] + inv_dist_N0 * T[2]));
  H[4] = ref_inv_K[2] * (K[2] * (R[4] + inv_dist_N1 * T[1]) +
                         K[3] * (R[7] + inv_dist_N1 * T[2]));
  H[5] = K[2] * (R[5] + inv_dist_N2 * T[1]) +
         K[3] * (R[8] + inv_dist_N2 * T[2]) +
         ref_inv_K[1] * (K[2] * (R[3] + inv_dist_N0 * T[1]) +
                         K[3] * (R[6] + inv_dist_N0 * T[2])) +
         ref_inv_K[3] * (K[2] * (R[4] + inv_dist_N1 * T[1]) +
                         K[3] * (R[7] + inv_dist_N1 * T[2]));
  H[6] = ref_inv_K[0] * (R[6] + inv_dist_N0 * T[2]);
  H[7] = ref_inv_K[2] * (R[7] + inv_dist_N1 * T[2]);
  H[8] = R[8] + ref_inv_K[1] * (R[6] + inv_dist_N0 * T[2]) +
         ref_inv_K[3] * (R[7] + inv_dist_N1 * T[2]) +
         inv_dist_N2 * T[2];
}

float PhotoConsistencyCost(in float tform[9],
                           int src_image_idx,
                           int row,
                           int col,
                           float local_ref_sum,
                           float local_ref_squared_sum,
                           float spatial_normalization,
                           float color_normalization) {
  const float kMaxCost = 2.0;

  float tform_step[8];
  for (int i = 0; i < 8; ++i) {
    tform_step[i] = kWindowStep * tform[i];
  }

  int thread_id = int(gl_LocalInvocationID.x);
  int row_start = row - kWindowRadius;
  int col_start = col - kWindowRadius;

  float col_src =
      tform[0] * col_start + tform[1] * row_start + tform[2];
  float row_src =
      tform[3] * col_start + tform[4] * row_start + tform[5];
  float z = tform[6] * col_start + tform[7] * row_start + tform[8];
  float base_col_src = col_src;
  float base_row_src = row_src;
  float base_z = z;

  int col_in_row_start =
      kThreadsPerBlock - kWindowRadius + thread_id;

  float ref_center_color =
      LocalRefImageGet(kWindowRadius,
                       col_in_row_start + kWindowRadius);
  float ref_color_sum = local_ref_sum;
  float ref_color_squared_sum = local_ref_squared_sum;
  float src_color_sum = 0.0;
  float src_color_squared_sum = 0.0;
  float src_ref_color_sum = 0.0;
  float bilateral_weight_sum = 0.0;

  int logical_row = 0;
  for (int window_row = -kWindowRadius;
       window_row <= kWindowRadius;
       window_row += kWindowStep) {
    int col_in_row = col_in_row_start;
    for (int window_col = -kWindowRadius;
         window_col <= kWindowRadius;
         window_col += kWindowStep) {
      float inv_z = 1.0 / z;
      float norm_col_src = inv_z * col_src + 0.5;
      float norm_row_src = inv_z * row_src + 0.5;
      float ref_color = LocalRefImageGet(logical_row, col_in_row);
      float src_color =
          SampleSourceImage(norm_col_src, norm_row_src, src_image_idx);

      float bilateral_weight = BilateralWeight(
          float(window_row),
          float(window_col),
          ref_center_color,
          ref_color,
          spatial_normalization,
          color_normalization);

      float bilateral_weight_src = bilateral_weight * src_color;

      src_color_sum += bilateral_weight_src;
      src_color_squared_sum += bilateral_weight_src * src_color;
      src_ref_color_sum += bilateral_weight_src * ref_color;
      bilateral_weight_sum += bilateral_weight;

      col_in_row += kWindowStep;

      col_src += tform_step[0];
      row_src += tform_step[3];
      z += tform_step[6];
    }

    logical_row += kWindowStep;

    base_col_src += tform_step[1];
    base_row_src += tform_step[4];
    base_z += tform_step[7];

    col_src = base_col_src;
    row_src = base_row_src;
    z = base_z;
  }

  float inv_bilateral_weight_sum = 1.0 / bilateral_weight_sum;
  src_color_sum *= inv_bilateral_weight_sum;
  src_color_squared_sum *= inv_bilateral_weight_sum;
  src_ref_color_sum *= inv_bilateral_weight_sum;

  float ref_color_var =
      ref_color_squared_sum - ref_color_sum * ref_color_sum;
  float src_color_var =
      src_color_squared_sum - src_color_sum * src_color_sum;

  const float kMinVar = 1e-5;
  if (ref_color_var < kMinVar || src_color_var < kMinVar) {
    return kMaxCost;
  } else {
    float src_ref_color_covar =
        src_ref_color_sum - ref_color_sum * src_color_sum;
    float src_ref_color_var = sqrt(ref_color_var * src_color_var);
    return max(0.0, min(kMaxCost, 1.0 - src_ref_color_covar / src_ref_color_var));
  }
}

void ComputePointAtDepth(float row,
                         float col,
                         float depth,
                         in float ref_inv_K[4],
                         out float point[3]) {
  point[0] = depth * (ref_inv_K[0] * col + ref_inv_K[1]);
  point[1] = depth * (ref_inv_K[2] * row + ref_inv_K[3]);
  point[2] = depth;
}

float GeometricConsistencyCost(in float P[12],
                               in float inv_P[12],
                               in float ref_K[4],
                               in float ref_inv_K[4],
                               float row,
                               float col,
                               float depth,
                               int image_idx,
                               float max_cost) {
  float forward_point[3];
  ComputePointAtDepth(row, col, depth, ref_inv_K, forward_point);

  float inv_forward_z =
      1.0 / (P[8] * forward_point[0] + P[9] * forward_point[1] +
             P[10] * forward_point[2] + P[11]);
  float src_col =
      inv_forward_z * (P[0] * forward_point[0] + P[1] * forward_point[1] +
                       P[2] * forward_point[2] + P[3]);
  float src_row =
      inv_forward_z * (P[4] * forward_point[0] + P[5] * forward_point[1] +
                       P[6] * forward_point[2] + P[7]);

  float src_depth =
      SampleSourceDepth(src_col + 0.5, src_row + 0.5, image_idx);
  if (src_depth == 0.0) {
    return max_cost;
  }

  src_col *= src_depth;
  src_row *= src_depth;
  float backward_point_x =
      inv_P[0] * src_col + inv_P[1] * src_row +
      inv_P[2] * src_depth + inv_P[3];
  float backward_point_y =
      inv_P[4] * src_col + inv_P[5] * src_row +
      inv_P[6] * src_depth + inv_P[7];
  float backward_point_z = inv_P[8] * src_col + inv_P[9] * src_row +
                           inv_P[10] * src_depth + inv_P[11];
  float inv_backward_point_z = 1.0 / backward_point_z;

  float backward_col =
      inv_backward_point_z *
      (ref_K[0] * backward_point_x + ref_K[1] * backward_point_z);
  float backward_row =
      inv_backward_point_z *
      (ref_K[2] * backward_point_y + ref_K[3] * backward_point_z);

  float diff_col = col - backward_col;
  float diff_row = row - backward_row;
  return min(max_cost, sqrt(diff_col * diff_col + diff_row * diff_row));
}

#endif
