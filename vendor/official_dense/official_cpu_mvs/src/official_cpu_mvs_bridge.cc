#include "official_cpu_mvs/bridge.h"

#include "colmap/mvs/fusion.h"

extern "C" int pw_official_cpu_mvs_default_options_smoke(void) {
  const colmap::mvs::StereoFusionOptions options;
  return options.num_threads == -1 && options.max_image_size == -1 &&
                 options.min_num_pixels == 5 &&
                 options.max_num_pixels == 10000 &&
                 options.max_traversal_depth == 100 &&
                 options.check_num_images == 50 && !options.use_cache
             ? 0
             : 1;
}

extern "C" int pw_official_cpu_mvs_run_unavailable(void) {
  return -1;
}

