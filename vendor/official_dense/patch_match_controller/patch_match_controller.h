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

// Cross-platform controller seam for COLMAP 4.1.1 PatchMatch. Selection,
// option defaults, stage ordering, and output naming follow the upstream
// controller. Only device discovery and execution are injected for Vulkan.
#pragma once

#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace pocketworld::official_dense::patch_match {

enum class StatusCode {
  kOk,
  kUnavailable,
  kInvalidArgument,
  kIoError,
  kBackendError,
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
  static Status Backend(std::string message) {
    return {StatusCode::kBackendError, std::move(message)};
  }
};

// Defaults are copied from COLMAP 4.1.1 mvs/patch_match_options.h.
struct PatchMatchOptions {
  double depth_min = -1.0;
  double depth_max = -1.0;
  double sigma_spatial = -1.0;
  double sigma_color = 0.2;
  double ncc_sigma = 0.6;
  double min_triangulation_angle = 1.0;
  double incident_angle_sigma = 0.9;
  double geom_consistency_regularizer = 0.3;
  double geom_consistency_max_cost = 3.0;
  double filter_min_ncc = 0.1;
  double filter_min_triangulation_angle = 3.0;
  double filter_geom_consistency_max_cost = 1.0;
  double cache_size = 32.0;
  std::string gpu_index = "-1";
  int max_image_size = -1;
  int window_radius = 5;
  int window_step = 1;
  int num_samples = 15;
  int num_iterations = 5;
  int filter_min_num_consistent = 2;
  int num_threads = -1;
  bool geom_consistency = true;
  bool filter = true;
  bool allow_missing_files = false;
  bool write_consistency_graph = false;

  // Equivalent to COLMAP 4.1.1 PatchMatchOptions::Check, narrowed to the
  // window radii actually instantiated by the frozen upstream GPU dispatcher.
  [[nodiscard]] bool Check() const noexcept;
};

struct Problem {
  int ref_image_idx = -1;
  std::vector<int> src_image_idxs;
};

struct ImageRecord {
  int image_idx = -1;
  std::string image_name;
  double depth_min = -1.0;
  double depth_max = -1.0;
  std::map<int, int> shared_num_points;
  std::map<int, double> triangulation_angles_rad;
};

struct WorkspaceSnapshot {
  std::string stereo_folder = "stereo";
  std::vector<ImageRecord> images;
};

struct WorkspaceReadRequest {
  std::filesystem::path workspace_path;
  std::string workspace_format;
  std::string pmvs_option_name;
  int max_image_size = -1;
  bool image_as_rgb = false;
  double cache_size = 32.0;
  std::string input_type;
};

class WorkspaceReader {
 public:
  virtual ~WorkspaceReader() = default;
  virtual Status Read(const WorkspaceReadRequest& request,
                      WorkspaceSnapshot* snapshot) = 0;
};

struct OutputPaths {
  std::filesystem::path depth_map;
  std::filesystem::path normal_map;
  std::filesystem::path consistency_graph;
};

struct PatchMatchRequest {
  PatchMatchOptions options;
  Problem problem;
  OutputPaths output;
};

class VulkanPatchMatchBackend {
 public:
  virtual ~VulkanPatchMatchBackend() = default;
  virtual Status Submit(const PatchMatchRequest& request) = 0;
  virtual Status WaitAll() = 0;
};

class VulkanBackendFactory {
 public:
  virtual ~VulkanBackendFactory() = default;
  virtual std::vector<int> EnumerateDevices() const = 0;
  virtual std::unique_ptr<VulkanPatchMatchBackend> Create(
      int device_index) const = 0;
};

// Fail-closed production default until the backend passes CUDA parity.
class UnavailableVulkanBackendFactory final : public VulkanBackendFactory {
 public:
  std::vector<int> EnumerateDevices() const override;
  std::unique_ptr<VulkanPatchMatchBackend> Create(
      int device_index) const override;
};

class PatchMatchController final {
 public:
  PatchMatchController(
      PatchMatchOptions options,
      std::filesystem::path workspace_path,
      std::string workspace_format,
      std::string pmvs_option_name,
      std::filesystem::path config_path,
      std::shared_ptr<WorkspaceReader> workspace_reader,
      std::shared_ptr<VulkanBackendFactory> backend_factory);

  Status Run();
  const std::vector<Problem>& problems() const { return problems_; }

 private:
  Status ReadWorkspace();
  Status ReadProblems();
  Status ReadDeviceIndices();
  Status SubmitStage(const PatchMatchOptions& options);
  Status BuildRequest(const PatchMatchOptions& options,
                      std::size_t problem_idx,
                      int device_index,
                      PatchMatchRequest* request,
                      bool* already_complete) const;

  PatchMatchOptions options_;
  std::filesystem::path workspace_path_;
  std::string workspace_format_;
  std::string pmvs_option_name_;
  std::filesystem::path config_path_;
  std::shared_ptr<WorkspaceReader> workspace_reader_;
  std::shared_ptr<VulkanBackendFactory> backend_factory_;
  WorkspaceSnapshot workspace_;
  std::vector<Problem> problems_;
  std::vector<int> device_indices_;
  std::vector<std::unique_ptr<VulkanPatchMatchBackend>> backends_;
};

}  // namespace pocketworld::official_dense::patch_match
