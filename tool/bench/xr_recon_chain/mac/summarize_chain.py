#!/usr/bin/python3
"""summarize_chain.py <scene...> —— [xrchain] 每场:引擎外推接口 vs 参照 xr_propagate2(逐字段 %.17g)、链路结果 vs 自检
(相机位姿逐位)、前端 hex 两次运行逐位、以及每张照片的来源 / 等待 / 可信。"""
import csv, sys, statistics as st, filecmp
SRC = {'1': 'FINAL', '2': 'WINDOW_AT_CLOSE', '3': 'TIMEOUT', '4': 'NO_BACKEND'}
for sc in sys.argv[1:]:
    a = [l.split() for l in open(f'runs/st_{sc}.prop')]; b = [l.split() for l in open(f'runs/st_{sc}.ref')]
    eq = sum(1 for x, y in zip(a, b) if x[:19] == y[:19]) if len(a) == len(b) else -1
    prop = {l[0][1:]: l for l in a}
    rows = list(csv.DictReader(open(f'runs/ch_{sc}.tsv'), delimiter='\t'))
    same = sum(1 for r in rows if r['has_pose'] == '1' and [r[k] for k in ['cpx','cpy','cpz','cqx','cqy','cqz','cqw']] == prop.get(r['photo_id'], [None]*19)[12:19])
    hexsame = filecmp.cmp(f'runs/st_{sc}.hex', f'runs/ch_{sc}.hex', shallow=False)
    fin = [float(r['wait_ms']) for r in rows if r['source'] == '1']
    ex = [float(r['extrap_ms']) for r in rows if r['source'] in '12']
    print(f'== {sc}: 接口 vs xr_propagate2 逐字段相同 {eq}/{len(a)};链路 vs 自检相机位姿逐位相同 {same}/{len(rows)};'
          f'前端 hex(自检回放 vs 链路回放)逐位相同 {hexsame}')
    print(f'   来源 {dict((SRC[s], sum(1 for r in rows if r["source"]==s)) for s in "1234")};可信 {sum(r["trusted"]=="1" for r in rows)}/{len(rows)};'
          f'FINAL 等待(数据时间,拍照时刻→定稿可用)中位 {st.median(fin):.0f} ms、最大 {max(fin):.0f} ms;外推长度中位 {st.median(ex):.1f} ms、最大 {max(ex):.1f} ms')
    for r in rows:
        if r['trusted'] != '1' or r['source'] != '1':
            print(f'   照片 {r["photo_id"]:>3} {SRC[r["source"]]:<15} 可信 {r["trusted"]} 原因位 {r["reasons"]:>3} 拍照时刻引擎状态 {r["state_at_photo"]} '
                  f'外推 {float(r["extrap_ms"]):.1f} ms 外推状态 {r["prop_status"]}')
