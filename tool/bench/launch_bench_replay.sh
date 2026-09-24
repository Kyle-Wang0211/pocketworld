#!/usr/bin/env bash
# launch_bench_replay.sh —— 用启动参数让台架(com.kyle.arloopbench)直接进回放页并自动开跑。
# 不用点屏幕;一场跑完页面停在结果上,回执落在 Documents/bench_replay_runs/<run>/receipt.json。
#
# 用法:
#   tool/bench/launch_bench_replay.sh <录制(目录名或 id 前缀)> <on|off> [节拍] [更多 -PW… 参数]
#     on|off = -PWPerFrameIntrinsics(逐帧内参开关,进程级 ⇒ 每换一次臂重启一次 App)
#     节拍   = paced(默认)| max | paced-live-drop
#   例:
#     tool/bench/launch_bench_replay.sh 6e2d4b99 off
#     tool/bench/launch_bench_replay.sh 6e2d4b99 on  paced
#     tool/bench/launch_bench_replay.sh 4ad6e500 on  paced -PWBenchReplayAllowLossy on
#     tool/bench/launch_bench_replay.sh 6e2d4b99 on  paced -PWYamlOverride solver.frame_time_budget=0.02
#   只打印不执行:PW_BENCH_DRY_RUN=1
#
# 启动命令的形状抄 BasaltVIOBench scripts/pw_run_arm.sh
# (`devicectl device process launch --device … --terminate-existing <bundle> -- -PW… …`)。
# 全部回放参数见 ios/Runner/PwBenchReplay.swift 的 PwBenchReplayLaunch。
#
# 🔴 只启动台架 com.kyle.arloopbench。生产 com.kyle.PocketWorld 不碰。
# 🔴 2026-09-23 只写了、`bash -n` 过,没在真机上跑过。
set -euo pipefail
UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
[ $# -ge 2 ] || { sed -n '2,20p' "$0"; exit 2; }
REC="$1"; ARM="$2"; shift 2
PACE="paced"
if [ $# -ge 1 ] && [ "${1#-}" = "$1" ]; then PACE="$1"; shift; fi
case "$ARM" in on|off) ;; *) echo "🔴 第二个参数要 on 或 off:$ARM" >&2; exit 2 ;; esac
case "$PACE" in paced|max|paced-live-drop) ;; *) echo "🔴 节拍不认识:$PACE" >&2; exit 2 ;; esac
CMD=(xcrun devicectl device process launch --device "$UDID" --terminate-existing
     com.kyle.arloopbench --
     -PWBenchReplayRecording "$REC" -PWPerFrameIntrinsics "$ARM" -PWBenchReplayPace "$PACE" "$@")
printf ' %q' "${CMD[@]}"; echo
[ "${PW_BENCH_DRY_RUN:-0}" = 1 ] && { echo "(dry run)"; exit 0; }
"${CMD[@]}"
echo "跑完后:tool/bench/pull_bench_replay_run.sh   # 列出 / 拉回 Documents/bench_replay_runs/"
