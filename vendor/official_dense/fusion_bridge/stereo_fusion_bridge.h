// Copyright (c), ETH Zurich and UNC Chapel Hill.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
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
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#pragma once

#include <array>
#include <cfloat>
#include <filesystem>
#include <string>
#include <utility>

namespace pocketworld::official_dense::fusion {

enum class StatusCode {
  kOk,
  kUnavailable,
  kInvalidArgument,
  kIoError,
  kFusionError,
};

struct Status {
  StatusCode code = StatusCode::kOk;
  std::string message;

  bool ok() const { return code == StatusCode::kOk; }
  static Status Ok() { return {}; }
  static Status Unavailable(std::string message) {
    return {StatusCode::kUnavailable, std::move(message)};
  }
  static Status Invalid(std::string message) {
    return {StatusCode::kInvalidArgument, std::move(message)};
  }
  static Status Io(std::string message) {
    return {StatusCode::kIoError, std::move(message)};
  }
  static Status FusionError(std::string message) {
    return {StatusCode::kFusionError, std::move(message)};
  }
};

// Field-for-field transport of COLMAP 4.1.1 mvs::StereoFusionOptions. The
// defaults below are frozen to that upstream revision; no product tuning is
// applied here.
struct FusionOptions {
  std::filesystem::path mask_path = "";
  int num_threads = -1;
  int max_image_size = -1;
  int min_num_pixels = 5;
  int max_num_pixels = 10000;
  int max_traversal_depth = 100;
  double max_reproj_error = 2.0;
  double max_depth_error = 0.01;
  double max_normal_error = 10.0;
  int check_num_images = 50;
  bool use_cache = false;
  double cache_size = 32.0;
  std::array<float, 3> bounding_box_min = {-FLT_MAX, -FLT_MAX, -FLT_MAX};
  std::array<float, 3> bounding_box_max = {FLT_MAX, FLT_MAX, FLT_MAX};
};

// Runs the official COLMAP workspace-format StereoFusion. The only supported
// input type is "geometric". On success the workspace contains fused.ply and
// fused.ply.vis. No output is published on failure.
Status RunStereoFusion(const std::filesystem::path& workspace_path,
                       const std::string& input_type,
                       const FusionOptions& options = FusionOptions());

}  // namespace pocketworld::official_dense::fusion
