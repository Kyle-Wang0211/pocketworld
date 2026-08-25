#import "GeneratedPluginRegistrant.h"

// aether3d_ffi C ABI for cross-platform depth tile and mask math.
// Implementations live in aether_cpp/src/pipeline/{tile_layout, tile_blend,
// mask_post, aether_depth_tile_c}.cpp, vendored as libaether3d_ffi.a via
// scripts/build_ios_xcframework.sh + pod aether3d_ffi.
#import <aether3d_ffi/aether_depth_tile_c.h>

// [pw][vio] XRSLAM (RD-VIO) C ABI。
// 为什么在原生侧喂帧而不是 Dart 侧:ARFrame 本来就在原生,从 Dart 喂意味着
// 每帧把像素缓冲跨 FFI 边界拷一次(1920x1440 灰度 = 2.7MB/帧 @30fps = 83MB/s)。
// 原生侧直接喂是零拷贝。Dart 侧只读位姿和健康状态 —— 那是几十字节。
#import <xrslam/XRSLAM.h>
