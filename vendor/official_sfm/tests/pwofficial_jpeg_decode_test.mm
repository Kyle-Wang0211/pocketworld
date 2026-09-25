#include "../include/official_sfm_io_c.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>

static unsigned char g_samples[3] = {};
static int g_width = 0;
static int g_height = 0;
static int g_add_frame_calls = 0;
static unsigned char g_replay_samples[3] = {};
static int g_replay_width = 0;
static int g_replay_height = 0;
static int g_replay_add_calls = 0;
static int g_replay_destroy_calls = 0;

struct aether_preclamp_phase_b_report_v1 {
  uint64_t accepted_frames;
  uint64_t legacy_descriptor_rows_total;
  uint64_t coverage8192_rows_total;
  uint64_t canonical8192_rows_total;
  uint64_t frames_descriptor_gt_8192;
  double coverage_row_headroom;
  double canonical_row_headroom;
};

extern "C" uint32_t aether_preclamp_phase_b_replay_create_v1(
    const char*, const int64_t*, const char* const*, uint32_t, void** out) {
  *out = reinterpret_cast<void*>(0x2);
  return 1;
}

extern "C" uint32_t aether_preclamp_phase_b_replay_add_gray_v1(
    void*, const uint8_t* gray, int width, int height, int64_t, const char*,
    uint32_t, int32_t,
    int (*extractor)(const uint8_t*, int, int, int, int, float*, uint8_t*, int,
                     int*)) {
  ++g_replay_add_calls;
  g_replay_width = width;
  g_replay_height = height;
  g_replay_samples[0] = gray[0];
  g_replay_samples[1] = gray[(height / 2) * width];
  g_replay_samples[2] = gray[(height - 1) * width];
  return extractor == nullptr ? 2 : 1;
}

extern "C" uint32_t aether_preclamp_phase_b_replay_seal_v1(
    void*, aether_preclamp_phase_b_report_v1* out) {
  out->accepted_frames = 1;
  out->legacy_descriptor_rows_total = 9000;
  out->coverage8192_rows_total = 8192;
  out->canonical8192_rows_total = 8192;
  out->frames_descriptor_gt_8192 = 1;
  out->coverage_row_headroom = 808.0 / 9000.0;
  out->canonical_row_headroom = 808.0 / 9000.0;
  return 7;
}

extern "C" void aether_preclamp_phase_b_replay_destroy_v1(void*) {
  ++g_replay_destroy_calls;
}

extern "C" int aether_dsp_sift_extract_gpu(
    const uint8_t*, int, int, int, int, float*, uint8_t*, int, int*) {
  return 0;
}

extern "C" aether_sfm_result_t pwofficial_add_frame(
    aether_sfm_session_t*,
    const uint8_t* gray,
    int width,
    int height,
    float,
    float,
    float,
    float,
    const double[4],
    const double[3],
    int* out_frame_id) {
  ++g_add_frame_calls;
  g_width = width;
  g_height = height;
  g_samples[0] = gray[0];
  g_samples[1] = gray[(height / 2) * width];
  g_samples[2] = gray[(height - 1) * width];
  if (out_frame_id != nullptr) *out_frame_id = 7;
  return AETHER_SFM_OK;
}

// [ENTRY-ANY-4X3 2026-09-25] fixC 之后 pwofficial_jpeg_decode.mm 还引用这两个核入口;
// 此前测试没补桩,基线本身就链接失败(Undefined _pwofficial_add_frame_v2 /
// _pwofficial_prefetch_frame)。桩的行为与 pwofficial_add_frame 桩相同。
static int g_add_frame_v2_calls = 0;
static int g_last_trusted = -1;
extern "C" aether_sfm_result_t pwofficial_add_frame_v2(
    aether_sfm_session_t*,
    const uint8_t* gray,
    int width,
    int height,
    float,
    float,
    float,
    float,
    const double[4],
    const double[3],
    int32_t device_pose_trusted,
    int* out_frame_id) {
  ++g_add_frame_v2_calls;
  g_last_trusted = device_pose_trusted;
  g_width = width;
  g_height = height;
  g_samples[0] = gray[0];
  g_samples[1] = gray[(height / 2) * width];
  g_samples[2] = gray[(height - 1) * width];
  if (out_frame_id != nullptr) *out_frame_id = 8;
  return AETHER_SFM_OK;
}

