#!/usr/bin/env bash
# mac_equivalence.sh —— Mac 上核对:台架回放(Dart 编排 + 原生回放,同源文件编的 macOS 库)
# 与既有的 Mac 宿主回放(xrslam fork pw_tools/regression/euroc_runner.cpp,
# ~/Developer/xrslam-4beb1a9-thr/build-pc-pfk/pw_euroc_runner)对**同一份录制、同一组开关**
# 是否给出同一条轨迹。
#
# 用法:tool/bench/replay_mac/mac_equivalence.sh <录制目录> <前 N 帧> <工作目录>
#
# 两边吃的东西怎么对齐(每一条都有出处):
#   · 帧:我们直接读 frames.bin;runner 读 arloopbench tools/pwvi_to_euroc.py 转出的无损 PNG
#     (compress_level=1,像素逐字节相同)。两边都是前 N 行相机索引(--limit N / -PWBenchReplayLimitFrames N)。
#   · 开头没 IMU 的帧:我们按 BasaltVIOBench DeviceRecordingLoader.swift:312-332 丢掉;
#     runner 的 EuRoC reader 不丢 ⇒ 这里把转出来的 cam0/data.csv 里 t < 第一条 IMU 的行删掉,
#     让两边吃同一组帧(删了几行打印出来,应与我们回执里的 leading_camera_frames_without_imu_dropped 相同)。
#   · 时间戳:本核对关掉曝光中点(-PWBenchReplayIgnoreExposure on,转换器不加 --exposure-half)、
#     c = 0(-PWBenchReplayCameraTimeOffsetMs 0,yaml time_offset 生成器默认 0.0)⇒ 两边相机时间都是
#     t_ns·1e-9 + 0,IMU 都是 t_ns·1e-9,逐位相同。开曝光 / c ≠ 0 时两边的舍入次序不同
#     (转换器先把 exposure/2 四舍五入到整纳秒),不是逐位相同 —— 那一档不在本核对范围。
#   · yaml:runner 吃的就是我们这一场写出来的 slam_config.yaml / device_config.yaml(同一个文件)。
#   · 逐帧 K(on 臂):转换器 --intrinsics-csv 与我们的装载器用同一条配对规则(pwvi_to_euroc.py:130-157)。
#   · 位姿口径:比 poses_body.tum(我们在同一时刻读 XRSLAM_RESULT_BODY_POSE,runner 也读它,
#     同一个闸、同一个打印格式,euroc_runner.cpp:205-213,248-254)。
# 判据:两份 TUM 逐字节相同(cmp)。不同就打印第一处不同与最大差。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
REC="$(cd "${1:?录制目录}" && pwd)"; N="${2:?前 N 帧}"; WORK="${3:?工作目录}"
RUNNER="${PW_EUROC_RUNNER:-$HOME/Developer/xrslam-4beb1a9-thr/build-pc-pfk/pw_euroc_runner}"
CONVERTER="${PWVI_TO_EUROC:-$HOME/Developer/arloopbench/tools/pwvi_to_euroc.py}"
PY=/usr/bin/python3   # 只有它有 numpy + Pillow(转换器要)
RUN="$(basename "$REC")"; TOKEN="${RUN#run-}"; TOKEN="${TOKEN:0:8}"
mkdir -p "$WORK"
echo "== 1. 编 Mac 库 =="
"$HERE/build_mac_harness.sh" "$WORK/harness" | tail -3
echo "== 2. 录制目录挂进假的 Documents =="
mkdir -p "$WORK/docs/replay_recordings"
ln -sfn "$REC" "$WORK/docs/replay_recordings/$RUN"
echo "== 3. 转 EuRoC(前 $N 帧,无曝光平移)+ 逐帧 K CSV =="
echo "   转换器 $CONVERTER sha256=$(shasum -a 256 "$CONVERTER" | cut -c1-16)"
rm -rf "$WORK/euroc"
"$PY" "$CONVERTER" "$REC" "$WORK/euroc" --limit "$N" --intrinsics-csv "$WORK/k.csv" | tail -4
"$PY" - "$WORK/euroc" <<'PY'
import os, sys
d = sys.argv[1]
imu_t0 = None
for ln in open(os.path.join(d, 'imu0', 'data.csv'), newline=''):
    if ln.startswith('#'): continue
    imu_t0 = int(ln.split(',')[0]); break
