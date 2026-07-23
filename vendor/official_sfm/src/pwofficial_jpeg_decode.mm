#include "../include/official_sfm_io_c.h"

#include <CoreGraphics/CoreGraphics.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ImageIO/ImageIO.h>

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <vector>

#define PWOFFICIAL_IO_EXPORT __attribute__((visibility("default"), used))

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
  // The official route accepts only the native 12 MP 4:3 still contract.
  // This native gate prevents a preview-sized JPEG from entering even if a
  // caller bypasses the Dart validation layer.
  if (width != 4032 || height != 3024) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_INVALID_ARG;
  }

  std::vector<uint8_t> gray(width * height);
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceGray();
  if (color_space == nullptr) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_EXTRACT;
  }
  CGContextRef context = CGBitmapContextCreate(
      gray.data(),
      width,
      height,
      8,
      width,
      color_space,
      kCGImageAlphaNone);
  CGColorSpaceRelease(color_space);
  if (context == nullptr) {
    CGImageRelease(image);
    return AETHER_SFM_ERR_EXTRACT;
  }

  // Keep the JPEG's original pixel grid exactly. The bitmap context writes the
  // decoded CGImage's top row to memory row 0; adding a CTM flip here would
  // invert the source image.
  CGContextSetInterpolationQuality(context, kCGInterpolationNone);
  CGContextDrawImage(
      context,
      CGRectMake(0, 0, static_cast<CGFloat>(width),
                 static_cast<CGFloat>(height)),
      image);
  CGContextRelease(context);
  CGImageRelease(image);

  return pwofficial_add_frame(
      session,
      gray.data(),
      static_cast<int>(width),
      static_cast<int>(height),
      fx,
      fy,
      cx,
      cy,
      pose_qwxyz,
      pose_t,
      out_frame_id);
}
