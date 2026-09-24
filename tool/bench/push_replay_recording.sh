#!/usr/bin/env bash
# push_replay_recording.sh —— 把一份设备录制(Mac 上的 run-<uuid>/)推进台架
# (com.kyle.arloopbench)的 App 容器:Documents/replay_recordings/<run-…>/。
# 台架回放页(lib/vio/render/bench_replay_page.dart)只认这个目录。
#
# 用法:
#   tool/bench/push_replay_recording.sh <录制目录> [--dry-run]
#     录制目录 = ~/Developer/viobench-recordings/run-<uuid>(BasaltVIOBench 录的那种:
#                recording_manifest.json + frames.bin + frames.pwvi + camera_index.csv +
#                imu.csv + intrinsics.jsonl + arkit_poses.tum)
#     --dry-run = 只核对、算空间、打印将执行的 devicectl 命令,不碰手机
#   环境变量:PW_BENCH_UDID 覆盖设备。
#
# devicectl 用法逐字抄自 `xcrun devicectl device copy to --help`
# (「if the domain is an app data container, the identifier is the bundle ID of the app」)。
# BasaltVIOBench 的录制是在手机上录、再用 `devicectl device copy from --domain-type
# appDataContainer --domain-identifier <bundle> --user mobile` 拉回 Mac 的
# (scripts/backup_runs.sh、pw_run_arm.sh);这里是同一对参数的反方向。
#
# 只推回放要读的文件:manifest 的 files[](逐个核 SHA-256 与字节数,frames.bin 只核字节数 ——
# 4–5 GB 在 Mac 上重哈希太慢;要核就在手机上开 -PWBenchReplayVerifyDigest on)
# + recording_manifest.json + input_manifest.json / receipt.json(机型旁证,查外参与 c 用)。
# 先在 Mac 上用 APFS 克隆(cp -c,不占额外空间)摆成一个干净目录,再逐个文件推。
#
# 🔴 只推台架 com.kyle.arloopbench 的容器。生产 com.kyle.PocketWorld 不碰。
# 🔴 2026-09-23 只写了、`bash -n` 与 --dry-run 过,没在真机上跑过。devicectl copy 对目录是
#    「拷成」还是「拷进」文档没写死(BasaltVIOBench pw_run_arm.sh 拉回来时见过多一层
#    $RUN/$RUN 的情况)⇒ 这里逐个文件推进目标目录,推完用 info files 核落点。
#
# 手机上要多少空间 ≈ frames.bin + 几 MB。现有三份 1920×1440 录制:
#   run-6e2d4b99  frames.bin 4,705,689,600 B(4.38 GiB,1702 帧,无损,无 exposure_s)
#   run-4ad6e500  frames.bin 4,619,980,800 B(4.30 GiB,1671 帧,loss 95,有 exposure_s)
#   run-5966aec0  frames.bin 4,476,211,200 B(4.17 GiB,1619 帧,loss 155,无 exposure_s)
# 每帧 2,764,800 B(1920×1440 luma8)。回放输出每场几百 KB,可以忽略。

set -euo pipefail

UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
BUNDLE="com.kyle.arloopbench"
DRY=0
SRC=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) SRC="$a" ;;
  esac
done
[ -n "$SRC" ] || { sed -n '2,20p' "$0"; exit 2; }
SRC="$(cd "$SRC" && pwd)"
RUN="$(basename "$SRC")"
MAN="$SRC/recording_manifest.json"
[ -f "$MAN" ] || { echo "🔴 没有 $MAN" >&2; exit 2; }
case "$RUN" in
  run-*) ;;
  *) echo "🔴 目录名应是 run-<uuid>:$RUN" >&2; exit 2 ;;
esac

STAGE="${TMPDIR:-/tmp}/pw_bench_replay_push/$RUN"
rm -rf "$STAGE"; mkdir -p "$STAGE"

echo "== 核对 $SRC =="
python3 - "$SRC" "$STAGE" <<'PY'
import hashlib, json, os, shutil, subprocess, sys
src, stage = sys.argv[1], sys.argv[2]
m = json.load(open(os.path.join(src, 'recording_manifest.json')))
total = 0
names = ['recording_manifest.json']
for f in m['files']:
    p = os.path.join(src, f['relative_path'])
    if not os.path.isfile(p):
        sys.exit(f"🔴 缺 {f['relative_path']}")
    n = os.path.getsize(p)
    if n != f['byte_count']:
        sys.exit(f"🔴 {f['relative_path']} 字节数 {n} != manifest {f['byte_count']}")
    if f['role'] != 'frames_stream':
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        if h != f['sha256']:
            sys.exit(f"🔴 {f['relative_path']} sha256 不对")
    total += n
    names.append(f['relative_path'])
for side in ('input_manifest.json', 'receipt.json'):
    if os.path.isfile(os.path.join(src, side)):
        names.append(side)
for n in names:
    # APFS 克隆:不占额外空间
    subprocess.run(['cp', '-c', os.path.join(src, n), os.path.join(stage, n)], check=True)
cam = m['camera']
print(f"录制 {m['recording_id']}  {cam['width']}x{cam['height']} {cam['pixel_format']}  "
      f"帧 {m['frame_count']}  loss {m['loss_count']}"
      + ("  🔴 有损:回放要加 -PWBenchReplayAllowLossy on" if m['loss_count'] else ""))
if (cam['width'], cam['height']) != (1920, 1440):
    print(f"🔴 不是 1920×1440:回放会原样喂 {cam['width']}×{cam['height']},回执里标出")
print(f"要推 {len(names)} 个文件,共 {total/2**30:.2f} GiB(手机上至少留这么多 + 余量)")
for n in names:
    print('   ', n)
PY

# 逐个文件作 --source(help 原文:「This flag can be passed multiple times」),目的地是
# 目录 ⇒ 文件落在目录里;比「整目录拷成/拷进」少一层歧义。
CMD=(xcrun devicectl device copy to
     --device "$UDID"
     --domain-type appDataContainer
     --domain-identifier "$BUNDLE")
for f in "$STAGE"/*; do CMD+=(--source "$f"); done
CMD+=(--destination "Documents/replay_recordings/$RUN/"
      --json-output "${STAGE%/*}/$RUN.devicectl.json")
echo "== 将执行 =="
printf ' %q' "${CMD[@]}"; echo
if [ "$DRY" = 1 ]; then
  echo "(--dry-run:没碰手机)"
  exit 0
fi
"${CMD[@]}"

echo "== 核落点 =="
xcrun devicectl device info files --device "$UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --subdirectory "Documents/replay_recordings/$RUN" --no-recurse || true
echo
echo "应当看到 recording_manifest.json / frames.bin 等直接在 Documents/replay_recordings/$RUN/ 下。"
echo "若文件没落在这一层(例如多了一层目录),回放页列不出来 —— 看上面的列表调整 --destination 再推。"
echo "回放:tool/bench/launch_bench_replay.sh ${RUN#run-} on|off"