p = os.path.join(d, 'cam0', 'data.csv')
rows = open(p, newline='').read().split('\r\n')
head, body = rows[0], [r for r in rows[1:] if r]
keep = [r for r in body if int(r.split(',')[0]) >= imu_t0]
open(p, 'w', newline='').write('\r\n'.join([head] + keep) + '\r\n')
print(f'   开头没 IMU 的帧:删 {len(body) - len(keep)} 行(剩 {len(keep)})')
PY
for ARM in off on; do
  echo "== 4.$ARM 台架回放(Dart + 原生),-PWPerFrameIntrinsics $ARM =="
  rm -f "$WORK/result_$ARM.txt"
  ( cd "$REPO" && \
    PW_BENCH_REPLAY_MAC_DYLIB="$WORK/harness/libpw_bench_replay_mac.dylib" \
    PW_BENCH_REPLAY_DOCS="$WORK/docs" PW_BENCH_REPLAY_RECORDING="$TOKEN" \
    PW_BENCH_REPLAY_PFK="$ARM" PW_BENCH_REPLAY_LIMIT="$N" PW_BENCH_REPLAY_PACE=max \
    PW_BENCH_REPLAY_IGNORE_EXPOSURE=on PW_BENCH_REPLAY_C_MS=0 PW_BENCH_REPLAY_TAG="mac-$ARM" \
    PW_BENCH_REPLAY_RESULT="$WORK/result_$ARM.txt" \
    flutter test test/vio/replay/bench_replay_mac_equivalence_test.dart 2>&1 \
      | grep -E "^[0-9]+:[0-9]+ \+|All tests|Some tests|Expected|Actual|reason" | tail -4 )
  RUN_DIR="$(cat "$WORK/result_$ARM.txt")"
  echo "   输出 $RUN_DIR"
  "$REPO/tool/bench/pull_bench_replay_run.sh" --check "$RUN_DIR" | sed 's/^/   /'
  echo "== 5.$ARM Mac 宿主回放 pw_euroc_runner(同一对 yaml)=="
  KARGS=(); [ "$ARM" = on ] && KARGS=(--intrinsics-csv "$WORK/k.csv")
  set +e
  "$RUNNER" "$RUN_DIR/slam_config.yaml" "$RUN_DIR/device_config.yaml" "euroc://$WORK/euroc" \
    "$WORK/runner_$ARM.tum" "${KARGS[@]+"${KARGS[@]}"}" > "$WORK/runner_$ARM.log" 2>&1
  rc=$?
  set -e
  # 04c0e83 的 runner 在 main 返回之后二次释放、退出码 139(输出已写完;fork
  # feat/solver-time-budget euroc_runner.cpp 的注释记着这件事),所以 0 与 139 都认,只要 TUM 非空。
  [ "$rc" = 0 ] || [ "$rc" = 139 ] || { echo "🔴 runner rc=$rc"; tail -20 "$WORK/runner_$ARM.log"; exit 1; }
  [ -s "$WORK/runner_$ARM.tum" ] || { echo "🔴 runner 没写出轨迹"; exit 1; }
  grep -E "images|poses|K matched|GetInfoIntrinsics" "$WORK/runner_$ARM.log" | sed 's/^/   /'
  echo "== 6.$ARM 逐字节比 poses_body.tum =="
  if cmp -s "$RUN_DIR/poses_body.tum" "$WORK/runner_$ARM.tum"; then
    echo "   ✅ 逐字节相同:$(wc -l < "$RUN_DIR/poses_body.tum" | tr -d ' ') 行 sha256=$(shasum -a 256 "$RUN_DIR/poses_body.tum" | cut -c1-16)"
  else
    echo "   🔴 不同"
    "$PY" - "$RUN_DIR/poses_body.tum" "$WORK/runner_$ARM.tum" <<'PY'
import sys
a = [l.split() for l in open(sys.argv[1])]; b = [l.split() for l in open(sys.argv[2])]
print(f'   行数 ours={len(a)} runner={len(b)}')
for i, (x, y) in enumerate(zip(a, b)):
    if x != y:
        print(f'   第一处不同:第 {i} 行\n     ours   {" ".join(x)}\n     runner {" ".join(y)}'); break
m = max((abs(float(p) - float(q)) for x, y in zip(a, b) for p, q in zip(x[1:4], y[1:4])), default=0)
print(f'   同行位置最大差 {m:.3e} m')
PY
  fi
  if [ "$ARM" = on ]; then
    echo "== 7. 逐帧 K:我们推下去的 == 转换器 CSV(按 t_ns)=="
    "$PY" - "$RUN_DIR/intrinsics_ledger.csv" "$WORK/k.csv" <<'PY'
import csv, sys
k = {}
for ln in open(sys.argv[2]):
    if ln.startswith('#'): continue
    t, *v = ln.strip().split(',')
    k[int(t)] = [float(x) for x in v]
same = diff = unattached = 0
for r in csv.DictReader(open(sys.argv[1])):
    if r['attached'] != '1': unattached += 1; continue
    got = [float(r[f'attached_{c}']) for c in ('fx', 'fy', 'cx', 'cy')]
    if k.get(int(r['t_ns'])) == got: same += 1
    else: diff += 1
print(f'   推了逐帧 K 的帧 {same + diff}:与转换器逐位相同 {same},不同 {diff};没推 {unattached}')
PY
  fi
done
