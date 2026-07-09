// pwsfm_export_shim.c — dlsym-visibility shim for the on-device SfM ABI.
//
// WHY: the Jun-29 COLMAP-4.0.4 libglomap_core.a compiles its TUs with
// -fvisibility=hidden, so every aether_sfm_* symbol is "private external"
// in the archive and gets LOCALIZED when statically linked into Runner —
// dart:ffi's dlsym(RTLD_DEFAULT, …) then can't find them (verified via
// `dyld_info -exports`: zero aether_sfm entries; nm shows lowercase 't').
// No linker flag can re-export a hidden symbol.
//
// FIX: this TU is compiled INTO the pod with explicit default visibility.
// Static linking within the binary is unaffected by hidden visibility, so
// these pure forwarders resolve against the force-loaded archive at link
// time, and their OWN pwsfm_* names land in the export trie for dlsym.
// Pure pass-through — zero algorithm logic lives here. The Dart binding
// (aether_sfm_ffi.dart) looks up the pwsfm_* names.
//
// Runner links this via -Wl,-u,_pwsfm_* (see aether3d_ffi.podspec): -u both
// pulls this object out of the pod archive and keeps each symbol through
// Release -dead_strip.
//
// SIMULATOR: the sim stub libaether_sfm.a predates finalize_async/status,
// so those two forwards would be undefined there — guarded to return
// UNSUPPORTED instead (the Dart layer gates on isSupported and never calls
// SfM on the simulator anyway; this just keeps the sim LINK green).

#include <TargetConditionals.h>

#include "../include/aether_sfm_c.h"

#define PWSFM_EXPORT __attribute__((visibility("default"), used))

PWSFM_EXPORT void pwsfm_options_default(aether_sfm_options_t* out) {
  aether_sfm_options_default(out);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_run(const char* db_path,
                                           const char* image_path,
                                           const aether_sfm_options_t* options,
                                           aether_sfm_session_t** out_session,
                                           char* out_json, int out_cap) {
  return aether_sfm_run(db_path, image_path, options, out_session, out_json,
                        out_cap);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_create(const char* db_path,
                                              const aether_sfm_options_t* options,
                                              aether_sfm_session_t** out_session) {
  return aether_sfm_create(db_path, options, out_session);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_add_frame(aether_sfm_session_t* s,
                                                 const uint8_t* gray,
                                                 int width, int height,
                                                 float fx, float fy,
                                                 float cx, float cy,
                                                 const double pose_qwxyz[4],
                                                 const double pose_t[3],
                                                 int* out_frame_id) {
  return aether_sfm_add_frame(s, gray, width, height, fx, fy, cx, cy,
                              pose_qwxyz, pose_t, out_frame_id);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_finalize_async(aether_sfm_session_t* s,
                                                      char* out_json,
                                                      int out_cap) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_json;
  (void)out_cap;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_finalize_async(s, out_json, out_cap);
#endif
}

PWSFM_EXPORT int pwsfm_finalize_status(aether_sfm_session_t* s) {
#if TARGET_OS_SIMULATOR
  (void)s;
  return AETHER_SFM_FINALIZE_ERROR;
#else
  return aether_sfm_finalize_status(s);
#endif
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_get_poses(aether_sfm_session_t* s,
                                                 aether_sfm_pose_t* out_poses,
                                                 int cap, int* out_count) {
  return aether_sfm_get_poses(s, out_poses, cap, out_count);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_get_points(aether_sfm_session_t* s,
                                                  aether_sfm_point_t** out_points,
                                                  int* out_count) {
  return aether_sfm_get_points(s, out_points, out_count);
}

PWSFM_EXPORT void pwsfm_points_free(aether_sfm_point_t* points) {
  aether_sfm_points_free(points);
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_get_preview_points(
    aether_sfm_session_t* s, float* out_xyz, int cap, int* out_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_xyz;
  (void)cap;
  if (out_count) *out_count = 0;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_preview_points(s, out_xyz, cap, out_count);
#endif
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_get_points_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_points;
  (void)out_count;
  (void)out_obs_offsets;
  (void)out_obs;
  (void)out_obs_count;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_points_tracked(s, out_points, out_count,
                                       out_obs_offsets, out_obs,
                                       out_obs_count);
#endif
}

PWSFM_EXPORT void pwsfm_track_obs_free(int32_t* offsets,
                                       aether_sfm_track_obs_t* obs) {
#if TARGET_OS_SIMULATOR
  (void)offsets;
  (void)obs;
#else
  aether_sfm_track_obs_free(offsets, obs);
#endif
}

PWSFM_EXPORT aether_sfm_result_t pwsfm_get_preview_tracked(
    aether_sfm_session_t* s, aether_sfm_point_t** out_points, int* out_count,
    int32_t** out_obs_offsets, aether_sfm_track_obs_t** out_obs,
    int64_t* out_obs_count) {
#if TARGET_OS_SIMULATOR
  (void)s;
  (void)out_points;
  (void)out_count;
  (void)out_obs_offsets;
  (void)out_obs;
  (void)out_obs_count;
  return AETHER_SFM_ERR_UNSUPPORTED;
#else
  return aether_sfm_get_preview_tracked(s, out_points, out_count,
                                        out_obs_offsets, out_obs,
                                        out_obs_count);
#endif
}

PWSFM_EXPORT void pwsfm_debug_last(aether_sfm_session_t* s, double* extract_ms,
                                   double* match_ms, int* n_cand,
                                   int* gpu_matches, int* cpu_matches) {
#if TARGET_OS_SIMULATOR
  (void)s; (void)extract_ms; (void)match_ms; (void)n_cand;
  (void)gpu_matches; (void)cpu_matches;
#else
  aether_sfm_debug_last(s, extract_ms, match_ms, n_cand, gpu_matches,
                        cpu_matches);
#endif
}

PWSFM_EXPORT void pwsfm_stream_stats(aether_sfm_session_t* s, int64_t* tvg_pairs,
                                     int64_t* raw_pairs, int64_t* grow_accepted,
                                     int64_t* grow_rejected,
                                     int64_t* reproj_filtered,
                                     int64_t* tri_filtered) {
#if TARGET_OS_SIMULATOR
  (void)s; (void)tvg_pairs; (void)raw_pairs; (void)grow_accepted;
  (void)grow_rejected; (void)reproj_filtered; (void)tri_filtered;
#else
  aether_sfm_stream_stats(s, tvg_pairs, raw_pairs, grow_accepted, grow_rejected,
                          reproj_filtered, tri_filtered);
#endif
}

PWSFM_EXPORT void pwsfm_free(aether_sfm_session_t* s) {
  aether_sfm_free(s);
}
