#!/usr/bin/python3
"""make_photos.py —— [xrchain] Mac 链路回放用的模拟照片时刻(引擎时域)。
首帧后 3 s 起每 1.45 s 一张(产品快门中位节奏,见 offline_sfm/make_feeds.py 的出处说明),相对网格点加确定性偏移
u ∈ [0, 100) ms(LCG);外加三张边界照片:首帧后 0.2 s(多半在初始化前)、末帧前 0.05 s、末帧后 0.3 s(收尾路径)。
时刻近似 = t_ns·1e-9 + 3 ms − 5 ms(照片时刻本来就是任意时刻,不需要与帧对齐)。"""
import os
SP = '/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/2359d42b-b338-4098-99ad-6a4c217067ad/scratchpad'
R = os.path.expanduser('~/Developer/viobench-recordings')
runs = {'13f5': 'run-13f53d2f-5935-4b1a-a499-4dc8367ea935', '6d18': 'run-6d187dff-403a-4882-b692-7bdc6c3cfa2a',
        '7353': 'run-73538ad6-8418-4eaf-8b75-a63c9d32af46'}
for sc, rn in runs.items():
    ts = [int(l.split(',')[0]) for l in list(open(f'{R}/{rn}/camera_index.csv'))[1:] if l.strip()]
    t0 = ts[0] * 1e-9 - 0.002; t1 = ts[-1] * 1e-9 - 0.002
    ph = []; seed = 12345; k = 0; g = t0 + 3.0
    while g < t1 - 0.3:
        seed = (1103515245 * seed + 12345) % (2 ** 31); u = (seed % 100000) / 1e6
        ph.append((k, g + u)); k += 1; g += 1.45
    ph += [(900, t0 + 0.2), (901, t1 - 0.05), (902, t1 + 0.3)]
    with open(f'{SP}/xrchain/photos/{sc}.txt', 'w') as f:
        for i, t in sorted(ph, key=lambda x: x[1]):
            f.write(f'{i} {t:.9f}\n')
    print(sc, len(ph))
