#!/usr/bin/env bash
# pull_bench_replay_run.sh —— 把台架(com.kyle.arloopbench)容器里的一场录制回放拉回 Mac 并自检。
#
# 用法:
#   tool/bench/pull_bench_replay_run.sh                 # 列出手机上的回放场次
#   tool/bench/pull_bench_replay_run.sh <run> [dest]    # 拉 Documents/bench_replay_runs/<run> 到 <dest>/<run>
#       run  = replay_<录制前8位>_<pfk-on|pfk-off>_<节拍>_<yyyyMMdd_HHmmss>[_<标签>]
#              (lib/vio/replay/bench_replay_controller.dart runDirName 生成)
#       dest = 本地根目录,默认 ~/Developer/arloopbench/pulls
#   环境变量:PW_BENCH_UDID / PW_BENCH_BUNDLE 覆盖设备与 bundle。
#
# 形状抄 tool/bench/pull_zero_arkit_run.sh(同一个 devicectl 用法、同一道 bundle 闸、
# 两种落法都认)。
#
# 自检(全部从回执里读,不另算口径):
#   · receipt.json schema == pw.bench.replay-receipt/1、phase == done
#   · outputs 里每个文件:本地字节数 == 回执 bytes、sha256 == 回执 sha256
#   · invariants.passed(原生收尾闸:没丢帧 / 没丢 IMU / 传输层零拒收 / 观察到的帧 == 交出去的帧)
#   · 摘要:臂(pfk-on/off)、节拍、引擎臂(Info.plist PWXrslamEngineArm)、TUM 行数、
#     逐帧计时 wall_ms 中位数/p95、逐帧 K 来源直方图
#
# 🔴 只拉台架 com.kyle.arloopbench。生产 com.kyle.PocketWorld 不碰。
# 🔴 2026-09-23 只写了,自检那段 python 在 Mac 本地回放输出上跑过;devicectl 那段没在真机上跑过。
set -euo pipefail

UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
BUNDLE="${PW_BENCH_BUNDLE:-com.kyle.arloopbench}"
DEST_ROOT="${2:-$HOME/Developer/arloopbench/pulls}"

if [ "$BUNDLE" != "com.kyle.arloopbench" ]; then
  echo "🔴 只允许拉台架容器(com.kyle.arloopbench),拒绝:$BUNDLE" >&2
  exit 2
fi

if [ $# -lt 1 ]; then
  echo "== 手机 $UDID 上 $BUNDLE 的 Documents/bench_replay_runs/ =="
  xcrun devicectl device info files --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --subdirectory Documents/bench_replay_runs --no-recurse
  echo
  echo "用法:$0 <replay_…> [dest]"
  exit 0
fi

RUN="$1"
case "$RUN" in
  replay_*) ;;
  --check) ;;
  *) echo "🔴 run 名应以 replay_ 开头:$RUN" >&2; exit 2 ;;
esac

if [ "$RUN" = "--check" ]; then
  # 只自检一个本地目录(Mac 等价核对也用它):pull_bench_replay_run.sh --check <dir>
  RUN_DIR="${2:?}"
else
  mkdir -p "$DEST_ROOT"
  DEST="$DEST_ROOT/$RUN"
  echo "== 拉取 Documents/bench_replay_runs/$RUN → $DEST =="
  xcrun devicectl device copy from --device "$UDID" \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Documents/bench_replay_runs/$RUN" --destination "$DEST" \
    --json-output "$DEST_ROOT/$RUN.devicectl.json"
  if [ -f "$DEST/receipt.json" ]; then RUN_DIR="$DEST"
  elif [ -f "$DEST/$RUN/receipt.json" ]; then RUN_DIR="$DEST/$RUN"
  else echo "🔴 拉回来的目录里找不到 receipt.json(还没跑完?):$DEST" >&2; RUN_DIR="$DEST"; fi
fi

echo "== 自检 $RUN_DIR =="
python3 - "$RUN_DIR" <<'PY'
import csv, hashlib, json, os, statistics, sys
d = sys.argv[1]
ok = True
def bad(msg):
    global ok
    ok = False
    print('🔴', msg)
rp = os.path.join(d, 'receipt.json')
if not os.path.isfile(rp):
    print('🔴 没有 receipt.json'); sys.exit(1)
r = json.load(open(rp, encoding='utf-8'))
if r.get('schema') != 'pw.bench.replay-receipt/1': bad(f"schema={r.get('schema')}")
if r.get('phase') != 'done': bad(f"phase={r.get('phase')} error={r.get('error')}")
for name, meta in (r.get('outputs') or {}).items():
    p = os.path.join(d, name)
    if not os.path.isfile(p): bad(f'缺 {name}'); continue
    b = open(p, 'rb').read()
    if len(b) != meta.get('bytes'): bad(f"{name} 字节 {len(b)} != 回执 {meta.get('bytes')}")
    if hashlib.sha256(b).hexdigest() != meta.get('sha256'): bad(f'{name} sha256 对不上')
inv = r.get('invariants') or {}
if not inv.get('passed'): bad(f"invariants 没过:{inv.get('failed')}")
sw = r.get('switches') or {}
eng = ((r.get('engine') or {}).get('info_plist') or {})
rec = r.get('recording') or {}
feed = r.get('feed_resolution') or {}
print(f"录制 {rec.get('recording_id')}  {feed.get('width')}x{feed.get('height')}  "
      f"臂 {sw.get('arm_label')}  节拍 {sw.get('pace')}  引擎 {eng.get('PWXrslamEngineArm', '没盖章')}"
      f"  覆盖 {[o.get('arg') for o in ((r.get('config') or {}).get('yaml_overrides') or [])]}")
outs = r.get('outputs') or {}
print(f"TUM camera {outs.get('poses_camera.tum', {}).get('rows')} 行 / body "
      f"{outs.get('poses_body.tum', {}).get('rows')} 行")
tp = os.path.join(d, 'frame_timing.csv')
if os.path.isfile(tp):
    rows = list(csv.DictReader(open(tp)))
    w = sorted(float(x['wall_ms']) for x in rows if x['wall_ms'] not in ('', 'nan'))
    if w:
        p95 = w[min(len(w) - 1, int(0.95 * len(w)))]
        print(f"逐帧 wall_ms:{len(w)} 帧 中位 {statistics.median(w):.2f} p95 {p95:.2f} 最大 {w[-1]:.2f}")
    s = [x['sw_solver_ms'] for x in rows]
    have = [float(v) for v in s if v not in ('', 'nan', 'NaN')]
    print(f"引擎求解遥测:{'有 ' + str(len(have)) + ' 帧' if have else '这条臂没有(列为 nan / -1)'}")
lp = os.path.join(d, 'intrinsics_ledger.csv')
if os.path.isfile(lp):
    hist = {}
    for x in csv.DictReader(open(lp)):
        hist[x['k_source']] = hist.get(x['k_source'], 0) + 1
    print(f"逐帧 K 来源:{hist}")
print('✅ 自检通过' if ok else '🔴 自检没过')
sys.exit(0 if ok else 1)
PY
