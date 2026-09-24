#!/usr/bin/env bash
# run.sh —— 在 Mac 上跑台架回放装载器 / 节拍器的 Swift 单测。
#
# 被测源文件就是 ios/Runner/ 里那两份(**逐字节复制**进一个临时 SwiftPM 包,
# 复制后 cmp 自证,不改一个字),加上本目录 Tests/ 下的用例:
#   ios/Runner/PwBenchReplayRecording.swift   ← BasaltVIOBench DeviceRecordingLoader/Types 的移植
#   ios/Runner/PwBenchReplayScheduler.swift   ← BasaltVIOBench ReplayScheduler 的逐字照抄
# 这两份只依赖 Foundation + CryptoKit,所以能单独编;PwBenchReplay.swift(要链引擎)
# 由 tool/bench/replay_mac/ 的等价核对覆盖。
#
# 用法:tool/bench/replay_swift_tests/run.sh [scratch_dir]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SCRATCH="${1:-${TMPDIR:-/tmp}/pw_bench_replay_swift_tests}"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/Sources/BenchReplayCore" "$SCRATCH/Tests/BenchReplayCoreTests"
for f in PwBenchReplayRecording.swift PwBenchReplayScheduler.swift; do
  cp "$REPO/ios/Runner/$f" "$SCRATCH/Sources/BenchReplayCore/$f"
  cmp -s "$REPO/ios/Runner/$f" "$SCRATCH/Sources/BenchReplayCore/$f" \
    || { echo "🔴 复制后不一致:$f"; exit 1; }
  echo "被测 $f sha256=$(shasum -a 256 "$REPO/ios/Runner/$f" | cut -c1-16)"
done
cp "$HERE"/Tests/*.swift "$SCRATCH/Tests/BenchReplayCoreTests/"
cat > "$SCRATCH/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "BenchReplayCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "BenchReplayCore",
                swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
        .testTarget(name: "BenchReplayCoreTests", dependencies: ["BenchReplayCore"],
                    swiftSettings: [.unsafeFlags(["-swift-version", "5"])]),
    ]
)
PKG
cd "$SCRATCH"
swift test 2>&1 | tail -n 60
