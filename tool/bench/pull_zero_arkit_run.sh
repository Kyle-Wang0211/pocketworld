#!/usr/bin/env bash
# pull_zero_arkit_run.sh —— 把台架(com.kyle.arloopbench)容器里的一次零 ARKit
# 端到端拍摄 run 拉回 Mac,并逐张自检。
#
# 用法:
#   tool/bench/pull_zero_arkit_run.sh                 # 列出手机上可用的 run
#   tool/bench/pull_zero_arkit_run.sh <run> [dest]    # 拉 Documents/<run> 到 <dest>/<run>
#       run  = 页面写的目录名,形如 zeroarkit_run_20260922_180507
#              (由 lib/vio/render/zero_arkit_capture_probe_page.dart 的
#               zeroArkitRunDirName 生成)
#       dest = 本地根目录,默认 ~/Developer/arloopbench/pulls
#   环境变量:PW_BENCH_UDID / PW_BENCH_BUNDLE 可覆盖设备与 bundle。
#
# devicectl 的用法逐字抄自
#   `xcrun devicectl device info files --help`
#   `xcrun devicectl device copy from --help`
# ——「the identifier is the bundle ID of the app」那句就是 --domain-identifier
# 的依据。不是新发明。
#
# 🔴 只拉台架 com.kyle.arloopbench 的容器。生产 com.kyle.PocketWorld 不碰。
# 🔴 本脚本 2026-09-22 只做过 `bash -n`,没在真机 run 上跑过。
#    `copy from --destination` 对目录到底是「拷成 dest」还是「拷进 dest」,
#    文档没写死,下面的自检两种落法都认。
#
# 自检(每张 photo_N.jpg + photo_N.json):
#   · JPEG 前两字节 FF D8
#   · sidecar poseSource == 'xrslam'
#   · extrinsic 恰 16 个有限数(不跟踪时如实为空,标 EMPTY,不算通过)
#   · anchors_world 为空表(VIO 没有 ARKit 锚点,必须为空)
#   · intrinsics_fxfycxcy 恰 4 个有限数
#   · t 有限
# 再印 run_manifest.json 的摘要。

set -euo pipefail

UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
BUNDLE="${PW_BENCH_BUNDLE:-com.kyle.arloopbench}"
DEST_ROOT="${2:-$HOME/Developer/arloopbench/pulls}"

if [ "$BUNDLE" != "com.kyle.arloopbench" ]; then
  echo "🔴 只允许拉台架容器(com.kyle.arloopbench),拒绝:$BUNDLE" >&2
  exit 2
fi

list_runs() {
  echo "== 手机 $UDID 上 $BUNDLE 的 Documents/ =="
  xcrun devicectl device info files \
    --device "$UDID" \
    --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" \
    --subdirectory Documents \
    --no-recurse
  echo
  echo "用法:$0 <zeroarkit_run_yyyyMMdd_HHmmss> [dest]"
}

