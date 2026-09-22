// Copyright (c) 2026, PocketWorld contributors.
// SPDX-License-Identifier: BSD-3-Clause

#include "diagnostic_map_export.h"

#include <cstddef>
#include <limits>
#include <string>
#include <vector>

#include "../workspace_io/workspace_io.h"

namespace pocketworld::official_dense::vulkan {
namespace {

bool SetDetail(std::string* detail, const std::string& message) noexcept {
  if (detail != nullptr) *detail = message;
  return false;
}

bool IsSafeImageName(const std::string& value) noexcept {
  if (value.empty() || value.find('\0') != std::string::npos ||
      value.find('/') != std::string::npos || value.find('\\') != std::string::npos) {
    return false;
  }
  return std::filesystem::path(value).filename() ==
         std::filesystem::path(value);
}

bool WriteFloatMap(const std::filesystem::path& path,
                   const std::uint32_t width,
                   const std::uint32_t height,
                   const std::size_t depth,
                   const float* values,
                   std::string* detail) noexcept {
  if (values == nullptr || width == 0U || height == 0U || depth == 0U ||
      static_cast<std::size_t>(width) >
          std::numeric_limits<std::size_t>::max() /
              static_cast<std::size_t>(height) ||
      static_cast<std::size_t>(width) * static_cast<std::size_t>(height) >
          std::numeric_limits<std::size_t>::max() / depth) {
    return SetDetail(detail, "invalid diagnostic float map");
  }
  const std::size_t count = static_cast<std::size_t>(width) * height * depth;
  FloatMatrix matrix;
  matrix.width = width;
  matrix.height = height;
  matrix.depth = depth;
  matrix.values.assign(values, values + count);
  const Status status = WriteFloatMatrix(path, matrix);
  if (!status.ok()) return SetDetail(detail, status.message);
  return true;
}

}  // namespace

bool WriteDiagnosticPhotometricMaps(
    const std::filesystem::path& workspace_root,
    const std::string& image_name,
    const resource_arena::DiagnosticImageReadback& readback,
    std::string* const detail) noexcept {
  if (!IsSafeImageName(image_name)) {
    return SetDetail(detail, "unsafe diagnostic image name");
  }
  if (readback.width == 0U || readback.height == 0U ||
      readback.photometric_depth == nullptr ||
      readback.photometric_normal == nullptr) {
    return SetDetail(detail, "incomplete photometric diagnostic readback");
  }
  const Status prepared = CreateStandardWorkspace(workspace_root);
  if (!prepared.ok()) return SetDetail(detail, prepared.message);
  const std::filesystem::path stereo = workspace_root / "stereo";
  const std::string photometric_name = image_name + ".photometric.bin";
  if (!WriteFloatMap(stereo / "depth_maps" / photometric_name,
                     readback.width, readback.height, 1U,
                     readback.photometric_depth, detail) ||
      !WriteFloatMap(stereo / "normal_maps" / photometric_name,
                     readback.width, readback.height, 3U,
                     readback.photometric_normal, detail)) {
    return false;
  }
  if (detail != nullptr) detail->clear();
  return true;
}

bool WriteDiagnosticColmapMaps(
    const std::filesystem::path& workspace_root,
    const std::string& image_name,
    const resource_arena::DiagnosticImageReadback& readback,
    std::string* const detail) noexcept {
  if (!IsSafeImageName(image_name)) {
    return SetDetail(detail, "unsafe diagnostic image name");
  }
  if (readback.width == 0U || readback.height == 0U ||
      readback.photometric_depth == nullptr ||
      readback.photometric_normal == nullptr ||
      readback.geometric_depth == nullptr || readback.geometric_normal == nullptr ||
      readback.consistency_graph_values == nullptr) {
    return SetDetail(detail, "incomplete diagnostic readback");
  }
  const Status prepared = CreateStandardWorkspace(workspace_root);
  if (!prepared.ok()) return SetDetail(detail, prepared.message);
  const std::filesystem::path stereo = workspace_root / "stereo";
  const std::string photometric_name = image_name + ".photometric.bin";
  const std::string geometric_name = image_name + ".geometric.bin";
  if (!WriteFloatMap(stereo / "depth_maps" / photometric_name,
                     readback.width, readback.height, 1U,
                     readback.photometric_depth, detail) ||
      !WriteFloatMap(stereo / "normal_maps" / photometric_name,
                     readback.width, readback.height, 3U,
                     readback.photometric_normal, detail) ||
      !WriteFloatMap(stereo / "depth_maps" / geometric_name,
                     readback.width, readback.height, 1U,
                     readback.geometric_depth, detail) ||
      !WriteFloatMap(stereo / "normal_maps" / geometric_name,
                     readback.width, readback.height, 3U,
                     readback.geometric_normal, detail)) {
    return false;
  }
  ConsistencyGraph graph;
  graph.width = readback.width;
  graph.height = readback.height;
  graph.values.assign(readback.consistency_graph_values,
                      readback.consistency_graph_values +
                          readback.consistency_graph_value_count);
  const Status graph_status = WriteConsistencyGraph(
      stereo / "consistency_graphs" / geometric_name, graph);
  if (!graph_status.ok()) return SetDetail(detail, graph_status.message);
  if (detail != nullptr) detail->clear();
  return true;
}

}  // namespace pocketworld::official_dense::vulkan
