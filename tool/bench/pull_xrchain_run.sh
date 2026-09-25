#!/usr/bin/env bash
# pull_xrchain_run.sh —— 把台架(com.kyle.arloopbench)里的一次「XRSLAM → SfM 重建链」run 拉回 Mac 并自检。
# 形状照抄 tool/bench/pull_zero_arkit_run.sh(devicectl 用法同源,两种落法都认)。
#
# 用法:
#   tool/bench/pull_xrchain_run.sh                   # 列出手机上的 Documents/
#   tool/bench/pull_xrchain_run.sh <run> [dest]      # 拉 Documents/<run> + 它引用的 pw_photos/<id>.{jpg,json}
#       run  = xrchain_run_yyyyMMdd_HHmmss(lib/bench_xrchain/xr_recon_chain_page.dart 生成)
#       dest = 本地根目录,默认 ~/Developer/arloopbench/pulls
#   环境变量:PW_BENCH_UDID / PW_BENCH_BUNDLE 可覆盖设备与 bundle。
# 🔴 只拉台架 com.kyle.arloopbench 的容器,生产 com.kyle.PocketWorld 不碰。拉之前先 df -h ~(每张照片 3–5 MB)。
set -euo pipefail
UDID="${PW_BENCH_UDID:-1B290474-D354-5B4C-AAB0-0805AC5DC832}"
BUNDLE="${PW_BENCH_BUNDLE:-com.kyle.arloopbench}"
DEST_ROOT="${2:-$HOME/Developer/arloopbench/pulls}"
[ "$BUNDLE" = "com.kyle.arloopbench" ] || { echo "🔴 只允许拉台架容器,拒绝:$BUNDLE" >&2; exit 2; }
if [ $# -lt 1 ]; then
  xcrun devicectl device info files --device "$UDID" --domain-type appDataContainer \
    --domain-identifier "$BUNDLE" --subdirectory Documents --no-recurse
  echo; echo "用法:$0 <xrchain_run_yyyyMMdd_HHmmss> [dest]"; exit 0
fi
RUN="$1"
case "$RUN" in
  xrchain_run_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "🔴 run 名不合 xrchain_run_<yyyyMMdd_HHmmss>:$RUN" >&2; exit 2 ;;
esac
mkdir -p "$DEST_ROOT"; DEST="$DEST_ROOT/$RUN"
xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source "Documents/$RUN" --destination "$DEST" --json-output "$DEST_ROOT/$RUN.devicectl.json"
if [ -f "$DEST/chain_photos.jsonl" ]; then RUN_DIR="$DEST"; elif [ -f "$DEST/$RUN/chain_photos.jsonl" ]; then RUN_DIR="$DEST/$RUN"; else
  echo "🔴 找不到 chain_photos.jsonl:$DEST" >&2; exit 3; fi
mkdir -p "$RUN_DIR/photos"
python3 - "$RUN_DIR/chain_photos.jsonl" > "$RUN_DIR/photos/_list.txt" <<'PY'
import json, sys, os
seen = set()
for ln in open(sys.argv[1]):
    r = json.loads(ln)
    for k in ('jpeg', 'sidecar'):
        p = r.get(k)
        if p and '/Documents/pw_photos/' in p:
            rel = 'Documents/pw_photos/' + p.split('/Documents/pw_photos/')[1]
            if rel not in seen:
                seen.add(rel); print(rel)
PY
while IFS= read -r rel; do
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "$rel" --destination "$RUN_DIR/photos/$(basename "$rel")" >/dev/null
done < "$RUN_DIR/photos/_list.txt"
echo "== 自检 $RUN_DIR"
python3 - "$RUN_DIR" <<'PY'
import json, os, sys, statistics as st
d = sys.argv[1]
rows = [json.loads(l) for l in open(os.path.join(d, 'chain_photos.jsonl'))]
done = [r for r in rows if 'pose_source' in r]
print(f"照片行 {len(rows)};有位姿结论 {len(done)};可信 {sum(1 for r in done if r['device_pose_trusted'])}")
by = {}
for r in done: by[r['pose_source']] = by.get(r['pose_source'], 0) + 1
print('来源', by)
w = [r['wait_from_photo_ms'] for r in done if r['pose_source'] == 'final']
if w: print(f"FINAL 等待:中位 {st.median(w):.0f} ms,最大 {max(w):.0f} ms")
x = [r['extrapolation_ms'] for r in done]
if x: print(f"外推长度:中位 {st.median(x):.1f} ms,最大 {max(x):.1f} ms")
for r in done:
    if not r['device_pose_trusted']:
        print(f"  不可信 #{r['request_id']} {r['pose_source']} {r['untrusted_reasons']} 外推 {r['extrapolation_ms']:.1f} ms")
missing = [r['jpeg'] for r in rows if r.get('jpeg') and not os.path.isfile(os.path.join(d, 'photos', os.path.basename(r['jpeg'])))]
print('照片缺失', len(missing))
m = os.path.join(d, 'run_manifest.json')
if os.path.isfile(m):
    mm = json.load(open(m)); print('manifest sfm', mm.get('sfm'), '错误', mm.get('sfm_errors'))
else:
    print('(无 run_manifest.json:页面没按「完成」?)')
for f in ('sfm_refined_poses.csv', 'sfm_refined_points.ply', 'official_sfm_fed_frames.jsonl', 'sfm_match_fail.jsonl'):
    print(f, '有' if os.path.isfile(os.path.join(d, f)) else '无')
PY
