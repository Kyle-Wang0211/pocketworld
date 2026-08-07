#ifndef POCKETWORLD_OFFICIAL_SFM_IO_C_H
#define POCKETWORLD_OFFICIAL_SFM_IO_C_H

#include "official_sfm_c.h"

#ifdef __cplusplus
extern "C" {
#endif

// Official-route file boundary: decodes the JPEG named by `jpeg_path` at its
// original pixel dimensions and forwards the resulting full-resolution luma
// plane to the frozen COLMAP-backed streaming core. No crop, resize, histogram
// normalization, or Dart/Flutter image transfer is performed. ImageIO replaces
// COLMAP's OpenImageIO reader, which is unavailable in the arm64 mobile build.
aether_sfm_result_t pwofficial_add_jpeg_frame(
    aether_sfm_session_t* session,
    const char* jpeg_path,
    double capture_timestamp,
    float fx,
    float fy,
    float cx,
    float cy,
    const double pose_qwxyz[4],
    const double pose_t[3],
    int* out_frame_id);

// Diagnostic-only v6 Phase-B cached-capture replay ABI. Status values mirror
// the private replay driver: 0=OFF, 1=OK, 2=invalid argument, 4=decode/extract
// failure, and 7=sealed. This route performs extraction/counting only.
typedef struct pwofficial_phase_b_report_v1 {
  uint64_t accepted_frames;
  uint64_t legacy_descriptor_rows_total;
  uint64_t coverage8192_rows_total;
  uint64_t canonical8192_rows_total;
  uint64_t frames_descriptor_gt_8192;
  double coverage_row_headroom;
  double canonical_row_headroom;
} pwofficial_phase_b_report_v1;

uint32_t pwofficial_phase_b_replay_create_v1(
    const char* ordered_manifest_sha256,
    const int64_t* ordered_frame_ids,
    const char* const* ordered_source_sha256,
    uint32_t frame_count,
    void** out_handle);

uint32_t pwofficial_phase_b_replay_add_jpeg_v1(
    void* handle,
    const char* jpeg_path,
    int64_t frame_id,
    const char* source_sha256,
    uint32_t thermal_state_status,
    int32_t thermal_state);

uint32_t pwofficial_phase_b_replay_seal_v1(
    void* handle,
    pwofficial_phase_b_report_v1* out_report);

void pwofficial_phase_b_replay_destroy_v1(void* handle);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_OFFICIAL_SFM_IO_C_H
