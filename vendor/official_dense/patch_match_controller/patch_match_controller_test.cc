#include "patch_match_controller.h"

#include <limits>

namespace od = pocketworld::official_dense::patch_match;

int main() {
  od::PatchMatchOptions options;
  if (!options.Check()) return 1;

  options.window_radius = 1;
  options.window_step = 2;
  if (!options.Check()) return 2;
  options.window_radius = 32;
  if (!options.Check()) return 3;
  options.window_radius = 0;
  if (options.Check()) return 4;
  options.window_radius = 33;
  if (options.Check()) return 5;
  options = {};
  options.window_step = 0;
  if (options.Check()) return 6;
  options.window_step = 3;
  if (options.Check()) return 7;

  options = {};
  options.depth_min = 10.0;
  options.depth_max = 1.0;
  if (options.Check()) return 8;
  options.depth_min = -1.0;
  options.depth_max = 1.0;
  if (options.Check()) return 9;
  options = {};
  options.sigma_color = 0.0;
  if (options.Check()) return 10;
  options = {};
  options.num_samples = 0;
  if (options.Check()) return 11;
  options = {};
  options.ncc_sigma = 0.0;
  if (options.Check()) return 12;
  options = {};
  options.min_triangulation_angle = -0.1;
  if (options.Check()) return 13;
  options.min_triangulation_angle = 180.0;
  if (options.Check()) return 14;
  options = {};
  options.incident_angle_sigma = 0.0;
  if (options.Check()) return 15;
  options = {};
  options.num_iterations = 0;
  if (options.Check()) return 16;
  options = {};
  options.geom_consistency_regularizer = -0.1;
  if (options.Check()) return 17;
  options = {};
  options.geom_consistency_max_cost = -0.1;
  if (options.Check()) return 18;
  options = {};
  options.filter_min_ncc = -1.1;
  if (options.Check()) return 19;
  options.filter_min_ncc = 1.1;
  if (options.Check()) return 20;
  options = {};
  options.filter_min_triangulation_angle = -0.1;
  if (options.Check()) return 21;
  options.filter_min_triangulation_angle = 180.1;
  if (options.Check()) return 22;
  options = {};
  options.filter_min_num_consistent = -1;
  if (options.Check()) return 23;
  options = {};
  options.filter_geom_consistency_max_cost = -0.1;
  if (options.Check()) return 24;
  options = {};
  options.cache_size = 0.0;
  if (options.Check()) return 25;
  options = {};
  options.num_threads = -2;
  if (options.Check()) return 26;

  // COLMAP's comparison macros reject NaN for every strict/range check.
  options = {};
  options.sigma_color = std::numeric_limits<double>::quiet_NaN();
  if (options.Check()) return 27;
  return 0;
}
