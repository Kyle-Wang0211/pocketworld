#import "GeneratedPluginRegistrant.h"

// aether3d_ffi C ABI for cross-platform depth tile and mask math.
// Implementations live in aether_cpp/src/pipeline/{tile_layout, tile_blend,
// mask_post, aether_depth_tile_c}.cpp, vendored as libaether3d_ffi.a via
// scripts/build_ios_xcframework.sh + pod aether3d_ffi.
#import <aether3d_ffi/aether_depth_tile_c.h>

// [pw][vio] One cross-platform C++ transport wraps the frozen official ABI.
// Swift sees raw transport only; Dart owns configuration and interpretation.
#import "../../vendor/xrslam/transport/PwXrslamTransportCore.h"
