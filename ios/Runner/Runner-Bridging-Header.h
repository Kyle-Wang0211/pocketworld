#import "GeneratedPluginRegistrant.h"

// aether3d_ffi C ABI for cross-platform depth tile and mask math.
// Implementations live in aether_cpp/src/pipeline/{tile_layout, tile_blend,
// mask_post, aether_depth_tile_c}.cpp, vendored as libaether3d_ffi.a via
// scripts/build_ios_xcframework.sh + pod aether3d_ffi.
#import <aether3d_ffi/aether_depth_tile_c.h>

// [pw][vio] One cross-platform C++ transport wraps the frozen official ABI.
// Swift sees raw transport only; Dart owns configuration and interpretation.
#import "../../vendor/xrslam/transport/PwXrslamTransportCore.h"

// [pw][lod] 2026-09-24 build 171: the GPU point-cloud viewer (one viewer for every stage of the
// capture page). PwLodSurface.h includes the frozen C ABI vendor/aether_lod/include/pwlod_viewer.h
// (v3) so Swift sees pwlod_camera / pwlod_style / pwlod_frame_stats with the engine's layout.
// The engine archive libpw_lod_72ee817f.a is -force_load'ed by the Runner target and binds its
// wgpu* to the Dawn already inside libaether3d_ffi.a (no second Dawn).
#import "PwLodSurface.h"
