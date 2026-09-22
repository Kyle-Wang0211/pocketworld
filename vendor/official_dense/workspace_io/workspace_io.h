// Cross-platform disk I/O for the COLMAP 4.1.1 dense workspace contract.
// This layer deliberately contains no PatchMatch or fusion algorithm code.
#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <string>
#include <utility>
#include <vector>

namespace pocketworld::official_dense {

struct Status {
  bool success = false;
  std::string message;

  bool ok() const { return success; }

  static Status Ok() { return {true, {}}; }
  static Status Error(std::string message) {
    return {false, std::move(message)};
  }
};

struct MaterializationEntry {
  std::filesystem::path source_path;
  std::string image_name;
  std::uintmax_t byte_size = 0;
  std::string sha256;
};

// COLMAP Mat<float> storage. Values use the upstream slice-major linear order:
// slice * width * height + row * width + col.
struct FloatMatrix {
  std::size_t width = 0;
  std::size_t height = 0;
  std::size_t depth = 0;
  std::vector<float> values;
};

// Raw COLMAP ConsistencyGraph int32 payload. Each record is
// col, row, num_images, image_idx_0, ... image_idx_N.
struct ConsistencyGraph {
  std::size_t width = 0;
  std::size_t height = 0;
  std::vector<std::int32_t> values;
};

Status CreateStandardWorkspace(const std::filesystem::path& root);

Status MaterializeImage(const std::filesystem::path& images_directory,
                        const MaterializationEntry& entry);

Status WriteFloatMatrix(const std::filesystem::path& path,
                        const FloatMatrix& matrix);
Status ReadFloatMatrix(const std::filesystem::path& path, FloatMatrix* matrix);

Status WriteConsistencyGraph(const std::filesystem::path& path,
                             const ConsistencyGraph& graph);
Status ReadConsistencyGraph(const std::filesystem::path& path,
                            ConsistencyGraph* graph);

// Writes exactly the supplied lines in their supplied order. No image
// selection, sorting, expansion, or source-view inference is performed.
Status WriteConfigLines(const std::filesystem::path& path,
                        const std::vector<std::string>& lines);

}  // namespace pocketworld::official_dense