if [ $# -lt 1 ]; then
  list_runs
  exit 0
fi

RUN="$1"
case "$RUN" in
  zeroarkit_run_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "🔴 run 名不合 zeroarkit_run_<yyyyMMdd_HHmmss>:$RUN" >&2; exit 2 ;;
esac

mkdir -p "$DEST_ROOT"
DEST="$DEST_ROOT/$RUN"
JSON_OUT="$DEST_ROOT/$RUN.devicectl.json"

echo "== 拉取 Documents/$RUN → $DEST =="
xcrun devicectl device copy from \
  --device "$UDID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE" \
  --source "Documents/$RUN" \
  --destination "$DEST" \
  --json-output "$JSON_OUT"

# 两种落法都认:dest 本身就是 run,或 run 被拷进了 dest/run。
if [ -f "$DEST/run_manifest.json" ]; then
  RUN_DIR="$DEST"
elif [ -f "$DEST/$RUN/run_manifest.json" ]; then
  RUN_DIR="$DEST/$RUN"
else
  echo "🔴 拉回来的目录里找不到 run_manifest.json(页面没按「完成」?):$DEST" >&2
  RUN_DIR="$DEST"
fi

echo "== 自检 $RUN_DIR =="
python3 - "$RUN_DIR" <<'PY'
import json, math, os, re, sys

run_dir = sys.argv[1]
def finite(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x)

manifest = None
mp = os.path.join(run_dir, 'run_manifest.json')
if os.path.isfile(mp):
    with open(mp, encoding='utf-8') as f:
        manifest = json.load(f)

status_by_index = {}
if manifest:
    for p in manifest.get('photos', []):
        status_by_index[p.get('index')] = p.get('status')

jpgs = sorted(
    (f for f in os.listdir(run_dir) if re.fullmatch(r'photo_\d+\.jpg', f)),
    key=lambda f: int(re.findall(r'\d+', f)[0]),
)
rows = []
ok_all = True
for jpg in jpgs:
    idx = int(re.findall(r'\d+', jpg)[0])
    jp = os.path.join(run_dir, jpg)
    sp = os.path.join(run_dir, f'photo_{idx}.json')
    with open(jp, 'rb') as f:
        magic = f.read(2)
    jpeg_ok = magic == b'\xff\xd8'
    size = os.path.getsize(jp)
    pose_src = ext = anchors = k = t = '-'
    ext_ok = anchors_ok = k_ok = t_ok = src_ok = False
    if os.path.isfile(sp):
        with open(sp, encoding='utf-8') as f:
            sc = json.load(f)
        pose_src = sc.get('poseSource')
        src_ok = pose_src == 'xrslam'
        e = sc.get('extrinsic')
        if isinstance(e, list) and len(e) == 16 and all(finite(v) for v in e):
            ext, ext_ok = '16', True
        elif isinstance(e, list) and len(e) == 0:
            ext = 'EMPTY'
        else:
            ext = f'BAD({len(e) if isinstance(e, list) else type(e).__name__})'
        a = sc.get('anchors_world')
        anchors_ok = isinstance(a, list) and len(a) == 0
        anchors = 'empty' if anchors_ok else f'BAD({a!r:.20})'
        kk = sc.get('intrinsics_fxfycxcy')
        k_ok = isinstance(kk, list) and len(kk) == 4 and all(finite(v) for v in kk)
        k = '4' if k_ok else f'BAD({kk!r:.20})'
        tt = sc.get('t')
        t_ok = finite(tt)
        t = f'{tt:.3f}' if t_ok else f'BAD({tt!r})'
    else:
        pose_src = 'NO_SIDECAR'
    verdict = jpeg_ok and src_ok and ext_ok and anchors_ok and k_ok and t_ok
    ok_all = ok_all and verdict
    rows.append((jpg, f'{size/1e6:.2f}MB', 'FFD8' if jpeg_ok else 'BAD', str(pose_src),
                 ext, anchors, k, t, status_by_index.get(idx, '-'),
                 '✅' if verdict else '🔴'))

hdr = ('file', 'size', 'jpeg', 'poseSource', 'extrinsic', 'anchors_world',
       'K', 't', 'manifest_status', 'verdict')
widths = [max(len(str(r[i])) for r in [hdr] + rows) for i in range(len(hdr))]
def line(r):
    return '  '.join(str(v).ljust(widths[i]) for i, v in enumerate(r))
print(line(hdr))
print(line(tuple('-' * w for w in widths)))
for r in rows:
    print(line(r))
if not rows:
    print('(没有 photo_N.jpg —— 这一 run 没按过快门,或快门全部非 saved)')

if manifest:
    c = manifest.get('camera_time_offset') or {}
    s = manifest.get('session') or {}
    m = manifest.get('machine') or {}
    print()
    print(f"manifest: 机型={m.get('hw_machine')} prime={m.get('device_machine_prime')} "
          f"c={c.get('milliseconds')}ms provenance={c.get('provenance')} "
          f"session ok={s.get('ok')} err={s.get('error')} "
          f"相机 rc={(manifest.get('camera') or {}).get('start_rc')} "
          f"内参等待={(manifest.get('camera') or {}).get('intrinsics_wait_ms')}ms")
    print(f"          位姿帧={manifest.get('pose_frames')} 跟踪帧={manifest.get('tracking_frames')} "
          f"状态={manifest.get('tracking_state_counts')} 档={manifest.get('confidence_tier_counts')} "
          f"照片={manifest.get('photos_saved')}/{manifest.get('photos_requested')} "
          f"时长={manifest.get('page_duration_s')}s")
    for p in manifest.get('photos', []):
        print(f"          #{p.get('index')} {p.get('status')} {p.get('message') or ''} "
              f"{p.get('elapsed_ms')}ms state@trigger={p.get('tracking_state_at_trigger')}")
else:
    print('(无 run_manifest.json)')

sys.exit(0 if ok_all else 1)
PY
