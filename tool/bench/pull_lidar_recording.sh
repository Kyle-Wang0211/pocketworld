#!/usr/bin/env bash
# pull_lidar_recording.sh —— 把台架(com.kyle.arloopbench)里一份 LiDAR 米尺录制的**尺子子集**拉回 Mac,
# 可选再拉一场手机回放(XRSLAM 位姿),然后直接跑离线尺子。🔴 bench-only ruler:LiDAR 永不进产品。
#
# 用法:
#   tool/bench/pull_lidar_recording.sh                          # 列出手机上的 replay_recordings/
#   tool/bench/pull_lidar_recording.sh <run-…> [replay_…|latest] [dest]
#       run-…    = Documents/replay_recordings/<run-uuid>(录制页写的;只拉它的 ruler_subset/,约 400 MB/30 s,
#                  **不拉** 5 GB 的整份 frames.bin —— Mac 盘放不下,尺子也用不着)
#       replay_… = Documents/bench_replay_runs/<replay_…>(回放页在手机上跑出的 XRSLAM 位姿,几百 KB)
#       dest     = 本地根目录,默认 ~/Developer/arloopbench/pulls
#   环境变量:PW_BENCH_UDID / PW_BENCH_BUNDLE 覆盖设备与 bundle;
#            PW_BENCH_SUBSET 子集目录名(默认 ruler_subset;给老录制重导的是 ruler_subset_xr30)。
#
# [2026-09-24 rec30] XRSLAM 直接喂尺子:回放目录里有 poses_camera_by_recording_frame.csv(本版起的手机回放
#   都写)⇒ `--xrslam-camera`(按录制帧 t_ns 整数相等取 CAMERA 位姿,零容差、不插值)+ 同名 ledger
#   (只用来给缺位姿的帧分类)。老回放没有这份 ⇒ 退回 BODY + ledger + yaml 外参,并警告「帧未必对齐」。
#
# 形状抄 tool/bench/pull_bench_replay_run.sh(同一个 devicectl 用法、同一道 bundle 闸)。
# 🔴 只拉台架 com.kyle.arloopbench,生产 com.kyle.PocketWorld 不碰。
# 2026-09-24 真机上跑过(run-fb5d3a8f);rec30 改动见上。
set -euo pipefail

UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
BUNDLE="${PW_BENCH_BUNDLE:-com.kyle.arloopbench}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$BUNDLE" != "com.kyle.arloopbench" ]; then
  echo "🔴 只允许拉台架容器(com.kyle.arloopbench),拒绝:$BUNDLE" >&2
  exit 2
fi

list() {
  xcrun devicectl device info files --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory "$1" --no-recurse
}

if [ $# -lt 1 ]; then
  echo "== 手机 $UDID 上 $BUNDLE 的 Documents/replay_recordings/ =="
  list Documents/replay_recordings
  echo
  echo "用法:$0 <run-…> [replay_…|latest] [dest]"
  exit 0
fi

RUN="$1"
REPLAY=""
DEST_ROOT="$HOME/Developer/arloopbench/pulls"
if [ $# -ge 2 ]; then
  case "$2" in replay_*|latest) REPLAY="$2"; DEST_ROOT="${3:-$DEST_ROOT}" ;; *) DEST_ROOT="$2" ;; esac
fi
case "$RUN" in run-*) ;; *) echo "🔴 录制名应以 run- 开头:$RUN" >&2; exit 2 ;; esac
# rec30:第二个参数写 latest ⇒ 取手机上这份录制最新的一场回放
#   (回放目录名 replay_<录制 id 前 8 位>_…,按修改时间取最新)。
if [ "$REPLAY" = latest ]; then
  RID="${RUN#run-}"; RID="${RID:0:8}"
  TMPD="$(mktemp -d -t pwreplays)"; TMPJ="$TMPD/list.json"
  xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --subdirectory Documents/bench_replay_runs --no-recurse \
    --json-output "$TMPJ" >/dev/null 2>&1 || true
  REPLAY="$(/usr/bin/python3 - "$TMPJ" "$RID" <<'PY2'
import json, sys
try:
    fs = json.load(open(sys.argv[1]))['result']['files']
except Exception:
    fs = []
c = [f for f in fs if f['relativePath'].split('/')[-1].startswith('replay_' + sys.argv[2])
     and f.get('resources', {}).get('isDirectory')]
c.sort(key=lambda f: f['metadata'].get('lastModDate', ''))
print(c[-1]['relativePath'].split('/')[-1] if c else '')
PY2
)"
  rm -rf "$TMPD"
  [ -n "$REPLAY" ] || { echo "🔴 手机上没有 $RUN 的回放(replay_${RID}_…):先在台架「回放」页回放这份录制" >&2; exit 2; }
  echo "== 最新回放:$REPLAY =="
fi

