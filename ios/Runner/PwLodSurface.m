// PwLodSurface.m — see PwLodSurface.h. Plain C against the IOSurface / CoreVideo / Dawn C
// APIs (ObjC only for the property-dictionary literal).
//
// Copied, not invented:
//   * IOSurface + CVPixelBuffer creation: ios/Runner/MetalRenderer.swift:165-186 @875fe67
//     (the production Flutter-texture renderer): 32BGRA, 4 bytes per element,
//     CVPixelBufferCreateWithIOSurface with no extra attributes.
//     product_adapter: bytesPerRow goes through IOSurfaceAlignProperty (iPhoneOS26.2 SDK
//     IOSurface/IOSurfaceRef.h:388-391, "automatically align property values") instead of the
//     raw width*4 — our width is the screen's physical width, not a fixed 256.
//   * IOSurface -> WGPUSharedTextureMemory -> WGPUTexture: Aether3D
//     aether_cpp/src/render/dawn_gpu_device.cpp:917-983 @849c4d6b01 (import_iosurface, the
//     ffi's source revision): IOSurface descriptor chained on the memory descriptor,
//     allowStorageBinding = false, GetProperties, size + format checks, texture descriptor from
//     the properties (usage = props.usage, 2D, 1 mip, 1 sample).
//     Added check (contract, pwlod_viewer.h:118): usage must include RenderAttachment|CopySrc.
#import "PwLodSurface.h"

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>

#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

struct PwLodSurfaceRing {
  uint32_t width;
  uint32_t height;
  IOSurfaceRef surfaces[PWLOD_TARGET_COUNT];
  CVPixelBufferRef pixel_buffers[PWLOD_TARGET_COUNT];
  pwlod_target targets[PWLOD_TARGET_COUNT];
};

static void PwLodSurfaceError(char *buf, uint32_t len, const char *fmt, ...) {
  if (buf == NULL || len == 0) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, len, fmt, ap);
  va_end(ap);
}

pwlod_status PwLodSurfaceCreateGpu(pwlod_gpu *out_gpu) {
  // dawn_gpu_device.cpp:474-478 @849c4d6b01 minus Subgroups (the LOD engine does not ask for it).
  const WGPUFeatureName features[2] = {
      WGPUFeatureName_SharedTextureMemoryIOSurface,
      WGPUFeatureName_SharedFenceMTLSharedEvent,
  };
  return pwlod_gpu_create(features, 2, out_gpu);
}

WGPUTextureFormat PwLodSurfaceRingFormat(void) {
  // kCVPixelFormatType_32BGRA <-> BGRA8Unorm
  // (dawn @12ee391c src/dawn/native/metal/SharedTextureMemoryMTL.mm:55-56).
  return WGPUTextureFormat_BGRA8Unorm;
}

const pwlod_target *PwLodSurfaceRingTargets(const PwLodSurfaceRing *ring) {
  return ring != NULL ? ring->targets : NULL;
}

CVPixelBufferRef PwLodSurfaceRingPixelBuffer(const PwLodSurfaceRing *ring, uint32_t index) {
  if (ring == NULL || index >= PWLOD_TARGET_COUNT) return NULL;
  return ring->pixel_buffers[index];
}

void PwLodSurfaceRingDestroy(PwLodSurfaceRing *ring) {
  if (ring == NULL) return;
  for (uint32_t i = 0; i < PWLOD_TARGET_COUNT; ++i) {
    if (ring->targets[i].texture != NULL) wgpuTextureRelease(ring->targets[i].texture);
    if (ring->targets[i].memory != NULL) wgpuSharedTextureMemoryRelease(ring->targets[i].memory);
    if (ring->pixel_buffers[i] != NULL) CVPixelBufferRelease(ring->pixel_buffers[i]);
    if (ring->surfaces[i] != NULL) CFRelease(ring->surfaces[i]);
  }
  free(ring);
}

