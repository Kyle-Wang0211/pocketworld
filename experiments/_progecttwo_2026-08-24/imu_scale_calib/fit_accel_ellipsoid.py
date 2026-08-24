#!/usr/bin/env python3
"""
L2 静态加计标定 —— 椭球拟合求 scale factor / bias / 非正交

判据背景(为什么这个实验能判死整条 VIO 线):
  加速度计的**乘性 scale factor 偏置**是手机米制尺度误差的主因(ADVIO 点名),
  而它对 ARKit / XRSLAM / 自研离线求解器**完全共模** —— 大家读同一颗加速度计。
  关键区分:
    · bias(零偏)         → VIO 在线能估掉,不进最终尺度误差
    · scale factor(乘性) → **在线估不掉,离线 BA 也消不掉**,直接变成尺度的系统性偏差
  所以本脚本的 headline 是 max|s_i - 1|,不是 bias。

  已知参照:iPhone XR 加计 scale factor 误差 0.116%,三星 SM-A536V 0.66%
           MEMS scale factor 温漂 -160 ppm/°C(最大 -400)

原理:
  静止(或准静止)时加计只测重力,理想下所有姿态的读数落在半径 |g| 的球面上。
    scale factor 误差 → 球变椭球
    bias             → 椭球中心偏移
    非正交/misalign  → 椭球轴倾斜
  拟合一般二次曲面 x^T A x + 2 b^T x = 1,再分解出校正矩阵。

用法:
  python3 fit_accel_ellipsoid.py --selftest              # 先跑正向对照(必做)
  python3 fit_accel_ellipsoid.py data.csv                # 拟合真实数据
  python3 fit_accel_ellipsoid.py cold.csv --compare hot.csv --dtemp 12   # 冷热对比算温漂
  python3 fit_accel_ellipsoid.py data.csv --T 2.0        # 指定产品阈值 T(%),给出判决

只依赖 numpy。
"""
import sys, os, csv, math, argparse, json
import numpy as np

G_NOMINAL = 9.80665

# ---------------------------------------------------------------- CSV 读取

ACC_KEYS = [
    ("ax", "ay", "az"),
    ("accelerationx", "accelerationy", "accelerationz"),
    ("accelerometerx", "accelerometery", "accelerometerz"),
    ("accx", "accy", "accz"),
    ("x", "y", "z"),
]
GYR_HINT = ("gyro", "gyroscope", "angular", "wx", "rotationrate")


def _norm(s):
    return "".join(ch for ch in s.lower() if ch.isalnum())


def load_csv(path):
    """返回 (acc Nx3, gyr Nx3 或 None, t N 或 None)。自动识别常见 App 的列名。"""
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
        sample = f.read(8192); f.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        except Exception:
            dialect = csv.excel
        rows = list(csv.reader(f, dialect))
    if not rows:
        raise SystemExit(f"空文件: {path}")

    header, start = rows[0], 1
    try:                                   # 无表头的纯数字文件
        [float(c) for c in header[:3]]
        header, start = [f"c{i}" for i in range(len(rows[0]))], 0
    except ValueError:
        pass
    hn = [_norm(h) for h in header]

    def find_triplet(keys):
        for kx, ky, kz in keys:
            idx = []
            for k in (kx, ky, kz):
                hit = [i for i, h in enumerate(hn) if h == k] or \
                      [i for i, h in enumerate(hn) if h.endswith(k) and "gyro" not in h and "magnet" not in h]
                if not hit:
                    idx = []; break
                idx.append(hit[0])
            if len(idx) == 3:
                return idx
        return None

    ai = find_triplet(ACC_KEYS)
    if ai is None:                          # 兜底:取前三个非时间数值列
        num = [i for i, h in enumerate(hn) if "time" not in h and "t" != h]
        if len(num) < 3:
            raise SystemExit(f"无法识别加速度列,表头= {header}")
        ai = num[:3]
        print(f"[warn] 未识别列名,按位置取列 {ai}: {[header[i] for i in ai]}")

    gi = None
    gcols = [i for i, h in enumerate(hn) if any(k in h for k in GYR_HINT)]
    if len(gcols) >= 3:
        gi = gcols[:3]
    ti = next((i for i, h in enumerate(hn) if h.startswith("time") or h == "t"), None)

    acc, gyr, t = [], [], []
    for r in rows[start:]:
        try:
            acc.append([float(r[i]) for i in ai])
            if gi: gyr.append([float(r[i]) for i in gi])
            if ti is not None: t.append(float(r[ti]))
        except (ValueError, IndexError):
            continue
    acc = np.asarray(acc, float)
    if acc.shape[0] < 100:
        raise SystemExit(f"有效样本仅 {acc.shape[0]} 条,太少")
    return acc, (np.asarray(gyr, float) if gyr else None), (np.asarray(t, float) if t else None)


