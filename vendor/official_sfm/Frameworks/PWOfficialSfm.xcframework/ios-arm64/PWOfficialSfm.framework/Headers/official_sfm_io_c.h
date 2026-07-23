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

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_OFFICIAL_SFM_IO_C_H