// dawn_gpu_device.cpp:901-983 @849c4d6b01 (import_iosurface), one slot.
static int PwLodSurfaceImport(WGPUDevice device,
                              IOSurfaceRef surface,
                              uint32_t width,
                              uint32_t height,
                              pwlod_target *out,
                              char *err,
                              uint32_t err_len) {
  WGPUSharedTextureMemoryIOSurfaceDescriptor io_desc =
      WGPU_SHARED_TEXTURE_MEMORY_IO_SURFACE_DESCRIPTOR_INIT;
  io_desc.ioSurface = (void *)surface;
  // allowStorageBinding=false: render attachment + copy source, never a compute storage write.
  io_desc.allowStorageBinding = WGPU_FALSE;

  WGPUSharedTextureMemoryDescriptor mem_desc = WGPU_SHARED_TEXTURE_MEMORY_DESCRIPTOR_INIT;
  mem_desc.nextInChain = &io_desc.chain;

  WGPUSharedTextureMemory mem = wgpuDeviceImportSharedTextureMemory(device, &mem_desc);
  if (mem == NULL) {
    PwLodSurfaceError(err, err_len,
                      "ImportSharedTextureMemory NULL (feature not granted / IOSurface format?)");
    return 0;
  }

  WGPUSharedTextureMemoryProperties props = WGPU_SHARED_TEXTURE_MEMORY_PROPERTIES_INIT;
  const WGPUStatus props_status = wgpuSharedTextureMemoryGetProperties(mem, &props);
  if (props_status != WGPUStatus_Success) {
    PwLodSurfaceError(err, err_len, "SharedTextureMemoryGetProperties status=%d",
                      (int)props_status);
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }
  // Dawn hands back an *error object*, not NULL, when the import is rejected (feature not
  // granted, IOSurface refused); its properties read back as 0x0. Host run against real Dawn
  // (Metal) with SharedTextureMemoryIOSurface withheld: exactly this. Name it instead of
  // reporting a size mismatch.
  if (props.size.width == 0 || props.size.height == 0) {
    PwLodSurfaceError(err, err_len,
                      "ImportSharedTextureMemory returned an error object (0x0): feature not "
                      "granted or IOSurface rejected -- see Dawn's uncaptured-error log");
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }
  if (props.size.width != width || props.size.height != height) {
    PwLodSurfaceError(err, err_len, "size mismatch sharedMemory=(%u,%u) requested=(%u,%u)",
                      props.size.width, props.size.height, width, height);
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }
  if (props.format != PwLodSurfaceRingFormat()) {
    PwLodSurfaceError(err, err_len, "format mismatch sharedMemory=%d requested=%d",
                      (int)props.format, (int)PwLodSurfaceRingFormat());
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }
  const WGPUTextureUsage needed = WGPUTextureUsage_RenderAttachment | WGPUTextureUsage_CopySrc;
  if ((props.usage & needed) != needed) {
    PwLodSurfaceError(err, err_len, "usage 0x%llx lacks RenderAttachment|CopySrc",
                      (unsigned long long)props.usage);
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }

  WGPUTextureDescriptor texture_desc = WGPU_TEXTURE_DESCRIPTOR_INIT;
  texture_desc.usage = props.usage;
  texture_desc.dimension = WGPUTextureDimension_2D;
  texture_desc.size = props.size;
  texture_desc.format = props.format;
  texture_desc.mipLevelCount = 1;
  texture_desc.sampleCount = 1;

  WGPUTexture texture = wgpuSharedTextureMemoryCreateTexture(mem, &texture_desc);
  if (texture == NULL) {
    PwLodSurfaceError(err, err_len, "SharedTextureMemoryCreateTexture NULL");
    wgpuSharedTextureMemoryRelease(mem);
    return 0;
  }
  out->texture = texture;
  out->memory = mem;
  return 1;
}

PwLodSurfaceRing *PwLodSurfaceRingCreate(WGPUDevice device,
                                         uint32_t width,
                                         uint32_t height,
                                         char *err_buf,
                                         uint32_t err_buf_len) {
  if (device == NULL || width == 0 || height == 0) {
    PwLodSurfaceError(err_buf, err_buf_len, "invalid args device=%p %ux%u", (void *)device,
                      width, height);
    return NULL;
  }
  PwLodSurfaceRing *ring = (PwLodSurfaceRing *)calloc(1, sizeof(PwLodSurfaceRing));
  if (ring == NULL) {
    PwLodSurfaceError(err_buf, err_buf_len, "calloc failed");
    return NULL;
  }
  ring->width = width;
  ring->height = height;

  const size_t bytes_per_row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, (size_t)width * 4);
  // MetalRenderer.swift:165-171 @875fe67 property set.
  NSDictionary *props = @{
    (__bridge NSString *)kIOSurfaceWidth : @(width),
    (__bridge NSString *)kIOSurfaceHeight : @(height),
    (__bridge NSString *)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
    (__bridge NSString *)kIOSurfaceBytesPerElement : @4,
    (__bridge NSString *)kIOSurfaceBytesPerRow : @(bytes_per_row),
  };

  for (uint32_t i = 0; i < PWLOD_TARGET_COUNT; ++i) {
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (surface == NULL) {
      PwLodSurfaceError(err_buf, err_buf_len, "IOSurfaceCreate NULL (slot %u, %ux%u)", i, width,
                        height);
      PwLodSurfaceRingDestroy(ring);
      return NULL;
    }
    ring->surfaces[i] = surface;

    CVPixelBufferRef pb = NULL;
    const CVReturn cv =
        CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pb);
    if (cv != kCVReturnSuccess || pb == NULL) {
      PwLodSurfaceError(err_buf, err_buf_len, "CVPixelBufferCreateWithIOSurface CVReturn=%d",
                        (int)cv);
      PwLodSurfaceRingDestroy(ring);
      return NULL;
    }
    ring->pixel_buffers[i] = pb;

    char slot_err[160] = {0};
    if (!PwLodSurfaceImport(device, surface, width, height, &ring->targets[i], slot_err,
                            sizeof slot_err)) {
      PwLodSurfaceError(err_buf, err_buf_len, "slot %u: %s", i, slot_err);
      PwLodSurfaceRingDestroy(ring);
      return NULL;
    }
  }
  return ring;
}