# ------------------------------------------------------------ 静止段筛选

def static_mask(acc, gyr=None, win=25, gyr_thr=0.05, acc_thr=0.35):
    """筛掉动态加速度污染的样本。有陀螺就用陀螺模长,否则用加速度模长的滑窗标准差。"""
    n = len(acc)
    if gyr is not None and len(gyr) == n:
        m = np.linalg.norm(gyr, axis=1) < gyr_thr
        if m.sum() > 200:
            return m, "陀螺模长 < %.3f rad/s" % gyr_thr
    mag = np.linalg.norm(acc, axis=1)
    k = max(5, min(win, n // 20))
    c = np.cumsum(np.insert(mag, 0, 0.0)); c2 = np.cumsum(np.insert(mag**2, 0, 0.0))
    s = (c[k:] - c[:-k]) / k
    s2 = (c2[k:] - c2[:-k]) / k
    sd = np.sqrt(np.maximum(s2 - s * s, 0.0))
    sd = np.concatenate([np.full(k - 1, sd[0]), sd])[:n]
    return sd < acc_thr, "|a| 滑窗标准差 < %.2f m/s²" % acc_thr


def coverage_score(acc):
    """姿态覆盖度:把单位化后的方向投到 26 个方向 bin,返回被覆盖的比例。
    覆盖不足时椭球拟合病态,scale factor 不可信。"""
    u = acc / np.linalg.norm(acc, axis=1, keepdims=True)
    dirs = []
    for x in (-1, 0, 1):
        for y in (-1, 0, 1):
            for z in (-1, 0, 1):
                if (x, y, z) != (0, 0, 0):
                    v = np.array([x, y, z], float); dirs.append(v / np.linalg.norm(v))
    dirs = np.asarray(dirs)
    hit = (u @ dirs.T).max(axis=0) > 0.9    # 每个 bin 是否有样本落在 ~25° 内
    return hit.mean(), int(hit.sum()), len(dirs)


# -------------------------------------------------------------- 椭球拟合

def fit_ellipsoid(acc):
    """拟合 x^T A x + 2 b^T x = 1,返回 (center, W, radii, R)。
    校正模型: a_cal = W @ (a_raw - center),使 |a_cal| ≈ G_NOMINAL"""
    x, y, z = acc[:, 0], acc[:, 1], acc[:, 2]
    D = np.column_stack([x*x, y*y, z*z, 2*x*y, 2*x*z, 2*y*z, 2*x, 2*y, 2*z])
    v, *_ = np.linalg.lstsq(D, np.ones(len(acc)), rcond=None)

    A = np.array([[v[0], v[3], v[4]],
                  [v[3], v[1], v[5]],
                  [v[4], v[5], v[2]]])
    bv = v[6:9]
    center = -np.linalg.solve(A, bv)
    # 平移到中心后的常数项
    const = 1.0 + center @ A @ center
    if const <= 0:
        raise SystemExit("拟合退化(常数项<=0):姿态覆盖不足或数据含大量动态段")
    Ac = A / const
    evals, evecs = np.linalg.eigh(Ac)
    if np.any(evals <= 0):
        raise SystemExit("拟合退化(非正定):姿态覆盖不足")
    radii = 1.0 / np.sqrt(evals)                     # 三个半轴长(m/s²)
    # 校正矩阵:把椭球映回半径 G 的球
    W = evecs @ np.diag(G_NOMINAL / radii) @ evecs.T
    return center, W, radii, evecs


def analyze(acc, label=""):
    m, how = static_mask(acc[:, :3], None)
    used = acc[m] if m.sum() > 300 else acc
    cov, hit, tot = coverage_score(used)
    center, W, radii, R = fit_ellipsoid(used)

    scale = radii / G_NOMINAL                        # 每个椭球主轴方向上的尺度因子
    s_err = np.abs(scale - 1.0)
    corrected = (used - center) @ W.T
    resid = np.linalg.norm(corrected, axis=1) - G_NOMINAL

    return dict(
        label=label, n_total=len(acc), n_used=int(m.sum()) if m.sum() > 300 else len(acc),
        static_rule=how, coverage=cov, cov_hit=hit, cov_tot=tot,
        center=center.tolist(), radii=radii.tolist(), scale=scale.tolist(),
        max_scale_err_pct=float(s_err.max() * 100),
        mean_scale_err_pct=float(s_err.mean() * 100),
        bias_norm=float(np.linalg.norm(center)),
        resid_rms=float(np.sqrt((resid**2).mean())),
        resid_rms_pct=float(np.sqrt((resid**2).mean()) / G_NOMINAL * 100),
        raw_mag_mean=float(np.linalg.norm(used, axis=1).mean()),
        W=W.tolist(),
    )


def report(r, T=None):
    print(f"\n{'='*66}\n  {r['label'] or '标定结果'}\n{'='*66}")
    print(f"  样本      : {r['n_used']} / {r['n_total']}  (静止判据: {r['static_rule']})")
    cov_flag = "✅" if r['coverage'] >= 0.65 else ("⚠️ 偏低" if r['coverage'] >= 0.4 else "❌ 不足")
    print(f"  姿态覆盖  : {r['coverage']*100:.0f}%  ({r['cov_hit']}/{r['cov_tot']} 方向)  {cov_flag}")
    print(f"  原始 |a|  : {r['raw_mag_mean']:.4f} m/s²   (标称 {G_NOMINAL})")
    print(f"\n  bias      : [{r['center'][0]:+.4f} {r['center'][1]:+.4f} {r['center'][2]:+.4f}]  |b| = {r['bias_norm']:.4f} m/s²")
    print(f"              ↳ VIO 在线可估掉,不进最终尺度误差")
    print(f"\n  半轴长    : [{r['radii'][0]:.4f} {r['radii'][1]:.4f} {r['radii'][2]:.4f}] m/s²")
    print(f"  scale     : [{r['scale'][0]:.6f} {r['scale'][1]:.6f} {r['scale'][2]:.6f}]")
    print(f"\n  ▶ max|s-1| = {r['max_scale_err_pct']:.4f}%   ← HEADLINE(在线估不掉,离线BA也消不掉)")
    print(f"    mean      = {r['mean_scale_err_pct']:.4f}%")
    print(f"  拟合残差  : {r['resid_rms']:.4f} m/s²  ({r['resid_rms_pct']:.3f}%)")

    if r['coverage'] < 0.4:
        print("\n  ❌ 姿态覆盖不足,scale factor 不可信 —— 重采:翻滚要慢且覆盖尽可能多的朝向")
    if r['resid_rms_pct'] > 0.5:
        print("  ⚠️  残差偏大,可能仍混有动态段或存在强非线性")

    if T is not None:
        half = 0.5 * T
        print(f"\n{'-'*66}\n  判据(产品阈值 T = {T}%,门槛 0.5T = {half}%)")
        if r['max_scale_err_pct'] >= half:
            print(f"  🔴 max|s-1| = {r['max_scale_err_pct']:.4f}% ≥ {half}%")
            print(f"     ⇒ 所有 IMU 路线被同一天花板卡死。ARKit / XRSLAM / 自研离线求解器")
            print(f"        读的是同一颗加速度计,这是共模误差。**VIO 路线判死**,")
            print(f"        除非先做 per-device 加计标定并在管线里应用校正矩阵 W。")
        else:
            print(f"  ✅ max|s-1| = {r['max_scale_err_pct']:.4f}% < {half}%")
            print(f"     ⇒ 加计不是瓶颈,可以继续 L3(离线 oracle 上界)。")
        print('-'*66)


# ---------------------------------------------------------- 正向对照(必做)

def selftest():
    """用已知 scale/bias 造合成数据,验证脚本本身没写错。
    调研明确强调:没有这一步,求解器的 bug 会被误读成'IMU 路线不行'。"""
    print("正向对照:合成已知椭球 → 拟合 → 比对")
    rng = np.random.default_rng(42)
    ok = True
    for true_s, true_b, noise in [
        (np.array([1.0000, 1.0000, 1.0000]), np.array([0.0, 0.0, 0.0]), 0.0),
        (np.array([1.0012, 0.9994, 1.0031]), np.array([0.05, -0.03, 0.08]), 0.0),
        (np.array([1.0012, 0.9994, 1.0031]), np.array([0.05, -0.03, 0.08]), 0.02),
        (np.array([1.0060, 0.9930, 1.0100]), np.array([-0.12, 0.09, 0.04]), 0.01),
    ]:
        u = rng.normal(size=(6000, 3)); u /= np.linalg.norm(u, axis=1, keepdims=True)
        meas = u * G_NOMINAL * true_s + true_b + rng.normal(scale=noise, size=(6000, 3))
        c, W, radii, _ = fit_ellipsoid(meas)
        got_s = np.sort(radii / G_NOMINAL); exp_s = np.sort(true_s)
        ds = np.abs(got_s - exp_s).max(); db = np.abs(c - true_b).max()
        tol_s = 3e-4 + noise * 2e-3; tol_b = 3e-3 + noise * 3e-2
        good = ds < tol_s and db < tol_b
        ok &= good
        print(f"  {'✅' if good else '❌'} noise={noise:<5} scale 最大偏差 {ds:.2e} (tol {tol_s:.1e}) | "
              f"bias 最大偏差 {db:.2e} (tol {tol_b:.1e})")
    print("\n  " + ("✅ 脚本自身正确,可以信任真实数据的结果" if ok
                    else "❌ 自检未通过,不要用它下任何结论"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description="L2 加计椭球标定")
    ap.add_argument("csv", nargs="?", help="加速度 CSV(phyphox / SensorLog / 通用 t,ax,ay,az)")
    ap.add_argument("--compare", help="第二份 CSV(热机后),用于算温漂")
    ap.add_argument("--dtemp", type=float, help="两次采集的温差(°C),给出 ppm/°C")
    ap.add_argument("--T", type=float, help="产品阈值 T(百分比),给出判决")
    ap.add_argument("--json", help="结果写入 JSON")
    ap.add_argument("--selftest", action="store_true", help="只跑正向对照")
    a = ap.parse_args()

    if a.selftest or not a.csv:
        return selftest()

    print("先跑正向对照 —— 求解器有 bug 会被误读成 'IMU 路线不行'")
    if selftest() != 0:
        return 1

    acc, gyr, _ = load_csv(a.csv)
    m, how = static_mask(acc, gyr)
    r1 = analyze(acc if m.sum() <= 300 else acc, os.path.basename(a.csv))
    report(r1, a.T)
    out = {"cold": r1}

    if a.compare:
        acc2, gyr2, _ = load_csv(a.compare)
        r2 = analyze(acc2, os.path.basename(a.compare))
        report(r2, a.T)
        out["hot"] = r2
        d = np.array(r2["scale"]) - np.array(r1["scale"])
        print(f"\n{'='*66}\n  温漂对比\n{'='*66}")
        print(f"  Δscale = [{d[0]:+.6f} {d[1]:+.6f} {d[2]:+.6f}]   max|Δ| = {np.abs(d).max()*100:.4f}%")
        if a.dtemp:
            ppm = np.abs(d).max() / a.dtemp * 1e6
            print(f"  ΔT = {a.dtemp}°C  ⇒  {ppm:.0f} ppm/°C")
            print(f"  参照:MEMS 加计 scale factor 温漂平均 -160 ppm/°C(最大 -400)")
            print(f"  ⚠️  零偏温漂会被 VIO 在线 bias 估计吸收,**scale factor 温漂不会**")
            out["ppm_per_C"] = float(ppm)
        else:
            print("  (给 --dtemp 可换算 ppm/°C)")

    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2, ensure_ascii=False)
        print(f"\n结果已写入 {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
