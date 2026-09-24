// PwLodSurface.h — iOS shell half of the LOD point-cloud viewer that has to speak Dawn's C
// structs (chained descriptors are safer in C than in Swift). Everything else in the shell is
// Swift (PwLodTexture.swift / PwLodTexturePlugin.swift / PwLodProbe.swift).
//
// Scope: bench (arloopbench, com.kyle.arloopbench) and the feat/lod-viewer branch only; never
// production. The production Runner.xcodeproj does not compile this file and the production
// bridging header does not import it.
//
// Swift sees the engine through this header: it includes the two frozen C headers
// (vendor/aether_lod/include/, byte-identical to the coordinator's contract; see SHA256SUMS
// there), so the Clang importer lays out pwlod_camera / pwlod_params / pwlod_frame_stats /
// PwLodProbeSample exactly as the engine was compiled against. Same route as the product's
// own C ABI facade vendor/pw_af/pw_af_c.h (imported by Runner-Bridging-Header.h). No
// DynamicLibrary.process() lookups: the calls are linked statically.
//
// Platform types live only here and in ios/Runner/PwLod*.swift (IOSurface, CVPixelBuffer).
// The engine ABI (pwlod_viewer.h) has none — it only ever sees WGPUTexture +
// WGPUSharedTextureMemory.
#ifndef PW_LOD_SURFACE_H_
#define PW_LOD_SURFACE_H_

#include <CoreVideo/CoreVideo.h>
#include <stdint.h>

#include "../../vendor/aether_lod/include/pw_lod_bench.h"
#include "../../vendor/aether_lod/include/pwlod_viewer.h"

#ifdef __cplusplus
extern "C" {
#endif

/// pwlod_gpu_create with the two device features the IOSurface bridge needs:
///   WGPUFeatureName_SharedTextureMemoryIOSurface  import an IOSurface as a WGPUTexture;
///   WGPUFeatureName_SharedFenceMTLSharedEvent     Dawn's Metal backend fails every
///       wgpuSharedTextureMemoryEndAccess without it
///       (dawn @12ee391c src/dawn/native/metal/SharedTextureMemoryMTL.mm:228-230; BeginAccess
///       only checks it when fences are passed, :210-214), and the engine brackets every use
///       of a target with BeginAccess / EndAccess (pwlod_viewer.h:116-118).
/// Same pair the production renderer requests (Aether3D aether_cpp/src/render/
/// dawn_gpu_device.cpp:474-478 @849c4d6b01, the ffi's source revision).
pwlod_status PwLodSurfaceCreateGpu(pwlod_gpu *out_gpu);

typedef struct PwLodSurfaceRing PwLodSurfaceRing; /* opaque */

/// PWLOD_TARGET_COUNT render targets of width x height: each is an IOSurface (BGRA8), the
/// CVPixelBuffer Flutter reads, and the WGPUSharedTextureMemory + WGPUTexture the engine writes.
/// NULL on failure with a reason in err_buf (may be NULL).
PwLodSurfaceRing *PwLodSurfaceRingCreate(WGPUDevice device,
                                         uint32_t width,
                                         uint32_t height,
                                         char *err_buf,
                                         uint32_t err_buf_len);

/// PWLOD_TARGET_COUNT entries, valid until PwLodSurfaceRingDestroy; pass straight to
/// pwlod_viewer_set_targets.
const pwlod_target *PwLodSurfaceRingTargets(const PwLodSurfaceRing *ring);

/// The format every ring texture has (what pwlod_viewer_set_targets must be told).
WGPUTextureFormat PwLodSurfaceRingFormat(void);

/// +0; retain it (Swift: stored in an array) for as long as it is handed to Flutter.
CVPixelBufferRef PwLodSurfaceRingPixelBuffer(const PwLodSurfaceRing *ring, uint32_t index)
    CF_RETURNS_NOT_RETAINED;

/// Only after the viewer using the ring is destroyed (the engine may still write a target
/// until pwlod_viewer_stop returns). NULL is a no-op.
void PwLodSurfaceRingDestroy(PwLodSurfaceRing *ring);

#ifdef __cplusplus
}
#endif

#endif  // PW_LOD_SURFACE_H_