extern "C" int pwofficial_prefetch_frame(
    aether_sfm_session_t*, const uint8_t*, int, int) {
  return 0;
}

static bool WriteBandJpeg(
    const std::string& path,
    size_t width,
    size_t height) {
  auto* pixels = static_cast<unsigned char*>(std::malloc(width * height));
  if (pixels == nullptr) return false;
  for (size_t y = 0; y < height; ++y) {
    const unsigned char value =
        y < height / 3 ? 10 : (y < (height * 2) / 3 ? 110 : 230);
    std::memset(pixels + y * width, value, width);
  }

  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceGray();
  CGContextRef context = color_space == nullptr
      ? nullptr
      : CGBitmapContextCreate(
            pixels, width, height, 8, width, color_space, kCGImageAlphaNone);
  if (color_space != nullptr) CGColorSpaceRelease(color_space);
  if (context == nullptr) {
    std::free(pixels);
    return false;
  }
  CGImageRef image = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (image == nullptr) {
    std::free(pixels);
    return false;
  }

  CFURLRef url = CFURLCreateFromFileSystemRepresentation(
      kCFAllocatorDefault,
      reinterpret_cast<const UInt8*>(path.c_str()),
      static_cast<CFIndex>(path.size()),
      false);
  CGImageDestinationRef destination = url == nullptr
      ? nullptr
      : CGImageDestinationCreateWithURL(
            url, CFSTR("public.jpeg"), 1, nullptr);
  if (url != nullptr) CFRelease(url);
  if (destination == nullptr) {
    CGImageRelease(image);
    std::free(pixels);
    return false;
  }

  float quality = 1.0f;
  int orientation = 6;
  CFNumberRef quality_number = CFNumberCreate(
      kCFAllocatorDefault, kCFNumberFloatType, &quality);
  CFNumberRef orientation_number = CFNumberCreate(
      kCFAllocatorDefault, kCFNumberIntType, &orientation);
  const void* keys[] = {
      kCGImageDestinationLossyCompressionQuality,
      kCGImagePropertyOrientation,
  };
  const void* values[] = {quality_number, orientation_number};
  CFDictionaryRef properties = CFDictionaryCreate(
      kCFAllocatorDefault,
      keys,
      values,
      2,
      &kCFTypeDictionaryKeyCallBacks,
      &kCFTypeDictionaryValueCallBacks);
  CGImageDestinationAddImage(destination, image, properties);
  const bool ok = CGImageDestinationFinalize(destination);

  CFRelease(properties);
  CFRelease(quality_number);
  CFRelease(orientation_number);
  CFRelease(destination);
  CGImageRelease(image);
  std::free(pixels);
  return ok;
}

static bool BandsOk() {
  return g_samples[0] < 50 && g_samples[1] > 70 && g_samples[1] < 160 &&
         g_samples[2] > 190;
}

