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

#include "stereo_fusion_bridge.h"

#include <exception>
#include <filesystem>
#include <string>
#include <system_error>

#if defined(PW_OFFICIAL_DENSE_WITH_COLMAP_4_1_1)
#include "colmap/mvs/fusion.h"
#include "colmap/util/ply.h"
#include <Eigen/Core>
#endif

namespace pocketworld::official_dense::fusion {
namespace {

namespace fs = std::filesystem;

class OutputTransaction final {
 public:
  explicit OutputTransaction(const fs::path& workspace_path)
      : ply_output_(workspace_path / "fused.ply"),
        visibility_output_(workspace_path / "fused.ply.vis"),
        ply_temporary_(workspace_path / "fused.ply.pwofficial.tmp"),
        visibility_temporary_(workspace_path /
                              "fused.ply.vis.pwofficial.tmp") {}

  ~OutputTransaction() {
    if (!committed_) {
      std::error_code ignored;
      std::filesystem::remove(ply_temporary_, ignored);
      std::filesystem::remove(visibility_temporary_, ignored);
      if (ply_published_) std::filesystem::remove(ply_output_, ignored);
    }
  }

  Status Prepare() const {
    std::error_code error;
    if (!fs::is_directory(ply_output_.parent_path(), error) || error) {
      return Status::Io("workspace is not a directory");
    }
    for (const fs::path& path : {ply_output_, visibility_output_,
                                 ply_temporary_, visibility_temporary_}) {
      error.clear();
      if (fs::exists(path, error) || error) {
        return Status::Io("refusing to overwrite fusion output: " +
                          path.string());
      }
    }
    return Status::Ok();
  }

  const fs::path& ply_temporary() const { return ply_temporary_; }
  const fs::path& visibility_temporary() const {
    return visibility_temporary_;
  }

  Status Commit() {
    std::error_code error;
    std::filesystem::rename(ply_temporary_, ply_output_, error);
    if (error) return Status::Io("cannot publish fused.ply: " + error.message());
    ply_published_ = true;

    error.clear();
    std::filesystem::rename(visibility_temporary_, visibility_output_, error);
    if (error) {
      return Status::Io("cannot publish fused.ply.vis: " + error.message());
    }
    committed_ = true;
    return Status::Ok();
  }

 private:
  fs::path ply_output_;
  fs::path visibility_output_;
  fs::path ply_temporary_;
  fs::path visibility_temporary_;
  bool ply_published_ = false;
  bool committed_ = false;
};

#if defined(PW_OFFICIAL_DENSE_WITH_COLMAP_4_1_1)
colmap::mvs::StereoFusionOptions ToOfficialOptions(
    const FusionOptions& options) {
  colmap::mvs::StereoFusionOptions official;
  official.mask_path = options.mask_path;
  official.num_threads = options.num_threads;
  official.max_image_size = options.max_image_size;
  official.min_num_pixels = options.min_num_pixels;
  official.max_num_pixels = options.max_num_pixels;
  official.max_traversal_depth = options.max_traversal_depth;
  official.max_reproj_error = options.max_reproj_error;
  official.max_depth_error = options.max_depth_error;
  official.max_normal_error = options.max_normal_error;
  official.check_num_images = options.check_num_images;
  official.use_cache = options.use_cache;
  official.cache_size = options.cache_size;
  official.bounding_box = std::make_pair(
      Eigen::Vector3f(options.bounding_box_min[0],
                      options.bounding_box_min[1],
                      options.bounding_box_min[2]),
      Eigen::Vector3f(options.bounding_box_max[0],
                      options.bounding_box_max[1],
                      options.bounding_box_max[2]));
  return official;
}
#endif

}  // namespace

Status RunStereoFusion(const fs::path& workspace_path,
                       const std::string& input_type,
                       const FusionOptions& options) {
  if (input_type != "geometric") {
    return Status::Invalid("official mobile fusion requires geometric input");
  }

#if !defined(PW_OFFICIAL_DENSE_WITH_COLMAP_4_1_1)
  (void)workspace_path;
  (void)options;
  return Status::Unavailable(
      "COLMAP 4.1.1 StereoFusion is not linked into this target");
#else
  OutputTransaction outputs(workspace_path);
  Status status = outputs.Prepare();
  if (!status.ok()) return status;

  try {
    const colmap::mvs::StereoFusionOptions official_options =
        ToOfficialOptions(options);
    colmap::mvs::StereoFusion fuser(official_options,
                                    workspace_path,
                                    "COLMAP",
                                    "",
                                    input_type);
    fuser.Run();
    colmap::WriteBinaryPlyPoints(outputs.ply_temporary(),
                                 fuser.GetFusedPoints());
    colmap::mvs::WritePointsVisibility(
        outputs.visibility_temporary(), fuser.GetFusedPointsVisibility());
    return outputs.Commit();
  } catch (const std::exception& error) {
    return Status::FusionError(error.what());
  } catch (...) {
    return Status::FusionError("COLMAP 4.1.1 StereoFusion failed");
  }
#endif
}

}  // namespace pocketworld::official_dense::fusion
