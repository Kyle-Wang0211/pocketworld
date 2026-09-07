#!/usr/bin/env python3
"""自动拍验收尺(2026-09-07 未命名(22) 之后定):不看开火次数,看相邻照片的间距分布。

用法: python3 tool/autocapture_spacing_report.py <official_photo_bundle.json> [更多 bundle...]
输出每场:帧数、时长、相邻间隔 <1 s / <0.6 s 的对数、相邻旋转中位数、旋转 <5°/<3° 的对数、
相邻位移中位数、位移 <5 cm 的对数。对照口径:103 的 cap17 = rot 11.7° / 位移 20 cm / <5 cm 0 对;
104 的 cap22(全毁)= rot 9.2° / 12 cm / <5 cm 9 对、<1 s 16 对。
"""
import json, math, sys

def _mat(m):
    if isinstance(m, dict):
        m = m.get('m') or m.get('elements') or list(m.values())
    m = [float(x) for x in m]
    if len(m) == 16:  # column-major 4x4
        return [[m[0], m[4], m[8]], [m[1], m[5], m[9]], [m[2], m[6], m[10]]], (m[12], m[13], m[14])
    if len(m) == 12:  # row-major 3x4
        return [[m[0], m[1], m[2]], [m[4], m[5], m[6]], [m[8], m[9], m[10]]], (m[3], m[7], m[11])
    raise ValueError(len(m))

def _rot_deg(ra, rb):
    tr = sum(ra[i][j] * rb[i][j] for i in range(3) for j in range(3))
    return math.degrees(math.acos(max(-1.0, min(1.0, (tr - 1) / 2))))

def report(path):
    b = json.load(open(path))
    fr = sorted(b['frames'], key=lambda f: f['timestamp'])
    ts = [f['timestamp'] for f in fr]
    dts = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    rots, moves = [], []
    for i in range(len(fr) - 1):
        try:
            ra, pa = _mat(fr[i]['cameraTransform']); rb, pb = _mat(fr[i + 1]['cameraTransform'])
            rots.append(_rot_deg(ra, rb)); moves.append(math.dist(pa, pb))
        except Exception:
            pass
    med = lambda x: sorted(x)[len(x) // 2] if x else float('nan')
    print(f"{path.split('/')[-2] if '/' in path else path}: frames={len(fr)} span={ts[-1]-ts[0]:.1f}s "
          f"dt<1s={sum(x < 1 for x in dts)} dt<0.6s={sum(x < 0.6 for x in dts)} dt_med={med(dts):.2f}s | "
          f"rot_med={med(rots):.1f}° rot<5°={sum(r < 5 for r in rots)} rot<3°={sum(r < 3 for r in rots)} | "
          f"move_med={med(moves)*100:.1f}cm move<5cm={sum(m < 0.05 for m in moves)}")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    for p in sys.argv[1:]:
        report(p)
