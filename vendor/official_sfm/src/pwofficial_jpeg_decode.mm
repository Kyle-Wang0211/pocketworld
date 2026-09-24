#include "../include/official_sfm_io_c.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>
#include <TargetConditionals.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>

#define PWOFFICIAL_IO_EXPORT __attribute__((visibility("default"), used))
#define PWOFFICIAL_IO_HIDDEN __attribute__((visibility("hidden")))

using PwofficialGpuExtractFn = int (*)(
    const uint8_t*, int, int, int, int, float*, uint8_t*, int, int*);

struct aether_preclamp_phase_b_report_v1 {
  uint64_t accepted_frames;
  uint64_t legacy_descriptor_rows_total;
  uint64_t coverage8192_rows_total;
  uint64_t canonical8192_rows_total;
  uint64_t frames_descriptor_gt_8192;
  double coverage_row_headroom;
  double canonical_row_headroom;
};

#if !TARGET_OS_SIMULATOR
extern "C" PWOFFICIAL_IO_HIDDEN uint32_t
aether_preclamp_phase_b_replay_create_v1(
    const char*, const int64_t*, const char* const*, uint32_t, void**);
extern "C" PWOFFICIAL_IO_HIDDEN uint32_t
aether_preclamp_phase_b_replay_add_gray_v1(
    void*, const uint8_t*, int, int, int64_t, const char*, uint32_t, int32_t,
    PwofficialGpuExtractFn);
extern "C" PWOFFICIAL_IO_HIDDEN uint32_t
aether_preclamp_phase_b_replay_seal_v1(
    void*, aether_preclamp_phase_b_report_v1*);
extern "C" PWOFFICIAL_IO_HIDDEN void
aether_preclamp_phase_b_replay_destroy_v1(void*);
extern "C" PWOFFICIAL_IO_HIDDEN int aether_dsp_sift_extract_gpu(
    const uint8_t*, int, int, int, int, float*, uint8_t*, int, int*);
#endif

namespace {

aether_sfm_result_t DecodeOfficialJpegGray(
    const char* jpeg_path,
    std::vector<uint8_t>* gray,
    int* out_width,
    int* out_height) {
  if (jpeg_path == nullptr || jpeg_path[0] == '\0' || gray == nullptr ||
      out_width == nullptr || out_height == nullptr) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }

  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(jpeg_path),
      static_cast<CFIndex>(std::strlen(jpeg_path)),
      false);
  if (url == nullptr) return AETHER_SFM_ERR_INVALID_ARG;

  CGImageSourceRef source = CGImageSourceCreateWithURL(url, nullptr);
  CFRelease(url);
  if (source == nullptr) return AETHER_SFM_ERR_EXTRACT;

  CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
  CFRelease(source);
  if (image == nullptr) return AETHER_SFM_ERR_EXTRACT;

  const size_t width = CGImageGetWidth(image);
  const size_t height = CGImageGetHeight(image);
  if (width != 4032 || height != 3024) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_INVALID_ARG;
  }

  try {
    gray->assign(width * height, 0);
  } catch (...) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_EXTRACT;
  }
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceGray();
  if (color_space == nullptr) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_EXTRACT;
  }
  CGContextRef context = CGBitmapContextCreate(
      gray->data(), width, height, 8, width, color_space, kCGImageAlphaNone);
  CGColorSpaceRelease(color_space);
  if (context == nullptr) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_EXTRACT;
  }

  // Keep the JPEG's original pixel grid exactly. Both live and replay consume
  // this one helper, so neither route may introduce a crop, resize, or CTM flip.
  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextDrawImage(
      context,
      CGRectMake(0, 0, static_cast<CGFloat>(width),
                 static_cast<CGFloat>(height)),
      image);
  CGContextRelease(context);
  CGImageRelease(image);
  *out_width = static_cast<int>(width);
  *out_height = static_cast<int>(height);
  return AETHER_SFM_OK;
}

}  // namespace

/* [EXTRACT-PREFETCH 2026-08-09] JPEG 版预取:与 add_jpeg 同一 decode helper
   (同像素网格、零 crop/resize/flip),解码后把 gray 转手给核内专属提取线程。
   把"下一帧"的解码+提取都搬出关键路径 —— 堵车(spool 非空)时由 facade 在
   派发当前帧之前调用。env 关时先廉价早退,不白解码 12MP。
   返回:0=已入队 1=关闭/无效/解码失败 2=busy(深度1队列还占着,跳过即可)。 */
extern "C" PWOFFICIAL_IO_EXPORT int
pwofficial_prefetch_jpeg_frame(aether_sfm_session_t* session,
                               const char* jpeg_path) {
  if (session == nullptr || jpeg_path == nullptr || jpeg_path[0] == '\0') {
    return 1;
  }
  static const bool enabled = [] {
    const char* e = getenv("OFFICIAL_AETHER_EXTRACT_PREFETCH");
    return e != nullptr && e[0] == '1';
  }();
  if (!enabled) return 1;
  std::vector<uint8_t> gray;
  int width = 0;
  int height = 0;
  if (DecodeOfficialJpegGray(jpeg_path, &gray, &width, &height) !=
      AETHER_SFM_OK) {
    return 1;
  }
  return pwofficial_prefetch_frame(session, gray.data(), width, height);
}

