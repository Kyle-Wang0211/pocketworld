#!/usr/bin/env bash
# run.sh —— 在 Mac 上跑台架 LiDAR 米尺录制写器的 Swift 单测 + 两个小工具。🔴 bench-only ruler。
#
# 形状抄 tool/bench/replay_swift_tests/run.sh:被测源文件就是 ios/Runner/ 里那两份(**逐字节复制**进一个
# 临时 SwiftPM 包,复制后 cmp 自证,不改一个字):
#   ios/Runner/PwBenchReplayRecording.swift        回放装载器 + 共用的 Codable 类型(写与读同一套)
#   ios/Runner/PwBenchLidarRecordingWriter.swift   录制写器(BasaltVIOBench DeviceRecordingWriter @76b8d47 的移植)
# 只依赖 Foundation / CryptoKit / CoreVideo / QuartzCore ⇒ macOS 能编。ARKit 那半(PwBenchLidarSession.swift)
# 只能在台架包里编(见交付报告的构建核对)。
#
# 产物:
#   swift test                                   Tests/LidarWriterTests.swift
#   .build/release/lidar_subset_export <rec> <s>  子集导出器(test_lidar_ruler_synth.py --subset-exporter 用)
#   .build/release/lidar_writer_ab <dir> <秒>      写器 A/B 测量:深度 关 / 开(独立队列)/ 开(共用队列,源的做法)
#
# 用法:tool/bench/lidar_swift_tests/run.sh [scratch_dir] [--ab 秒]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRATCH="${1:-${TMPDIR:-/tmp}/pw_bench_lidar_swift_tests}"
AB_SECONDS=""
if [ "${2:-}" = "--ab" ]; then AB_SECONDS="${3:-3}"; fi
rm -rf "$SCRATCH"
for t in LidarCore lidar_subset_export lidar_writer_ab; do mkdir -p "$SCRATCH/Sources/$t"; done
mkdir -p "$SCRATCH/Tests/LidarCoreTests"
for f in PwBenchReplayRecording.swift PwBenchLidarRecordingWriter.swift; do
  for t in LidarCore lidar_subset_export lidar_writer_ab; do
    cp "$REPO/ios/Runner/$f" "$SCRATCH/Sources/$t/$f"
    cmp -s "$REPO/ios/Runner/$f" "$SCRATCH/Sources/$t/$f" || { echo "🔴 复制后不一致:$f"; exit 1; }
  done
  echo "被测 $f sha256=$(shasum -a 256 "$REPO/ios/Runner/$f" | cut -c1-16)"
done
cp "$HERE/Tools/lidar_subset_export_main.swift" "$SCRATCH/Sources/lidar_subset_export/main.swift"
cp "$HERE/Tools/lidar_writer_ab_main.swift" "$SCRATCH/Sources/lidar_writer_ab/main.swift"
cp "$HERE"/Tests/*.swift "$SCRATCH/Tests/LidarCoreTests/"
cat > "$SCRATCH/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let flags: [SwiftSetting] = [.unsafeFlags(["-swift-version", "5"])]
let package = Package(
    name: "LidarCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "LidarCore", swiftSettings: flags),
        .executableTarget(name: "lidar_subset_export", swiftSettings: flags),
        .executableTarget(name: "lidar_writer_ab", swiftSettings: flags),
        .testTarget(name: "LidarCoreTests", dependencies: ["LidarCore"], swiftSettings: flags),
    ]
)
PKG
cd "$SCRATCH"
# [xr-recon-chain 2026-09-25] ImuSplitRecorderTests 的会话源码契约测试读这份(ARKit 那半编不进 Mac)。
export PW_LIDAR_SESSION_SOURCE="$REPO/ios/Runner/PwBenchLidarSession.swift"
swift test 2>&1 | tail -n 40
swift build -c release --product lidar_subset_export 2>&1 | tail -n 3
swift build -c release --product lidar_writer_ab 2>&1 | tail -n 3
echo "子集导出器:$SCRATCH/.build/release/lidar_subset_export"
if [ -n "$AB_SECONDS" ]; then
  "$SCRATCH/.build/release/lidar_writer_ab" "$SCRATCH/ab_work" "$AB_SECONDS"
fi
