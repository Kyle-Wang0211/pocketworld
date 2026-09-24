#import "GeneratedPluginRegistrant.h"

// [pw][vio] 跨端 C++ 传输层。iOS 与安卓编的是**同一个源文件**
// (安卓:android_ready/native/xrslam/CMakeLists.txt)。Swift 只看到裸传输;
// 配置与解释归 Dart。
#import "../../vendor/xrslam/transport/PwXrslamTransportCore.h"

// [pw][af] 跨端 CDAF 的 C ABI 门面(对焦三臂用)。真源在 pocketworld
// vendor/pw_af/,由 sync_from_production.sh 镜像并自证逐字节一致。
#import "../../vendor/pw_af/pw_af_c.h"

// [pw][bench-replay 2026-09-23] 台架回放的两个只读引擎读数(BODY_POSE 与求解遥测)。
// 真源在 pocketworld ios/Runner/PwBenchReplayEngineProbe.{h,c},由同步脚本镜像并自证
// 逐字节一致。生产桥接头不 import 它。
#import "PwBenchReplayEngineProbe.h"

// [pw][lod 2026-09-24] LOD 点云查看器 iOS 外壳的 C 半边(IOSurface → Dawn SharedTextureMemory)。
// 它再 include 两份冻结头 vendor/aether_lod/include/{pw_lod_bench.h, pwlod_viewer.h},
// Swift(PwLodTexture / PwLodTexturePlugin / PwLodProbe)经此按编译器排布使用 pwlod_* 结构体。
// 真源在 pocketworld feat/lod-viewer ios/Runner/PwLodSurface.{h,m},由同步脚本 LOD 段镜像并自证
// 逐字节一致。生产桥接头不 import 它。<webgpu/webgpu.h> 走 HEADER_SEARCH_PATHS 里的
// $(PROJECT_DIR)/../vendor/aether_lod/include。
#import "PwLodSurface.h"

// [pw][full-chain 2026-09-24] 完整重建链 168:照抄生产 ios/Runner/Runner-Bridging-Header.h:3-7 那一行。
// aether3d_ffi pod(静态 + use_modular_headers!)的公开头;生产的 Swift 并不调用它的函数
// (MetalRenderer.swift 自己声明私有桩),留着只为与生产的桥接头逐项对齐。生产桥接头里的另一行
// PwXrslamTransportCore.h 台架上面已有(传输层用 vendor/xrslam = bench-replay 那份,见适配清单)。
#import <aether3d_ffi/aether_depth_tile_c.h>

// [pw][unified 2026-09-24] 泼溅 A/B(原 PWSplatAB)的三个 C 入口:pwsplat_ab_run / pwpoints_run / pwcloud_run。
// 真源 pocketworld bench/unified ios/Runner/PwSplatAB/(pw_splat_ab_bench Sources/@b792d57 原样),同步脚本 U 段镜像。
// pwlod_run 已由上面 PwLodSurface.h 引入的 vendor/aether_lod/include/pw_lod_bench.h 声明。
#import "PwSplatAB/pw_splat_ab.h"