SUBNAME="${PW_BENCH_SUBSET:-ruler_subset}"
case "$SUBNAME" in ruler_subset*) ;; *) echo "🔴 子集目录名应以 ruler_subset 开头:$SUBNAME" >&2; exit 2 ;; esac
mkdir -p "$DEST_ROOT/$RUN"
echo "== 拉取 Documents/replay_recordings/$RUN/$SUBNAME → $DEST_ROOT/$RUN/$SUBNAME =="
xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "Documents/replay_recordings/$RUN/$SUBNAME" \
  --destination "$DEST_ROOT/$RUN/$SUBNAME"
SUB="$DEST_ROOT/$RUN/$SUBNAME"
[ -d "$SUB/$SUBNAME" ] && SUB="$SUB/$SUBNAME"   # devicectl 两种落法都认

# 自检:子集 frames.bin 与子集清单的 sha256 / 字节数一致;深度三件套在。
/usr/bin/python3 - "$SUB" <<'PY'
import hashlib, json, os, sys
d = sys.argv[1]
m = json.load(open(os.path.join(d, 'ruler_subset_manifest.json')))
p = os.path.join(d, 'frames.bin')
h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
ok = h == m['frames_bin_sha256'] and os.path.getsize(p) == m['frames_bin_bytes']
for f in ('depth.bin', 'depth_conf.bin', 'depth.pwvi', 'intrinsics.jsonl', 'arkit_poses.tum'):
    ok = ok and os.path.exists(os.path.join(d, f))
t = json.load(open(os.path.join(d, 'recorder_timing.json'))) if os.path.exists(os.path.join(d, 'recorder_timing.json')) else {}
xa = m.get('xrslam_admission') or {}
print(f"子集帧 {m['frames']} / 录制帧 {m['source_frame_count']};深度行 {m['depth_rows']};"
      f"frames.bin sha {'✅' if ok else '🔴'};ARKit 少发帧估计 {t.get('arkit_frames_missed_estimate')};"
      f"写器丢帧 {t.get('writer', {}).get('loss_count')};跟踪 {t.get('tracking_counts')}")
print(f"录制频率 {t.get('record_hz', '60(旧录制,未过闸)')} Hz · 写法 {t.get('write_sync', 'fsync_each(旧)')} · "
      f"子集帧全是 XRSLAM 会收的帧: {xa.get('every_subset_frame_admitted', '旧导出器未核')}"
      f"(闸 {xa.get('camera_hz', '?')} Hz,来源 {xa.get('gate_source', '?')})")
sys.exit(0 if ok else 1)
PY

ARGS=(--recording "$SUB" --arkit --out "$DEST_ROOT/$RUN/lidar_ruler")
if [ -n "$REPLAY" ]; then
  echo "== 拉取 Documents/bench_replay_runs/$REPLAY → $DEST_ROOT/$REPLAY =="
  xcrun devicectl device copy from --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/bench_replay_runs/$REPLAY" --destination "$DEST_ROOT/$REPLAY"
  RD="$DEST_ROOT/$REPLAY"; [ -d "$RD/$REPLAY" ] && RD="$RD/$REPLAY"
  # 2026-09-24 真机首跑补:回放没跑完(如「有损录制照源规矩拒」phase=failed)时目录里只有
  # receipt.json + 两份 yaml,没有 poses_body.tum ⇒ 原先会把不存在的路径喂给尺子、Python 回溯退出,
  # ARKit 那条也不出。现在:回执 phase ≠ done 或没有位姿 ⇒ 报出回执里的 error,只量 ARKit。
  PHASE="$(/usr/bin/python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r.get("phase"), "|", r.get("error") or "")' "$RD/receipt.json" 2>/dev/null || echo "no_receipt |")"
  if [ "${PHASE%% *}" != "done" ] || [ ! -f "$RD/poses_body.tum" ]; then
    echo "🔴 回放 $REPLAY 没有可用的 XRSLAM 位姿(phase/error: $PHASE)⇒ 本次只量 ARKit" >&2
  elif [ -f "$RD/poses_camera_by_recording_frame.csv" ]; then
    # rec30:引擎 CAMERA 位姿按录制帧 t_ns 精确键控,尺子整数相等取,不插值、不经外参。
    ARGS+=(--xrslam-camera "xr=$RD/poses_camera_by_recording_frame.csv"
           --xrslam-ledger "xr=$RD/intrinsics_ledger.csv")
  else
    echo "⚠️ 回放 $REPLAY 是老版本(没有 poses_camera_by_recording_frame.csv)⇒ 退回 BODY + 外参;" \
         "子集帧未必都是 XRSLAM 收下的帧,缺的帧不插值、直接不用" >&2
    # 回放目录的 device_config.yaml(bench_replay_controller.dart 写的)里有 cam0.extrinsic.q_bc / p_bc。
    ARGS+=(--xrslam "xr=$RD/poses_body.tum" --xrslam-ledger "xr=$RD/intrinsics_ledger.csv"
           --xrslam-yaml "$RD/device_config.yaml")
  fi
fi
echo "== 离线尺子 =="
/usr/bin/python3 "$HERE/lidar_ruler/lidar_ruler.py" "${ARGS[@]}"
