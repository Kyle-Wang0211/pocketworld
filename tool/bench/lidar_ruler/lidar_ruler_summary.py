#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""🔴 bench-only ruler:LiDAR 米尺 v2 报告汇总(只读)。

v1 的汇总(scratchpad preint/tools/ruler3_sum.py)把标称 0.5 s 与 0.75 s 两份报告当成两组测量求均值,
而在 0.3 s 间隔的子集帧上这两档选出的是**同一批帧对**(实际都是 0.6 s)⇒ 同一个测量被算两次。
本脚本按 (录制, 深度目录, 帧对集合 sha256, 基础变体) 去重:相同的只计一次,并列出被去掉的重复报告。
不做跨报告平均 —— v2 单份报告已经在多档帧对上合并、给出块 bootstrap ∪ 方法范围 ∪ 噪声底的 95% 区间。

用法:/usr/bin/python3 lidar_ruler_summary.py <lidar_ruler_report.json> [...] [--json out.json]
"""
import json
import sys


def key_of(rep):
    meta = rep.get('meta', {})
    return (rep.get('recording'), rep.get('depth_dir'), meta.get('pair_set_sha256'), meta.get('base_variant'))


def main(argv):
    out_json = None
    if '--json' in argv:
        i = argv.index('--json')
        out_json = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    seen, dups, rows = {}, [], []
    for p in argv:
        rep = json.load(open(p))
        if rep.get('schema') != 'pw.bench.lidar-ruler/2':
            print(f'🔴 {p}:不是 v2 报告(schema {rep.get("schema")}),拒绝混算')
            return 2
        k = key_of(rep)
        if k in seen:
            dups.append((p, seen[k]))
            continue
        seen[k] = p
        for n, t in rep['trajectories'].items():
            e = t['estimate']
            rows.append({'report': p, 'recording': rep['recording'], 'trajectory': n, 'k': e.get('k'),
                         'k_minus_1_pct': e.get('k_minus_1_pct'), 'ci95_total_minus_1_pct': t.get('ci95_total_minus_1_pct'),
                         'verdict': t.get('verdict'), 'pairs': [e.get('pairs_with_scale'), e.get('pairs_attempted')]})
    for p, q in dups:
        print(f'  去重:{p} 与 {q} 是同一个测量(同录制、同帧对集合、同变体)⇒ 只计一次')
    print(f'唯一测量 {len(seen)} 份(输入 {len(argv)} 份)')
    for r in rows:
        ci = r['ci95_total_minus_1_pct'] or [float('nan'), float('nan')]
        print(f'  {r["recording"].rsplit("/", 1)[-1][:12]}  {r["trajectory"]:<28} k−1 {r["k_minus_1_pct"]:+.2f}%  '
              f'总 95% [{ci[0]:+.2f}, {ci[1]:+.2f}]%  {r["verdict"]}  帧对 {r["pairs"][0]}/{r["pairs"][1]}')
    if out_json:
        json.dump({'unique_reports': list(seen.values()), 'duplicates': dups, 'rows': rows},
                  open(out_json, 'w'), indent=1, ensure_ascii=False)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
