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

#include "patch_match_controller.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <limits>
#include <set>
#include <sstream>

namespace pocketworld::official_dense::patch_match {
namespace {

constexpr double kPi = 3.141592653589793238462643383279502884;

void Trim(std::string* value) {
  const auto first = std::find_if_not(value->begin(), value->end(), [](char c) {
    return std::isspace(static_cast<unsigned char>(c)) != 0;
  });
  const auto last = std::find_if_not(value->rbegin(), value->rend(), [](char c) {
                      return std::isspace(static_cast<unsigned char>(c)) != 0;
                    }).base();
  if (first >= last) {
    value->clear();
  } else {
    *value = std::string(first, last);
  }
}

std::vector<std::string> CsvToStrings(const std::string& input) {
  std::vector<std::string> values;
  std::istringstream stream(input);
  std::string value;
  while (std::getline(stream, value, ',')) {
    Trim(&value);
    values.push_back(value);
  }
  return values;
}

Status CsvToIntegers(const std::string& input, std::vector<int>* values) {
  values->clear();
  for (const std::string& value : CsvToStrings(input)) {
    if (value.empty()) return Status::Invalid("empty device index");
    std::size_t parsed = 0;
    try {
      const int result = std::stoi(value, &parsed);
      if (parsed != value.size() || result < -1) {
        return Status::Invalid("invalid device index: " + value);
      }
      values->push_back(result);
    } catch (const std::exception&) {
      return Status::Invalid("invalid device index: " + value);
    }
  }
  if (values->empty()) return Status::Invalid("device list is empty");
  return Status::Ok();
}

const ImageRecord* FindImageByIndex(const WorkspaceSnapshot& workspace,
                                    const int image_idx) {
  for (const auto& image : workspace.images) {
    if (image.image_idx == image_idx) return &image;
  }
  return nullptr;
}

const ImageRecord* FindImageByName(const WorkspaceSnapshot& workspace,
                                   const std::string& image_name) {
  for (const auto& image : workspace.images) {
    if (image.image_name == image_name) return &image;
  }
  return nullptr;
}

bool ExistsRegularFile(const std::filesystem::path& path) {
  std::error_code error;
  return std::filesystem::is_regular_file(path, error) && !error;
}

}  // namespace

bool PatchMatchOptions::Check() const noexcept {
  // Mechanical equivalent of COLMAP 4.1.1 PatchMatchOptions::Check(). Keep
  // its public validation limit of 32 unchanged; the CUDA dispatcher's
  // separate 1..20 template limit belongs to the execution stage.
  if (depth_min != -1.0 || depth_max != -1.0) {
    if (!(depth_min <= depth_max) || !(depth_min >= 0.0)) return false;
  }
  return window_radius > 0 && window_radius <= 32 && sigma_color > 0.0 &&
         window_step > 0 && window_step <= 2 && num_samples > 0 &&
         ncc_sigma > 0.0 && min_triangulation_angle >= 0.0 &&
         min_triangulation_angle < 180.0 && incident_angle_sigma > 0.0 &&
         num_iterations > 0 && geom_consistency_regularizer >= 0.0 &&
         geom_consistency_max_cost >= 0.0 && filter_min_ncc >= -1.0 &&
         filter_min_ncc <= 1.0 && filter_min_triangulation_angle >= 0.0 &&
         filter_min_triangulation_angle <= 180.0 &&
         filter_min_num_consistent >= 0 &&
         filter_geom_consistency_max_cost >= 0.0 && cache_size > 0.0 &&
         num_threads >= -1;
}

std::vector<int> UnavailableVulkanBackendFactory::EnumerateDevices() const {
  return {};
}

std::unique_ptr<VulkanPatchMatchBackend>
UnavailableVulkanBackendFactory::Create(const int /*device_index*/) const {
  return nullptr;
}

PatchMatchController::PatchMatchController(
    PatchMatchOptions options,
    std::filesystem::path workspace_path,
    std::string workspace_format,
    std::string pmvs_option_name,
    std::filesystem::path config_path,
    std::shared_ptr<WorkspaceReader> workspace_reader,
    std::shared_ptr<VulkanBackendFactory> backend_factory)
    : options_(std::move(options)),
      workspace_path_(std::move(workspace_path)),
      workspace_format_(std::move(workspace_format)),
      pmvs_option_name_(std::move(pmvs_option_name)),
      config_path_(std::move(config_path)),
      workspace_reader_(std::move(workspace_reader)),
      backend_factory_(std::move(backend_factory)) {}

Status PatchMatchController::Run() {
  if (!options_.Check()) {
    return Status::Invalid("PatchMatchOptions failed COLMAP 4.1.1 validation");
  }
  Status status = ReadWorkspace();
  if (!status.ok()) return status;
  status = ReadProblems();
  if (!status.ok()) return status;
  status = ReadDeviceIndices();
  if (!status.ok()) return status;

  backends_.clear();
  backends_.reserve(device_indices_.size());
  for (const int device_index : device_indices_) {
    auto backend = backend_factory_->Create(device_index);
    if (!backend) {
      backends_.clear();
      return Status::Unavailable(
          "COLMAP 4.1.1 Vulkan PatchMatch backend is unavailable");
    }
    backends_.push_back(std::move(backend));
  }

  // Upstream rule: when geometric consistency is requested, finish the
  // unfiltered photometric pass for every problem before starting any
  // geometric problem.
  if (options_.geom_consistency) {
    PatchMatchOptions photometric_options = options_;
    photometric_options.geom_consistency = false;
    photometric_options.filter = false;
    status = SubmitStage(photometric_options);
    if (!status.ok()) return status;
  }
  return SubmitStage(options_);
}

Status PatchMatchController::ReadWorkspace() {
  if (!workspace_reader_) return Status::Invalid("workspace reader is null");
  if (!backend_factory_) return Status::Invalid("backend factory is null");
  WorkspaceReadRequest request;
  request.workspace_path = workspace_path_;
  request.workspace_format = workspace_format_;
  request.pmvs_option_name = pmvs_option_name_;
  request.max_image_size = options_.max_image_size;
  request.image_as_rgb = false;
  request.cache_size = options_.cache_size;
  request.input_type = options_.geom_consistency ? "photometric" : "";
  Status status = workspace_reader_->Read(request, &workspace_);
  if (!status.ok()) return status;
  if (workspace_.images.empty()) return Status::Invalid("workspace has no images");

  std::set<int> indices;
  std::set<std::string> names;
  for (const auto& image : workspace_.images) {
    if (image.image_idx < 0 || image.image_name.empty() ||
        !indices.insert(image.image_idx).second ||
        !names.insert(image.image_name).second) {
      return Status::Invalid("workspace image identity is invalid");
    }
  }
  return Status::Ok();
}

Status PatchMatchController::ReadProblems() {
  problems_.clear();
  const std::filesystem::path config_path =
      config_path_.empty()
          ? workspace_path_ / workspace_.stereo_folder / "patch-match.cfg"
          : config_path_;
  std::ifstream config_stream(config_path);
  if (!config_stream) return Status::Io("cannot read: " + config_path.string());

  struct ProblemConfig {
    std::string ref_image_name;
    std::vector<std::string> src_image_names;
  };
  std::vector<ProblemConfig> configurations;
  std::string ref_image_name;
  std::string line;
  while (std::getline(config_stream, line)) {
    Trim(&line);
    if (line.empty() || line[0] == '#') continue;
    if (ref_image_name.empty()) {
      ref_image_name = line;
    } else {
      configurations.push_back({ref_image_name, CsvToStrings(line)});
      ref_image_name.clear();
    }
  }
  if (!config_stream.eof()) {
    return Status::Io("cannot read: " + config_path.string());
  }

  const double min_angle_rad =
      options_.min_triangulation_angle * kPi / 180.0;
  for (const auto& configuration : configurations) {
    const ImageRecord* reference =
        FindImageByName(workspace_, configuration.ref_image_name);
    if (!reference) {
      return Status::Invalid("unknown reference image: " +
                             configuration.ref_image_name);
    }
    Problem problem;
    problem.ref_image_idx = reference->image_idx;
    if (configuration.src_image_names.size() == 1 &&
        configuration.src_image_names[0] == "__all__") {
      problem.src_image_idxs.reserve(workspace_.images.size() - 1);
      for (const auto& image : workspace_.images) {
        if (image.image_idx != problem.ref_image_idx) {
          problem.src_image_idxs.push_back(image.image_idx);
        }
      }
    } else if (configuration.src_image_names.size() == 2 &&
               configuration.src_image_names[0] == "__auto__") {
      std::size_t parsed = 0;
      long long maximum = 0;
      try {
        maximum = std::stoll(configuration.src_image_names[1], &parsed);
      } catch (const std::exception&) {
        return Status::Invalid("invalid __auto__ source count");
      }
      if (parsed != configuration.src_image_names[1].size() || maximum < 0) {
        return Status::Invalid("invalid __auto__ source count");
      }

      std::vector<std::pair<int, int>> sources;
      sources.reserve(reference->shared_num_points.size());
      for (const auto& shared : reference->shared_num_points) {
        const auto angle = reference->triangulation_angles_rad.find(shared.first);
        if (angle == reference->triangulation_angles_rad.end()) {
          return Status::Invalid("missing triangulation angle");
        }
        if (angle->second >= min_angle_rad) sources.push_back(shared);
      }
      const std::size_t count = std::min(
          sources.size(), static_cast<std::size_t>(maximum));
      std::partial_sort(sources.begin(),
                        sources.begin() + count,
                        sources.end(),
                        [](const auto& lhs, const auto& rhs) {
                          return lhs.second > rhs.second;
                        });
      problem.src_image_idxs.reserve(count);
      for (std::size_t index = 0; index < count; ++index) {
        problem.src_image_idxs.push_back(sources[index].first);
      }
    } else {
      problem.src_image_idxs.reserve(configuration.src_image_names.size());
      for (const auto& source_name : configuration.src_image_names) {
        const ImageRecord* source = FindImageByName(workspace_, source_name);
        if (!source) return Status::Invalid("unknown source image: " + source_name);
        problem.src_image_idxs.push_back(source->image_idx);
      }
    }

    // COLMAP ignores reference images for which source selection is empty.
    if (!problem.src_image_idxs.empty()) problems_.push_back(std::move(problem));
  }
  return Status::Ok();
}

Status PatchMatchController::ReadDeviceIndices() {
  Status status = CsvToIntegers(options_.gpu_index, &device_indices_);
  if (!status.ok()) return status;
  if (device_indices_.size() == 1 && device_indices_[0] == -1) {
    device_indices_ = backend_factory_->EnumerateDevices();
  }
  if (device_indices_.empty()) {
    return Status::Unavailable(
        "COLMAP 4.1.1 Vulkan PatchMatch backend has no available device");
  }
  for (const int index : device_indices_) {
    if (index < 0) return Status::Invalid("invalid Vulkan device index");
  }
  return Status::Ok();
}

Status PatchMatchController::SubmitStage(const PatchMatchOptions& options) {
  for (std::size_t problem_idx = 0; problem_idx < problems_.size();
       ++problem_idx) {
    const std::size_t backend_idx = problem_idx % backends_.size();
    PatchMatchRequest request;
    bool already_complete = false;
    Status status = BuildRequest(options,
                                 problem_idx,
                                 device_indices_[backend_idx],
                                 &request,
                                 &already_complete);
    if (!status.ok()) return status;
    if (already_complete) continue;
    status = backends_[backend_idx]->Submit(request);
    if (!status.ok()) return status;
  }
  for (auto& backend : backends_) {
    Status status = backend->WaitAll();
    if (!status.ok()) return status;
  }
  return Status::Ok();
}

Status PatchMatchController::BuildRequest(const PatchMatchOptions& options,
                                          const std::size_t problem_idx,
                                          const int device_index,
                                          PatchMatchRequest* request,
                                          bool* already_complete) const {
  if (!request || !already_complete) return Status::Invalid("null output");
  if (problem_idx >= problems_.size()) return Status::Invalid("invalid problem");
  const Problem& problem = problems_[problem_idx];
  const ImageRecord* reference =
      FindImageByIndex(workspace_, problem.ref_image_idx);
  if (!reference) return Status::Invalid("unknown reference image index");

  request->options = options;
  request->problem = problem;
  if (request->options.depth_min < 0 || request->options.depth_max < 0) {
    request->options.depth_min = reference->depth_min;
    request->options.depth_max = reference->depth_max;
    if (!(request->options.depth_min > 0 && request->options.depth_max > 0)) {
      return Status::Invalid(
          "minimum and maximum depth must be set when sparse ranges are absent");
    }
  }
  request->options.gpu_index = std::to_string(device_index);
  if (request->options.sigma_spatial <= 0.0) {
    request->options.sigma_spatial = request->options.window_radius;
  }
  request->options.filter_min_num_consistent =
      std::min(static_cast<int>(problem.src_image_idxs.size()),
               request->options.filter_min_num_consistent);

  std::set<int> unique_sources(problem.src_image_idxs.begin(),
                               problem.src_image_idxs.end());
  if (unique_sources.size() != problem.src_image_idxs.size() ||
      unique_sources.count(problem.ref_image_idx) != 0) {
    return Status::Invalid("reference/source image set is not unique");
  }
  for (const int image_idx : problem.src_image_idxs) {
    if (!FindImageByIndex(workspace_, image_idx)) {
      return Status::Invalid("unknown source image index");
    }
  }

  const std::string output_type =
      options.geom_consistency ? "geometric" : "photometric";
  const std::string file_name =
      reference->image_name + "." + output_type + ".bin";
  request->output.depth_map = workspace_path_ / workspace_.stereo_folder /
                              "depth_maps" / file_name;
  request->output.normal_map = workspace_path_ / workspace_.stereo_folder /
                               "normal_maps" / file_name;
  request->output.consistency_graph =
      workspace_path_ / workspace_.stereo_folder / "consistency_graphs" /
      file_name;
  *already_complete =
      ExistsRegularFile(request->output.depth_map) &&
      ExistsRegularFile(request->output.normal_map) &&
      (!options.write_consistency_graph ||
       ExistsRegularFile(request->output.consistency_graph));
  return Status::Ok();
}

}  // namespace pocketworld::official_dense::patch_match
