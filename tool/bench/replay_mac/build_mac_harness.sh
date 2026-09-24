#!/usr/bin/env bash
# build_mac_harness.sh —— 把台架回放的**同一批源文件**编成一个 macOS 动态库,
# 让 Mac 上的 flutter test 能用 DynamicLibrary.open() 驱动「Dart 编排 + 原生回放」整条路,
# 与 Mac 宿主回放(xrslam fork pw_tools/regression/euroc_runner.cpp)逐行比轨迹。
#
# 编进去的(全部逐字节是台架镜像里那几份):
#   ios/Runner/PwXrslamLive.swift          ON 臂喂料通路(回放入口在这里)
#   ios/Runner/PwBenchReplay.swift         回放器 + pw_bench_replay_* C ABI
#   ios/Runner/PwBenchReplayRecording.swift / PwBenchReplayScheduler.swift
#   ios/Runner/PwBenchReplayEngineProbe.c  只读 BODY_POSE + 遥测
#   vendor/xrslam/transport/PwXrslamTransportCore.cpp
# Mac 专有、不进任何 App 的只有三样(本目录):
#   CoreMotion/ + CoreMotionStub.m        遮住 macOS 上 API_UNAVAILABLE(macos) 的 CMMotionManager,
#                                         让 PwXrslamLive.swift 原封不动编过(回放从不调它)
#   PwBenchReplayMacShim.swift            把启动参数写进 NSArgumentDomain(flutter_tester 的 argv 管不了)
#   bridging.h                            = 台架桥接头里与回放相关的两行
# 链的引擎:$XRSLAM_MAC_LIB_DIR/libxrslam.dylib,默认 ~/Developer/xrslam-4beb1a9-thr/lib ——
#   fork 04c0e83(逐帧内参)用 pw_tools/regression/build_pc_headless.sh 编的 Mac 版,
#   pw_euroc_runner(build-pc-pfk/)链的就是它。
#
# 用法:tool/bench/replay_mac/build_mac_harness.sh <out_dir>   ⇒ <out_dir>/libpw_bench_replay_mac.dylib
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${1:?out dir}"
LIBDIR="${XRSLAM_MAC_LIB_DIR:-$HOME/Developer/xrslam-4beb1a9-thr/lib}"
[ -f "$LIBDIR/libxrslam.dylib" ] || { echo "🔴 没有 $LIBDIR/libxrslam.dylib" >&2; exit 1; }
mkdir -p "$OUT/obj"
INC="-I$REPO/vendor/xrslam/include"
xcrun clang -c -O2 -fobjc-arc -I"$HERE" "$HERE/CoreMotionStub.m" -o "$OUT/obj/CoreMotionStub.o"
xcrun clang++ -c -O2 -std=c++17 -ffp-contract=off $INC \
  "$REPO/vendor/xrslam/transport/PwXrslamTransportCore.cpp" -o "$OUT/obj/PwXrslamTransportCore.o"
xcrun clang -c -O2 $INC "$REPO/ios/Runner/PwBenchReplayEngineProbe.c" -o "$OUT/obj/PwBenchReplayEngineProbe.o"
xcrun swiftc -emit-library -O -swift-version 5 -module-name PwBenchReplayMac \
  -I "$HERE" -import-objc-header "$HERE/bridging.h" -Xcc "$INC" \
  "$REPO/ios/Runner/PwXrslamLive.swift" \
  "$REPO/ios/Runner/PwBenchReplay.swift" \
  "$REPO/ios/Runner/PwBenchReplayRecording.swift" \
  "$REPO/ios/Runner/PwBenchReplayScheduler.swift" \
  "$HERE/PwBenchReplayMacShim.swift" \
  "$OUT/obj/CoreMotionStub.o" "$OUT/obj/PwXrslamTransportCore.o" "$OUT/obj/PwBenchReplayEngineProbe.o" \
  -L "$LIBDIR" -lxrslam -lc++ -Xlinker -rpath -Xlinker "$LIBDIR" \
  -o "$OUT/libpw_bench_replay_mac.dylib"
for s in pw_bench_replay_start pw_bench_replay_status pw_bench_replay_inspect \
         pw_bench_replay_launch_args pw_bench_replay_cancel pw_bench_replay_mac_set_argument; do
  nm -gU "$OUT/libpw_bench_replay_mac.dylib" | grep -q " _$s\$" || { echo "🔴 缺导出符号 $s" >&2; exit 1; }
done
echo "BUILD_OK $OUT/libpw_bench_replay_mac.dylib"
shasum -a 256 "$LIBDIR/libxrslam.dylib" "$OUT/libpw_bench_replay_mac.dylib"