int main() {
  const std::string base =
      "/tmp/pwofficial_jpeg_decode_test_" + std::to_string(getpid());
  struct Case {
    int w, h;
    bool accept;
    int32_t status;
  };
  // [ENTRY-ANY-4X3 2026-09-25] 写出来的 JPEG 都带 EXIF Orientation=6(与真机照片一样:
  // 像素按传感器横向存、朝向写在 EXIF 里)。判据看的是原始网格,所以 4032x3024 仍按横向 4:3 收。
  const Case cases[] = {
      {4032, 3024, true, PWOFFICIAL_PHOTO_SIZE_OK},
      {1920, 1440, true, PWOFFICIAL_PHOTO_SIZE_OK},  // 以前被拒,现在收
      {3264, 2448, true, PWOFFICIAL_PHOTO_SIZE_OK},
      {4080, 3072, true, PWOFFICIAL_PHOTO_SIZE_OK},  // CameraX mod16 意义下的 4:3
      {1920, 1080, false, PWOFFICIAL_PHOTO_SIZE_NOT_4_3},
      {1440, 1080, false, PWOFFICIAL_PHOTO_SIZE_LONG_SIDE_BELOW_MIN},
      {1440, 1920, false, PWOFFICIAL_PHOTO_SIZE_NOT_SENSOR_ORIENTATION},
  };
  int failures = 0;
  int expected_v1_calls = 0;
  int expected_v2_calls = 0;
  int expected_replay_calls = 0;
  for (const Case& c : cases) {
    const std::string path = base + "_" + std::to_string(c.w) + "x" +
                             std::to_string(c.h) + ".jpg";
    if (!WriteBandJpeg(path, static_cast<size_t>(c.w),
                       static_cast<size_t>(c.h))) {
      return 2;
    }
    const int32_t status = pwofficial_photo_size_status_v1(c.w, c.h);
    int frame_id = -1;
    g_width = g_height = 0;
    const auto v1 = pwofficial_add_jpeg_frame(
        reinterpret_cast<aether_sfm_session_t*>(0x1), path.c_str(), 10.125, 1,
        1, 1, 1, nullptr, nullptr, &frame_id);
    const bool v1_ok = c.accept
        ? (v1 == AETHER_SFM_OK && frame_id == 7 && g_width == c.w &&
           g_height == c.h && BandsOk())
        : (v1 == AETHER_SFM_ERR_INVALID_ARG);
    if (c.accept) ++expected_v1_calls;
    frame_id = -1;
    g_width = g_height = 0;
    const auto v2 = pwofficial_add_jpeg_frame_v2(
        reinterpret_cast<aether_sfm_session_t*>(0x1), path.c_str(), 10.25, 1,
        1, 1, 1, nullptr, nullptr, /*device_pose_trusted=*/0, &frame_id);
    const bool v2_ok = c.accept
        ? (v2 == AETHER_SFM_OK && frame_id == 8 && g_width == c.w &&
           g_height == c.h && g_last_trusted == 0 && BandsOk())
        : (v2 == AETHER_SFM_ERR_INVALID_ARG);
    if (c.accept) ++expected_v2_calls;

    constexpr char kManifest[] =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    constexpr char kSource[] =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const int64_t replay_frame_ids[] = {17};
    const char* replay_sources[] = {kSource};
    void* replay = nullptr;
    pwofficial_phase_b_replay_create_v1(kManifest, replay_frame_ids,
                                        replay_sources, 1, &replay);
    g_replay_width = g_replay_height = 0;
    const uint32_t replay_rc = pwofficial_phase_b_replay_add_jpeg_v1(
        replay, path.c_str(), 17, kSource, 1, 2);
    pwofficial_phase_b_replay_destroy_v1(replay);
    const bool replay_ok = c.accept
        ? (replay_rc == 1 && g_replay_width == c.w && g_replay_height == c.h &&
           g_replay_samples[0] == g_samples[0] &&
           g_replay_samples[1] == g_samples[1] &&
           g_replay_samples[2] == g_samples[2])
        : (replay_rc == 2);
    if (c.accept) ++expected_replay_calls;

    const bool ok = status == c.status && v1_ok && v2_ok && replay_ok &&
                    g_add_frame_calls == expected_v1_calls &&
                    g_add_frame_v2_calls == expected_v2_calls &&
                    g_replay_add_calls == expected_replay_calls;
    std::printf("%s %dx%d status=%d v1=%d v2=%d replay=%u\n",
                ok ? "ok  " : "FAIL", c.w, c.h, status, v1, v2, replay_rc);
    if (!ok) ++failures;
    std::remove(path.c_str());
  }
  // 纯算术口:不碰文件也能查。
  if (pwofficial_photo_size_status_v1(0, 0) != PWOFFICIAL_PHOTO_SIZE_INVALID ||
      pwofficial_photo_size_status_v1(8160, 6144) != PWOFFICIAL_PHOTO_SIZE_OK) {
    ++failures;
  }
  if (failures != 0) return 3;
  std::printf(
      "PASS live(v1,v2)+replay share one grid for every accepted 4:3 size; "
      "16:9 / long side < %d / portrait grid rejected before any consumer\n",
      PWOFFICIAL_PHOTO_MIN_LONG_SIDE);
  return 0;
}
