#import "GeneratedPluginRegistrant.h"

// aether3d_ffi C ABI for cross-platform depth tile and mask math.
// Implementations live in aether_cpp/src/pipeline/{tile_layout, tile_blend,
// mask_post, aether_depth_tile_c}.cpp, vendored as libaether3d_ffi.a via
// scripts/build_ios_xcframework.sh + pod aether3d_ffi.
#import <aether3d_ffi/aether_depth_tile_c.h>

// [pw][vio] One cross-platform C++ transport wraps the frozen official ABI.
// Swift sees raw transport only; Dart owns configuration and interpretation.
#import "../../vendor/xrslam/transport/PwXrslamTransportCore.h"

// [pw][af] 跨端 CDAF 的 C ABI 门面。算法在 vendor/pw_af/{af_scan,focus_measure,
// lens_scale}.cpp —— libcamera 树莓派 IPA(BSD-2)的复刻 + Pertuz/Mir 评测里的
// 梯度能量度量。Swift 只看到不透明指针与扁平结构体,C++ 类型一个都不暴露。
#import "../../vendor/pw_af/pw_af_c.h"
