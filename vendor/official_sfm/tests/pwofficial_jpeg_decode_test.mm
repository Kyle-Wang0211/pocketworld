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

int main() {
  const std::string base =
      "/tmp/pwofficial_jpeg_decode_test_" + std::to_string(getpid());
  const std::string full_path = base + "_4032x3024.jpg";
  const std::string preview_path = base + "_1920x1440.jpg";
  if (!WriteBandJpeg(full_path, 4032, 3024) ||
      !WriteBandJpeg(preview_path, 1920, 1440)) {
    return 2;
  }

  int frame_id = -1;
  const auto full_rc = pwofficial_add_jpeg_frame(
      reinterpret_cast<aether_sfm_session_t*>(0x1),
      full_path.c_str(),
      10.125,
      1,
      1,
      1,
      1,
      nullptr,
      nullptr,
      &frame_id);
  const bool full_ok =
      full_rc == AETHER_SFM_OK &&
      frame_id == 7 &&
      g_add_frame_calls == 1 &&
      g_width == 4032 &&
      g_height == 3024 &&
      g_samples[0] < 50 &&
      g_samples[1] > 70 &&
      g_samples[1] < 160 &&
      g_samples[2] > 190;

  const auto preview_rc = pwofficial_add_jpeg_frame(
      reinterpret_cast<aether_sfm_session_t*>(0x1),
      preview_path.c_str(),
      10.250,
      1,
      1,
      1,
      1,
      nullptr,
      nullptr,
      &frame_id);
  const bool preview_rejected =
      preview_rc == AETHER_SFM_ERR_INVALID_ARG && g_add_frame_calls == 1;

  constexpr char kManifest[] =
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  constexpr char kSource[] =
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  const int64_t replay_frame_ids[] = {17};
  const char* replay_sources[] = {kSource};
  void* replay = nullptr;
  const uint32_t replay_create = pwofficial_phase_b_replay_create_v1(
      kManifest, replay_frame_ids, replay_sources, 1, &replay);
  const uint32_t replay_full = pwofficial_phase_b_replay_add_jpeg_v1(
      replay, full_path.c_str(), 17, kSource, 1, 2);
  const uint32_t replay_preview = pwofficial_phase_b_replay_add_jpeg_v1(
      replay, preview_path.c_str(), 17, kSource, 1, 2);
  pwofficial_phase_b_report_v1 replay_report{};
  const uint32_t replay_seal =
      pwofficial_phase_b_replay_seal_v1(replay, &replay_report);
  pwofficial_phase_b_replay_destroy_v1(replay);
  const bool replay_ok =
      replay_create == 1 && replay_full == 1 && replay_preview == 2 &&
      g_replay_add_calls == 1 && g_replay_width == 4032 &&
      g_replay_height == 3024 && g_replay_samples[0] == g_samples[0] &&
      g_replay_samples[1] == g_samples[1] &&
      g_replay_samples[2] == g_samples[2] && g_add_frame_calls == 1 &&
      replay_seal == 7 && replay_report.accepted_frames == 1 &&
      replay_report.legacy_descriptor_rows_total == 9000 &&
      g_replay_destroy_calls == 1;

  std::remove(full_path.c_str());
  std::remove(preview_path.c_str());
  if (!full_ok || !preview_rejected || !replay_ok) {
    std::fprintf(
        stderr,
        "full_rc=%d calls=%d frame=%d dims=%dx%d rows=%d/%d/%d "
        "preview_rc=%d replay=%u/%u/%u calls=%d dims=%dx%d destroy=%d\n",
        full_rc,
        g_add_frame_calls,
        frame_id,
        g_width,
        g_height,
        g_samples[0],
        g_samples[1],
        g_samples[2],
        preview_rc,
        replay_create,
        replay_full,
        replay_preview,
        g_replay_add_calls,
        g_replay_width,
        g_replay_height,
        g_replay_destroy_calls);
    return 3;
  }
  std::printf(
      "PASS live+replay share 4032x3024 row order=%d/%d/%d; "
      "1920x1440 rejected before both consumers\n",
      g_samples[0],
      g_samples[1],
      g_samples[2]);
  return 0;
}
