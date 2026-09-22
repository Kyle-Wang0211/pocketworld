#ifndef POCKETWORLD_PWOFFICIAL_DENSE_C_H_
#define POCKETWORLD_PWOFFICIAL_DENSE_C_H_

#include <float.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PW_OFFICIAL_DENSE_ABI_VERSION 1u
#define PW_OFFICIAL_DENSE_GPU_INDEX_CAPACITY 32u
#define PW_OFFICIAL_DENSE_PATH_CAPACITY 1024u

typedef enum pwofficial_dense_result {
  PW_OFFICIAL_DENSE_OK = 0,
  PW_OFFICIAL_DENSE_INVALID_ARGUMENT = 1,
  PW_OFFICIAL_DENSE_UNAVAILABLE = 2,
  PW_OFFICIAL_DENSE_IO_ERROR = 3,
  PW_OFFICIAL_DENSE_CANCELLED = 4,
  PW_OFFICIAL_DENSE_INTERNAL_ERROR = 5,
} pwofficial_dense_result_t;

// The numeric defaults and field meanings mirror COLMAP 4.1.1
// PatchMatchOptions and StereoFusionOptions. Integer flags are used instead of
// C/C++ bool so the public layout is stable across Dart/C/C++ FFI boundaries.
typedef struct pwofficial_dense_options {
  uint32_t struct_size;
  uint32_t abi_version;

  double depth_min;
  double depth_max;
  double sigma_spatial;
  double sigma_color;
  double ncc_sigma;
  double min_triangulation_angle;
  double incident_angle_sigma;
  double geom_consistency_regularizer;
  double geom_consistency_max_cost;
  double filter_min_ncc;
  double filter_min_triangulation_angle;
  double filter_geom_consistency_max_cost;
  double patch_match_cache_size;
  char gpu_index[PW_OFFICIAL_DENSE_GPU_INDEX_CAPACITY];
  int32_t patch_match_max_image_size;
  int32_t window_radius;
  int32_t window_step;
  int32_t num_samples;
  int32_t num_iterations;
  int32_t filter_min_num_consistent;
  int32_t patch_match_num_threads;
  int32_t geom_consistency;
  int32_t filter;
  int32_t allow_missing_files;
  int32_t write_consistency_graph;

  char mask_path[PW_OFFICIAL_DENSE_PATH_CAPACITY];
  int32_t fusion_num_threads;
  int32_t fusion_max_image_size;
  int32_t min_num_pixels;
  int32_t max_num_pixels;
  int32_t max_traversal_depth;
  double max_reproj_error;
  double max_depth_error;
  double max_normal_error;
  int32_t check_num_images;
  int32_t use_cache;
  double fusion_cache_size;
  float bounding_box_min[3];
  float bounding_box_max[3];
} pwofficial_dense_options_t;

// Returns the exact ABI version implemented by this binary.
uint32_t pwofficial_dense_version(void);

// Returns a thread-local, library-owned UTF-8 message. The pointer remains
// valid until the next pwofficial_dense_* call on the same thread.
const char* pwofficial_dense_last_error(void);

// Writes all official COLMAP 4.1.1 PatchMatch and StereoFusion defaults.
pwofficial_dense_result_t pwofficial_dense_default_options(
    pwofficial_dense_options_t* options);

// Returns 1 only if every certified gate is ready: frozen official source
// hashes, Vulkan loader/capabilities, CUDA-XORWOW parity, CUDA-texture parity,
// all shaders/dispatch stages, and official StereoFusion.
int32_t pwofficial_dense_is_available(void);

// Synchronous execution boundary. It never creates output_ply unless every
// certified readiness gate passes. The backend must atomically publish the PLY
// only after PatchMatch and StereoFusion both succeed.
pwofficial_dense_result_t pwofficial_dense_run(
    const char* workspace_path,
    const char* output_ply,
    const pwofficial_dense_options_t* options);

// Requests cancellation of a synchronous run from another caller. This does
// not create a worker thread or scheduling policy.
pwofficial_dense_result_t pwofficial_dense_cancel(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_PWOFFICIAL_DENSE_C_H_