extern "C" PWOFFICIAL_IO_EXPORT aether_sfm_result_t
pwofficial_add_jpeg_frame(
    aether_sfm_session_t* session,
    const char* jpeg_path,
    double capture_timestamp,
    float fx,
    float fy,
    float cx,
    float cy,
    const double pose_qwxyz[4],
    const double pose_t[3],
    int* out_frame_id) {
  if (session == nullptr ||
      jpeg_path == nullptr ||
      jpeg_path[0] == '\0' ||
      !std::isfinite(capture_timestamp) ||
      capture_timestamp < 0.0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  std::vector<uint8_t> gray;
  int width = 0;
  int height = 0;
  const aether_sfm_result_t decode =
      DecodeOfficialJpegGray(jpeg_path, &gray, &width, &height);
  if (decode != AETHER_SFM_OK) return decode;

  return pwofficial_add_frame(
      session,
      gray.data(),
      width,
      height,
      fx,
      fy,
      cx,
      cy,
      pose_qwxyz,
      pose_t,
      out_frame_id);
}

// [DEVICE-POSE-TRUST-V1 2026-09-24] v1 + device_pose_trusted (see
// official_sfm_io_c.h). Same validation and decode as v1; forwards to the
// trust-carrying core entry.
extern "C" PWOFFICIAL_IO_EXPORT aether_sfm_result_t
pwofficial_add_jpeg_frame_v2(
    aether_sfm_session_t* session,
    const char* jpeg_path,
    double capture_timestamp,
    float fx,
    float fy,
    float cx,
    float cy,
    const double pose_qwxyz[4],
    const double pose_t[3],
    int32_t device_pose_trusted,
    int* out_frame_id) {
  if (session == nullptr ||
      jpeg_path == nullptr ||
      jpeg_path[0] == '\0' ||
      !std::isfinite(capture_timestamp) ||
      capture_timestamp < 0.0) {
    return AETHER_SFM_ERR_INVALID_ARG;
  }
  std::vector<uint8_t> gray;
  int width = 0;
  int height = 0;
  const aether_sfm_result_t decode =
      DecodeOfficialJpegGray(jpeg_path, &gray, &width, &height);
  if (decode != AETHER_SFM_OK) return decode;

  return pwofficial_add_frame_v2(
      session,
      gray.data(),
      width,
      height,
      fx,
      fy,
      cx,
      cy,
      pose_qwxyz,
      pose_t,
      device_pose_trusted,
      out_frame_id);
}

extern "C" PWOFFICIAL_IO_EXPORT uint32_t
pwofficial_phase_b_replay_create_v1(
    const char* ordered_manifest_sha256, const int64_t* ordered_frame_ids,
    const char* const* ordered_source_sha256, uint32_t frame_count,
    void** out_handle) {
#if TARGET_OS_SIMULATOR
  (void)ordered_manifest_sha256;
  (void)ordered_frame_ids;
  (void)ordered_source_sha256;
  (void)frame_count;
  if (out_handle != nullptr) *out_handle = nullptr;
  return 0;
#else
  return aether_preclamp_phase_b_replay_create_v1(
      ordered_manifest_sha256, ordered_frame_ids, ordered_source_sha256,
      frame_count, out_handle);
#endif
}

extern "C" PWOFFICIAL_IO_EXPORT uint32_t
pwofficial_phase_b_replay_add_jpeg_v1(
    void* handle, const char* jpeg_path, int64_t frame_id,
    const char* source_sha256, uint32_t thermal_state_status,
    int32_t thermal_state) {
#if TARGET_OS_SIMULATOR
  (void)handle;
  (void)jpeg_path;
  (void)frame_id;
  (void)source_sha256;
  (void)thermal_state_status;
  (void)thermal_state;
  return 0;
#else
  if (handle == nullptr || frame_id < 0 || source_sha256 == nullptr) return 2;
  std::vector<uint8_t> gray;
  int width = 0;
  int height = 0;
  const aether_sfm_result_t decode =
      DecodeOfficialJpegGray(jpeg_path, &gray, &width, &height);
  if (decode == AETHER_SFM_ERR_INVALID_ARG) return 2;
  if (decode != AETHER_SFM_OK) return 4;
  return aether_preclamp_phase_b_replay_add_gray_v1(
      handle, gray.data(), width, height, frame_id, source_sha256,
      thermal_state_status, thermal_state, &aether_dsp_sift_extract_gpu);
#endif
}

extern "C" PWOFFICIAL_IO_EXPORT uint32_t
pwofficial_phase_b_replay_seal_v1(
    void* handle, pwofficial_phase_b_report_v1* out_report) {
  if (out_report != nullptr) std::memset(out_report, 0, sizeof(*out_report));
#if TARGET_OS_SIMULATOR
  (void)handle;
  return 0;
#else
  if (handle == nullptr || out_report == nullptr) return 2;
  aether_preclamp_phase_b_report_v1 internal{};
  const uint32_t status =
      aether_preclamp_phase_b_replay_seal_v1(handle, &internal);
  if (status == 7) {
    out_report->accepted_frames = internal.accepted_frames;
    out_report->legacy_descriptor_rows_total =
        internal.legacy_descriptor_rows_total;
    out_report->coverage8192_rows_total = internal.coverage8192_rows_total;
    out_report->canonical8192_rows_total = internal.canonical8192_rows_total;
    out_report->frames_descriptor_gt_8192 =
        internal.frames_descriptor_gt_8192;
    out_report->coverage_row_headroom = internal.coverage_row_headroom;
    out_report->canonical_row_headroom = internal.canonical_row_headroom;
  }
  return status;
#endif
}

extern "C" PWOFFICIAL_IO_EXPORT void
pwofficial_phase_b_replay_destroy_v1(void* handle) {
#if TARGET_OS_SIMULATOR
  (void)handle;
#else
  aether_preclamp_phase_b_replay_destroy_v1(handle);
#endif
}
