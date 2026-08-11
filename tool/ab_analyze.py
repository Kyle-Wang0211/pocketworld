#!/usr/bin/env python3
"""A16 效率门 A/B 分析 v3 — 相邻块配对(正式判据,用户 2026-08-10 签决)

用法: python3 tool/ab_analyze.py <手机Documents拉回目录> <capture_id> [capture_id...]

v3 正式规则(取代 v2 混池):
  块 = ab-assignment.jsonl 中同臂连续帧段;相邻异臂块配对,
  delta = (B块中位 - A块中位) / A块中位;跨作品汇总全部配对,
  均值 ± t 分布 95% CI。
  判决:CI 上界 ≤ +5% 且 B 热峰 ≤ A 热峰 → PASS;下界 > +5% → FAIL;
  否则 ACCUMULATE。
  动机:管线 proc_ms 随拍摄单调爬升(增量SfM地图增长,实测 1177→2228ms),
  混池 CI 被趋势撑爆永不收口;配对按设计消除趋势(协议既定意图)。
"""
import json, sys, math

docs = sys.argv[1]
caps = sys.argv[2:]

all_pairs = []
per_cap = []
pooled = {'A': [], 'B': []}
for cap in caps:
    try:
        entries = []
        t_min, t_max = float('inf'), 0
        for line in open(f'{docs}/captures_official/{cap}/photos_hevc/ab-assignment.jsonl'):
            d = json.loads(line)
            entries.append(d)
            t_min = min(t_min, d['t']); t_max = max(t_max, d['t'])
    except FileNotFoundError:
        per_cap.append({'capture': cap, 'status': 'no_assignment_file'})
        continue
    proc = {}
    thermal = {'A': 0, 'B': 0}
    for line in open(f'{docs}/telemetry_official_dart.jsonl'):
        try: d = json.loads(line)
        except: continue
        if d.get('type') != 'frame': continue
        if not (t_min - 600_000 <= d.get('t', 0) <= t_max + 600_000): continue
        if isinstance(d.get('proc_ms'), (int, float)):
            proc.setdefault(d.get('jpeg', ''), []).append(d)
    # 同臂连续段 = 块(对任意 abPeriod 稳健)
    blocks = []
    for e in sorted(entries, key=lambda x: x['index']):
        arm = e['arm']
        frames = proc.get(e['jpeg'], [])
        for f in frames:
            thermal[arm] = max(thermal[arm], f.get('thermal', 0))
            pooled[arm].append(f['proc_ms'])
        if blocks and blocks[-1][0] == arm:
            blocks[-1][1].extend(f['proc_ms'] for f in frames)
        else:
            blocks.append((arm, [f['proc_ms'] for f in frames]))
    def med(v):
        v = sorted(v); n = len(v)
        return v[n//2] if n % 2 else (v[n//2-1]+v[n//2])/2
    pairs = []
    for (a1, v1), (a2, v2) in zip(blocks, blocks[1:]):
        if len(v1) < 4 or len(v2) < 4: continue
        if a1 == 'A' and a2 == 'B': pairs.append((med(v2)-med(v1))/med(v1))
        elif a1 == 'B' and a2 == 'A': pairs.append((med(v1)-med(v2))/med(v2))
    all_pairs += pairs
    per_cap.append({'capture': cap, 'blocks': len(blocks), 'pairs': len(pairs),
                    'thermal_max': thermal})

report = {'rule': 'v3_adjacent_block_pairing (signed 2026-08-10)',
          'captures': per_cap, 'total_pairs': len(all_pairs)}
if len(all_pairs) >= 6:
    n = len(all_pairs)
    mean = sum(all_pairs)/n
    sd = math.sqrt(sum((x-mean)**2 for x in all_pairs)/(n-1))
    se = sd/math.sqrt(n)
    # t 临界值(95% 双侧)常用区间近似
    tcrit = {6:2.571,7:2.447,8:2.365,9:2.306,10:2.262,12:2.201,15:2.145,
             20:2.093,25:2.064,30:2.045}.get(n-1)
    if tcrit is None:
        tcrit = 2.045 if n-1 > 30 else 2.571
    lo, hi = mean-tcrit*se, mean+tcrit*se
    tha = max((c['thermal_max']['A'] for c in per_cap if 'thermal_max' in c), default=0)
    thb = max((c['thermal_max']['B'] for c in per_cap if 'thermal_max' in c), default=0)
    report['pair_deltas_pct'] = [round(100*x, 1) for x in all_pairs]
    report['mean_pct'] = round(100*mean, 2)
    report['ci95_pct'] = [round(100*lo, 2), round(100*hi, 2)]
    report['thermal_max'] = {'A': tha, 'B': thb}
    if hi <= 0.05 and thb <= tha:
        report['gate'] = 'PASS'
    elif lo > 0.05:
        report['gate'] = 'FAIL'
    else:
        report['gate'] = 'ACCUMULATE (CI 上界 %.1f%% > 5%%,继续自然拍摄累积)' % (100*hi)
else:
    report['gate'] = 'ACCUMULATE (配对不足 6 组)'
print(json.dumps(report, indent=1, ensure_ascii=False))
