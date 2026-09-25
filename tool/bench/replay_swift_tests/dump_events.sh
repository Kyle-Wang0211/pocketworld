#!/usr/bin/env bash
# dump_events.sh <PwBenchReplayRecording.swift 源> <scratch_dir> [--split] <录制目录...>
# [xr-recon-chain 2026-09-25] 用给定那一版装载器源码编 replay_events_dump(Tools/replay_events_dump_main.swift),
# 对每份录制打印推送序列的 sha256。改前 / 改后两版各跑一次,sha 相同 = 喂进引擎的东西逐位不变。
# --split:被测源是新装载器(有 .gyro / .accel,编译时定义 PW_SPLIT_IMU)。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$1"; SCRATCH="$2"; shift 2
DEF=""; if [ "${1:-}" = "--split" ]; then DEF="-D PW_SPLIT_IMU"; shift; fi
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
cp "$SRC" "$SCRATCH/PwBenchReplayRecording.swift"; cmp -s "$SRC" "$SCRATCH/PwBenchReplayRecording.swift"
cp "$HERE/Tools/replay_events_dump_main.swift" "$SCRATCH/main.swift"
echo "被测装载器 sha256=$(shasum -a 256 "$SRC" | cut -c1-16) ${DEF:+(PW_SPLIT_IMU)}"
xcrun swiftc -O -swift-version 5 $DEF "$SCRATCH/PwBenchReplayRecording.swift" "$SCRATCH/main.swift" -o "$SCRATCH/replay_events_dump"
"$SCRATCH/replay_events_dump" "$@"
