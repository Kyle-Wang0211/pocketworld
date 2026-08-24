#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
L2-T  加计 scale factor 的**温度滞回**量化
================================================================

背景 / 为什么要这一条
--------------------
既定解药是"离线 batch 标 IMU 内参"。韩文一手材料给它加了一条限定:

    「똑같은 +25℃라고 하더라도 가열 사이클일 때와 냉각 사이클일 때
      NULL 바이어스 출력이 약간 차이가 난다」
    —— 同一个 +25°C,升温路径和降温路径的零偏输出不同。

也就是说标定结果是**路径依赖**的,不是标一次用一辈子的常数。
叠加我们的场景:手机连续跑 VIO 必然升温、拍完停下必然降温,
**同一次采集的前后半段可能落在滞回曲线的两支上**。
这比 −160 ppm/°C 那条温漂更难办 —— 那条是单调的、可用一条曲线补;
这条不是单调的,同一个 T 有两个值。

本脚本要回答的**唯一**问题
--------------------------
    滞回幅度相对"尺度误差进 1%"这个目标,到底可不可忽略?
    —— 必须用数字回答,不许默认可忽略。

观测量的选择(这一段是本脚本最重要的设计决定)
-----------------------------------------------
椭球拟合给出校正矩阵 W,使 a_cal = W (a_raw - c)。
定义**误标定矩阵** S = W^{-1},即 a_raw - c = S · a_true。

不要拿 radii / diag(S) 逐轴比较:`np.linalg.eigh` 返回的特征值是**按大小排序**的,
不同 plateau 之间"第 1 轴"不保证是同一根物理轴,排序抖动会直接进噪声。
实测代价:用 radii[0] 代替 det^(1/3),ĥ 的标准误稳定放大 **~2.2×**
(10 seed × 3 种各向异性,见 negative_control 的 NC2)。不是灾难性的,
但白送 2× 精度没有道理,而且 det^(1/3) 在两种 regime 下都安全。

改用旋转不变的标量:

    g = det(S)^(1/3) - 1 = (r1·r2·r3)^(1/3) / G - 1

    · det(S)^(1/3) 是三个主轴 scale 的几何平均
    · 它正是决定**米制尺度**(长度/体积)整体缩放的那个量 —— 我们要管的就是它
    · 对特征分解顺序、对机体系定向完全免疫

滞回模型
--------
每个温度平台(plateau)给出一个 (T, branch, g)。拟合

    g(T, d) = g0 + k·(T - T_ref) + h·d          d = +1 升温支 / -1 降温支

    · k  = 单调温漂系数(记忆里那条 −160 ppm/°C 就是它)
    · h  = **滞回半幅**;环的全宽 = 2|h|  ← 本脚本的 headline
    · 用加权最小二乘拟合,权重来自每个 plateau 的刀切方差 ⇒ h 自带标准误

统计细节(不做会低估不确定度好几倍)
------------------------------------
每个 plateau 内的样本是**按姿态成簇**的(同一姿态几百个样本高度相关)。
① 按单样本重采样会把 σ_g 低估 ~500×(NC3 实测 0.0024% vs 1.20%),于是任何 h 都"显著"。
② 但按姿态**有放回**自举也不对:14 个姿态有放回抽样平均丢 37% 的方向,
   而丢方向正是椭球拟合病态的唯一来源 ⇒ σ_g 被**高估**几十倍(实测 1.70%,
   而平台间真实散布只有 ~0.003%,χ²/dof 塌到 0,h 永远测不出显著)。
③ 生产用的是**留一姿态刀切法**:每次只去掉 1 个方向,条件数几乎不变。
   σ_g 是否标定对,由 report 里的 χ²/dof 检验(≈1 才对)。

用法
----
    python3 thermal_hysteresis.py --selftest            # 正向对照(合成已知滞回→拟合)
    python3 thermal_hysteresis.py --negative-control    # 负向对照(破坏算法→必须变红)
    python3 thermal_hysteresis.py --make-synthetic OUT/ # 造一份合成 session,验证 I/O 全链路
    python3 thermal_hysteresis.py --imu imu.csv --segments seg.csv [--budget-pct 0.10]

输入格式
--------
  imu.csv      : t,ax,ay,az[,gx,gy,gz]        t = unix 秒(float)
  segments.csv : t_start,t_end,plateau_id,branch,temp_c,pose_id
                 branch ∈ {heat, cool}
                 每个 (plateau_id) 是一个恒温平台,内含 >=12 个不同 pose_id

⚠️ 解释器:本机默认 python3 (3.14) 的 numpy 装坏了(__init__.py 缺失,
   `import numpy` 退化成 namespace package)。用 /opt/homebrew/bin/python3.11。
"""
import os
import sys
import csv
import json
import math
import argparse
import numpy as np

# ---- 复用既有资产,不重写椭球拟合 -------------------------------------------
_HERE = os.path.dirname(os.path.abspath(__file__))
_SCALE_CALIB = os.path.abspath(os.path.join(_HERE, "..", "imu_scale_calib"))
if _SCALE_CALIB not in sys.path:
    sys.path.insert(0, _SCALE_CALIB)
try:
    from fit_accel_ellipsoid import fit_ellipsoid, coverage_score, G_NOMINAL  # noqa
except ImportError as e:                                                      # pragma: no cover
    raise SystemExit(
        f"无法 import 既有的 fit_accel_ellipsoid ({_SCALE_CALIB}): {e}\n"
        f"本脚本是它的扩展,不是替代品。"
    )

MIN_POSES_PER_PLATEAU = 12       # < 12 个朝向时 9 参数椭球拟合病态(selftest 里有实证)
BOOTSTRAP_DRAWS = 200


# =============================================================== 观测量 g

def scale_gm_from_radii(radii):
    """几何平均 scale - 1。旋转不变,不受特征值排序影响。"""
    r = np.asarray(radii, float)
    if np.any(r <= 0):
        return float("nan")
    return float(np.exp(np.log(r).mean()) / G_NOMINAL - 1.0)


def plateau_scale(acc, poses):
    """一个恒温平台 → (g, S矩阵, radii, center, coverage)。失败返回 None。"""
    try:
        center, W, radii, _ = fit_ellipsoid(acc)
    except (SystemExit, np.linalg.LinAlgError):
        return None
    if not np.all(np.isfinite(radii)) or np.any(radii <= 0):
        return None
    S = np.linalg.inv(W)
    cov, _, _ = coverage_score(acc)
    return dict(g=scale_gm_from_radii(radii), S=S, radii=np.asarray(radii, float),
                center=np.asarray(center, float), coverage=float(cov),
                n_pose=int(len(np.unique(poses))), n=len(acc))


def plateau_scale_jackknife(acc, poses):
    """留一姿态刀切法(delete-one-cluster jackknife)估计 σ_g。 ← 生产用的就是这个

    为什么不是 cluster bootstrap:
      有放回重采样 14 个姿态会平均丢掉 ~37% 的**方向**,而丢方向恰恰是
      9 参数椭球拟合病态的唯一原因 ⇒ 自举分布被少数病态抽样拖成重尾,
      σ_g 被高估几十倍(实测 1.70% vs 真实平台间散布 ~0.03%,χ²/dof≈0)。
      刀切法每次只去掉 1 个方向,条件数几乎不变,是这里正确的 cluster-robust 估计。
    σ_g 的标定性由 report 里的 χ²/dof 检验(≈1 才说明不确定度是对的)。
    """
    uniq = np.unique(poses)
    n = len(uniq)
    if n < 4:
        return float("nan"), 0
    gs = []
    for p in uniq:
        m = poses != p
        r = plateau_scale(acc[m], poses[m])
        if r is None or not np.isfinite(r["g"]):
            continue
        gs.append(r["g"])
    if len(gs) < n - 1:
        return float("nan"), len(gs)
    gs = np.asarray(gs, float)
    var = (len(gs) - 1) / len(gs) * float(((gs - gs.mean()) ** 2).sum())
    return float(math.sqrt(max(var, 0.0))), len(gs)


def plateau_scale_bootstrap(acc, poses, draws=BOOTSTRAP_DRAWS, seed=0):
    """按姿态整簇**有放回**重采样。只保留给负向对照做对比,生产不用(见上面的注释)。"""
    rng = np.random.default_rng(seed)
    uniq = np.unique(poses)
    idx_by_pose = {p: np.flatnonzero(poses == p) for p in uniq}
    gs = []
    for _ in range(draws):
        pick = rng.choice(uniq, size=len(uniq), replace=True)
        idx = np.concatenate([idx_by_pose[p] for p in pick])
        r = plateau_scale(acc[idx], poses[idx])
        if r is not None and np.isfinite(r["g"]):
            gs.append(r["g"])
    if len(gs) < 0.6 * draws:
        return float("nan"), len(gs)
    return float(np.std(gs, ddof=1)), len(gs)


# =========================================================== 滞回加权拟合

def fit_hysteresis(T, d, g, sigma=None, t_ref=None):
    """WLS 拟合 g = g0 + k (T - Tref) + h d,返回参数与标准误。

    返回 dict:g0,k,h(及各自 se),t_ref,dof,chi2_red,以及 h 的 z 值。
    """
    T = np.asarray(T, float); d = np.asarray(d, float); g = np.asarray(g, float)
    n = len(T)
    if t_ref is None:
        t_ref = float(T.mean())
    X = np.column_stack([np.ones(n), T - t_ref, d])
    if sigma is None or not np.all(np.isfinite(sigma)) or np.any(np.asarray(sigma) <= 0):
        w = np.ones(n)
        sig_known = False
    else:
        w = 1.0 / np.asarray(sigma, float) ** 2
        sig_known = True
    Wm = np.diag(w)
    XtW = X.T @ Wm
    N = XtW @ X
    if np.linalg.matrix_rank(N) < 3:
        raise ValueError("设计矩阵秩亏:两支中至少有一支缺失,或所有平台温度相同")
    Cov = np.linalg.inv(N)
    beta = Cov @ (XtW @ g)
    resid = g - X @ beta
    dof = n - 3
    chi2 = float(resid @ Wm @ resid)
    chi2_red = chi2 / dof if dof > 0 else float("nan")
    # sigma 未知时用残差方差标定协方差;已知时也做一次保守放大(chi2>1 才放大)
    if not sig_known:
        Cov = Cov * (chi2 / dof if dof > 0 else 1.0)
    elif dof > 0 and chi2_red > 1.0:
        Cov = Cov * chi2_red
    se = np.sqrt(np.diag(Cov))
    return dict(g0=float(beta[0]), k=float(beta[1]), h=float(beta[2]),
                se_g0=float(se[0]), se_k=float(se[1]), se_h=float(se[2]),
                t_ref=float(t_ref), n=n, dof=int(dof), chi2_red=float(chi2_red),
                z_h=float(beta[2] / se[2]) if se[2] > 0 else float("inf"),
                sigma_known=sig_known)


# ================================================================ 合成数据

POSE_DIRS_14 = None


def _pose_dirs(n_pose):
    """n_pose 个尽量均布的单位方向:6 个面 + 8 个角 + (可选) 12 个棱。"""
    faces = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    corners = [(x, y, z) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)]
    edges = [(x, y, 0) for x in (-1, 1) for y in (-1, 1)] + \
            [(x, 0, z) for x in (-1, 1) for z in (-1, 1)] + \
            [(0, y, z) for y in (-1, 1) for z in (-1, 1)]
    allv = faces + corners + edges
    v = np.asarray(allv[:n_pose], float)
    return v / np.linalg.norm(v, axis=1, keepdims=True)


def synth_session(g0=1.2e-3, k=-1.6e-4, h=3.0e-4, temps=(26, 31, 36, 41),
                  n_pose=14, n_per_pose=400, rate=100.0, noise=0.02,
                  bias0=np.array([0.05, -0.03, 0.08]), bias_k=2e-3,
                  bias_h=0.0, seed=7, aniso=(1.0, 0.9994, 1.0009)):
    """造一份带**已知滞回**的完整 session(IMU 表 + segments 表)。

    真值构造:
        每轴 scale s_i(T,d) = aniso_i * (1 + g0 + k(T-Tref) + h·d)
        ⇒ 几何平均 scale - 1 = g0 + k(T-Tref) + h·d + log-mean(aniso)  (aniso 取几何平均=1)
    """
    rng = np.random.default_rng(seed)
    aniso = np.asarray(aniso, float)
    aniso = aniso / np.exp(np.log(aniso).mean())          # 强制几何平均 = 1,不污染 g
    t_ref = float(np.mean(temps))
    dirs = _pose_dirs(n_pose)

    imu_rows, seg_rows = [], []
    t = 1_700_000_000.0
    plateau_id = 0
    # 升温支:温度递增;降温支:温度递减 —— 两支覆盖同一组温度
    schedule = [(T, +1) for T in temps] + [(T, -1) for T in reversed(temps)]
    for T, d in schedule:
        plateau_id += 1
        s_scalar = 1.0 + g0 + k * (T - t_ref) + h * d
        s_vec = aniso * s_scalar
        b_vec = bias0 + bias_k * (T - t_ref) + bias_h * d
        order = rng.permutation(n_pose)                    # 随机化姿态顺序(见 PROTOCOL.md)
        for pi in order:
            u = dirs[pi]
            for _ in range(n_per_pose):
                jitter = rng.normal(scale=0.004, size=3)   # 手持/支架微抖
                uu = u + jitter
                uu /= np.linalg.norm(uu)
                a = uu * G_NOMINAL * s_vec + b_vec + rng.normal(scale=noise, size=3)
                imu_rows.append((t, a[0], a[1], a[2]))
                t += 1.0 / rate
            seg_rows.append((imu_rows[-n_per_pose][0], imu_rows[-1][0],
                             plateau_id, "heat" if d > 0 else "cool", T, int(pi)))
        t += 5.0                                            # 平台之间的空隙
    return imu_rows, seg_rows, dict(g0=g0, k=k, h=h, t_ref=t_ref)


def write_session(outdir, imu_rows, seg_rows):
    os.makedirs(outdir, exist_ok=True)
    p_imu = os.path.join(outdir, "imu.csv")
    p_seg = os.path.join(outdir, "segments.csv")
    with open(p_imu, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["t", "ax", "ay", "az"])
        for r in imu_rows:
            w.writerow(["%.6f" % r[0], "%.6f" % r[1], "%.6f" % r[2], "%.6f" % r[3]])
    with open(p_seg, "w", newline="") as f:
        w = csv.writer(f); w.writerow(["t_start", "t_end", "plateau_id", "branch", "temp_c", "pose_id"])
        for r in seg_rows:
            w.writerow(["%.6f" % r[0], "%.6f" % r[1], r[2], r[3], "%.3f" % r[4], r[5]])
    return p_imu, p_seg


# ================================================================== 读取

def load_imu(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().lower() for h in rows[0]]
    start = 1
    try:
        [float(c) for c in rows[0][:4]]
        hdr = ["t", "ax", "ay", "az"]; start = 0
    except ValueError:
        pass
    ix = {n: hdr.index(n) for n in ("t", "ax", "ay", "az") if n in hdr}
    if len(ix) < 4:
        raise SystemExit(f"imu.csv 需要列 t,ax,ay,az;实际表头 = {rows[0]}")
    t, a = [], []
    for r in rows[start:]:
        try:
            t.append(float(r[ix["t"]]))
            a.append([float(r[ix["ax"]]), float(r[ix["ay"]]), float(r[ix["az"]])])
        except (ValueError, IndexError):
            continue
    return np.asarray(t, float), np.asarray(a, float)


def load_segments(path):
    out = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            try:
                out.append(dict(t_start=float(row["t_start"]), t_end=float(row["t_end"]),
                                plateau_id=int(row["plateau_id"]),
                                branch=row["branch"].strip().lower(),
                                temp_c=float(row["temp_c"]), pose_id=int(row["pose_id"])))
            except (ValueError, KeyError) as e:
                raise SystemExit(f"segments.csv 行解析失败 {row}: {e}")
    bad = {s["branch"] for s in out} - {"heat", "cool"}
    if bad:
        raise SystemExit(f"branch 只能是 heat / cool,发现: {bad}")
    return out


def group_plateaus(t, acc, segs, guard_s=1.5):
    """→ [ {plateau_id, branch, temp_c, acc, poses} ]

    guard_s: 每个姿态段**首尾各扣掉**这么多秒。两个原因,都必须扣:
      ① 手机时钟 vs Mac 时钟(templog.py 记时间戳的那台)哪怕都对了 NTP
         也可能差几百毫秒 —— 姿态段边界对不齐会把**换姿态时的手部运动**
         当成静止数据吃进椭球拟合;
      ② 刚放下时手机还在晃/支架还在回弹,需要沉降时间。
    默认 1.5 s ⇒ 姿态时长必须 ≥ 8 s 才剩得下有效样本(见 PROTOCOL.md)。
    """
    order = np.argsort(t)
    t = t[order]; acc = acc[order]
    by = {}
    for s in segs:
        t0, t1s = s["t_start"] + guard_s, s["t_end"] - guard_s
        if t1s <= t0:
            continue
        i0, i1 = np.searchsorted(t, t0, "left"), np.searchsorted(t, t1s, "right")
        if i1 <= i0:
            continue
        e = by.setdefault(s["plateau_id"], dict(plateau_id=s["plateau_id"], branch=s["branch"],
                                                temp_c=s["temp_c"], idx=[], poses=[]))
        e["idx"].append(np.arange(i0, i1))
        e["poses"].append(np.full(i1 - i0, s["pose_id"]))
    out = []
    for k in sorted(by):
        e = by[k]
        idx = np.concatenate(e["idx"]); poses = np.concatenate(e["poses"])
        out.append(dict(plateau_id=k, branch=e["branch"], temp_c=e["temp_c"],
                        acc=acc[idx], poses=poses))
    return out


# ================================================================== 分析

def analyze_session(plateaus, budget_pct=0.10, draws=BOOTSTRAP_DRAWS, quiet=False, seed=0):
    rows = []
    for i, p in enumerate(plateaus):
        r = plateau_scale(p["acc"], p["poses"])
        if r is None:
            if not quiet:
                print(f"  ⚠️ plateau {p['plateau_id']} 椭球拟合退化,已丢弃")
            continue
        sg, nok = plateau_scale_jackknife(p["acc"], p["poses"])
        rows.append(dict(plateau_id=p["plateau_id"], branch=p["branch"], temp_c=p["temp_c"],
                         g=r["g"], sigma_g=sg, coverage=r["coverage"], n_pose=r["n_pose"],
                         n=r["n"], jack_ok=nok))
    if len(rows) < 4:
        raise SystemExit(f"可用平台仅 {len(rows)} 个,拟合 3 个参数至少要 4 个平台")
    T = np.array([r["temp_c"] for r in rows])
    d = np.array([+1.0 if r["branch"] == "heat" else -1.0 for r in rows])
    g = np.array([r["g"] for r in rows])
    sg = np.array([r["sigma_g"] for r in rows])
    if len(set(d.tolist())) < 2:
        raise SystemExit("只有一支(全 heat 或全 cool),测不了滞回")
    fit = fit_hysteresis(T, d, g, sigma=sg if np.all(np.isfinite(sg)) else None)
    fit["loop_width_pct"] = abs(fit["h"]) * 2 * 100
    fit["se_loop_width_pct"] = fit["se_h"] * 2 * 100
    fit["k_ppm_per_C"] = fit["k"] * 1e6
    fit["se_k_ppm_per_C"] = fit["se_k"] * 1e6
    fit["median_sigma_g_pct"] = float(np.nanmedian(sg) * 100) if np.any(np.isfinite(sg)) else float("nan")
    fit["budget_pct"] = budget_pct
    return rows, fit


def verdict(fit):
    """三条独立判据。返回 dict,值域 {'negligible','not_negligible','undetermined'}。"""
    lw = fit["loop_width_pct"]
    se = fit["se_loop_width_pct"]
    v = {}
    # 判据 A:统计上是否与 0 可分(|z| > 3)
    v["significant"] = abs(fit["z_h"]) > 3.0
    # 判据 B:相对产品预算
    if lw + 2 * se < fit["budget_pct"]:
        v["vs_budget"] = "negligible"
    elif lw - 2 * se > fit["budget_pct"]:
        v["vs_budget"] = "not_negligible"
    else:
        v["vs_budget"] = "undetermined"
    # 判据 C:相对标定自身的可重复性(单平台 σ_g)。比 σ 还小 ⇒ 标了也分辨不出
    ms = fit["median_sigma_g_pct"]
    if np.isfinite(ms):
        v["vs_repeatability"] = "negligible" if lw < 2 * ms else "not_negligible"
    else:
        v["vs_repeatability"] = "undetermined"
    return v


def report(rows, fit, truth=None):
    print(f"\n{'=' * 74}\n  温度滞回拟合  g(T,d) = g0 + k·(T-{fit['t_ref']:.1f}) + h·d\n{'=' * 74}")
    print(f"  {'plat':>4} {'branch':>6} {'T(°C)':>7} {'g(%)':>10} {'σ_g(%)':>9} {'cov':>6} {'#pose':>6}")
    for r in sorted(rows, key=lambda x: x["plateau_id"]):
        print(f"  {r['plateau_id']:>4} {r['branch']:>6} {r['temp_c']:>7.2f} "
              f"{r['g'] * 100:>10.5f} {r['sigma_g'] * 100:>9.5f} "
              f"{r['coverage']:>6.2f} {r['n_pose']:>6}")
    print(f"\n  g0 (T_ref 处 scale 偏差) = {fit['g0'] * 100:+.5f} %   ± {fit['se_g0'] * 100:.5f}")
    print(f"  k  (单调温漂)            = {fit['k_ppm_per_C']:+.1f} ppm/°C ± {fit['se_k_ppm_per_C']:.1f}")
    print(f"      ↳ 记忆里那条参照是 −160 ppm/°C(MEMS scale factor 温漂典型值)")
    print(f"  h  (滞回半幅)            = {fit['h'] * 100:+.5f} %   ± {fit['se_h'] * 100:.5f}   z = {fit['z_h']:+.2f}")
    print(f"\n  ▶ 滞回环全宽 2|h| = {fit['loop_width_pct']:.5f} % ± {fit['se_loop_width_pct']:.5f} %   ← HEADLINE")
    print(f"    单平台可重复性 σ_g(中位) = {fit['median_sigma_g_pct']:.5f} %")
    print(f"    拟合 χ²/dof = {fit['chi2_red']:.2f}  (dof={fit['dof']}, σ 来源: "
          f"{'留一姿态刀切' if fit['sigma_known'] else '残差标定'})")

    v = verdict(fit)
    print(f"\n{'-' * 74}\n  判决(产品预算 = 尺度误差全环宽 < {fit['budget_pct']:.3f}%)")
    print(f"  A 统计显著性 : {'🔴 h 与 0 可分 (|z|>3)' if v['significant'] else '✅ h 与 0 不可分'}")
    lab = {"negligible": "✅ 可忽略", "not_negligible": "🔴 不可忽略", "undetermined": "⚠️ 未定(需更多平台/更低噪声)"}
    print(f"  B 对预算     : {lab[v['vs_budget']]}")
    print(f"  C 对可重复性 : {lab[v['vs_repeatability']]}  (全宽 vs 2σ_g)")
    print(f"\n  行动建议:")
    if v["vs_budget"] == "not_negligible":
        print("    · 单条标定曲线不够 ⇒ 必须标**两条**(升温支/降温支),")
        print("      运行时按 dT/dt 的符号选支;拿不到 dT/dt 时按最坏支取先验中心并放大先验方差。")
    elif v["vs_budget"] == "negligible":
        print("    · 一条标定曲线够用,滞回并入先验方差即可(见 bias_window.py 给出的窗口)。")
    else:
        print("    · 数据不足以判定。加平台数、加每平台姿态数,或降噪(更长静置)。")
    print('-' * 74)
    if truth:
        print(f"\n  [合成真值]  g0={truth['g0'] * 100:+.5f}%  k={truth['k'] * 1e6:+.1f}ppm/°C  "
              f"h={truth['h'] * 100:+.5f}%  (2|h|={abs(truth['h']) * 2 * 100:.5f}%)")


# ============================================================ 正向对照

def _run_case(name, draws=80, seed=7, **kw):
    imu, seg, truth = synth_session(seed=seed, **kw)
    t = np.array([r[0] for r in imu]); acc = np.array([[r[1], r[2], r[3]] for r in imu])
    segs = [dict(t_start=s[0], t_end=s[1], plateau_id=s[2], branch=s[3],
                 temp_c=s[4], pose_id=s[5]) for s in seg]
    pl = group_plateaus(t, acc, segs)
    rows, fit = analyze_session(pl, draws=draws, quiet=True)
    return rows, fit, truth


def selftest(verbose=True):
    """正向对照:合成**已知滞回** → 必须拟合出来。

    覆盖四种情形:
      1. h = 0            → 不能造出假阳性
      2. h = 3e-4 (0.03%) → 必须以 |z|>3 检出,且落在真值 ±3σ 内
      3. h = 3e-3 (0.30%) → 大滞回,必须判 not_negligible
      4. 只有 6 个姿态     → 椭球 9 参数病态,σ_g 必须显著变大(协议下限的实证)
    """
    ok = True
    print("=" * 74)
    print("  正向对照 —— 合成已知滞回 → 拟合 → 比对真值")
    print("=" * 74)

    # --- 1  零滞回:不许假阳性
    rows, fit, tr = _run_case("h=0", h=0.0, seed=11)
    good = abs(fit["z_h"]) < 3.0
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [h=0]      2|h|={fit['loop_width_pct']:.5f}% "
              f"z={fit['z_h']:+.2f}  期望 |z|<3(无假阳性)")

    # --- 2  小滞回:必须检出且数值对
    rows, fit, tr = _run_case("h=3e-4", h=3.0e-4, seed=12)
    det = abs(fit["z_h"]) > 3.0
    err = abs(fit["h"] - tr["h"])
    acc_ok = err < max(3 * fit["se_h"], 1.0e-4)
    good = det and acc_ok
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [h=3e-4]   ĥ={fit['h'] * 100:+.5f}% vs 真值 {tr['h'] * 100:+.5f}%  "
              f"|Δ|={err * 100:.5f}%  se={fit['se_h'] * 100:.5f}%  z={fit['z_h']:+.2f}")

    # --- 3  大滞回:必须判 not_negligible
    rows, fit, tr = _run_case("h=3e-3", h=3.0e-3, seed=13)
    v = verdict(fit)
    good = v["vs_budget"] == "not_negligible" and abs(fit["h"] - tr["h"]) < max(3 * fit["se_h"], 3e-4)
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [h=3e-3]   ĥ={fit['h'] * 100:+.5f}% vs 真值 {tr['h'] * 100:+.5f}%  "
              f"判决={v['vs_budget']}  期望 not_negligible")

    # --- 4  单调温漂系数也要拟合对
    rows, fit, tr = _run_case("k", h=1e-4, k=-3.0e-4, seed=14)
    good = abs(fit["k"] - tr["k"]) < max(3 * fit["se_k"], 3e-5)
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [k]        k̂={fit['k_ppm_per_C']:+.1f} vs 真值 "
              f"{tr['k'] * 1e6:+.1f} ppm/°C  se={fit['se_k_ppm_per_C']:.1f}")

    # --- 5  姿态数下限的实证:6 pose vs 14 pose 的 σ_g
    r6, f6, _ = _run_case("pose6", n_pose=6, h=3.0e-4, seed=15)
    r14, f14, _ = _run_case("pose14", n_pose=14, h=3.0e-4, seed=15)
    ratio = f6["median_sigma_g_pct"] / max(f14["median_sigma_g_pct"], 1e-12)
    good = ratio > 2.0
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [姿态下限] σ_g(6 pose)={f6['median_sigma_g_pct']:.5f}%  "
              f"σ_g(14 pose)={f14['median_sigma_g_pct']:.5f}%  倍数={ratio:.1f}×  期望 >2×")
        print(f"             ⇒ 协议里 MIN_POSES_PER_PLATEAU={MIN_POSES_PER_PLATEAU} 有实证,不是拍脑袋")

    print("\n  " + ("✅ 正向对照全过 —— 拟合器本身可信" if ok else
                    "❌ 正向对照未过 —— 不要用它下任何结论"))
    return 0 if ok else 1


# ============================================================ 负向对照

def negative_control(verbose=True):
    """负向对照:**故意破坏**算法,确认测试会变红。

    没有这一步,'测试通过'可能只是测试根本没在测东西。
    """
    print("=" * 74)
    print("  负向对照 —— 破坏算法,确认测试变红")
    print("=" * 74)
    allred = True

    imu, seg, truth = synth_session(h=3.0e-4, seed=21)
    t = np.array([r[0] for r in imu]); acc = np.array([[r[1], r[2], r[3]] for r in imu])
    segs = [dict(t_start=s[0], t_end=s[1], plateau_id=s[2], branch=s[3],
                 temp_c=s[4], pose_id=s[5]) for s in seg]
    pl = group_plateaus(t, acc, segs)

    # NC1: 打乱 branch 标签 —— 滞回项应当塌到 0
    rng = np.random.default_rng(3)
    pl_shuf = [dict(p) for p in pl]
    labs = [p["branch"] for p in pl_shuf]
    rng.shuffle(labs)
    for p, l in zip(pl_shuf, labs):
        p["branch"] = l
    try:
        _, f_shuf = analyze_session(pl_shuf, draws=80, quiet=True)
        red = abs(f_shuf["z_h"]) < 3.0
    except SystemExit:
        red = True
        f_shuf = dict(z_h=float("nan"), loop_width_pct=float("nan"))
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC1 打乱 branch 标签 → z={f_shuf['z_h']:+.2f}  "
              f"期望 |z|<3(滞回项塌掉)")

    # NC2: 把 g 换成**排序敏感**的"最小半轴" radii[0],代替旋转不变的 det^(1/3)。
    #  实测(10 seed × 3 种各向异性,见报告)ĥ 的标准误稳定放大 ~2.2×。
    #  ⚠️ 诚实标定过:单个 seed 的 |Δh| 有时并不变差(1.2–2.7× 随机),
    #     所以判据必须建在**多 seed 平均的 se** 上,不能建在单次误差上 ——
    #     否则这条负向对照本身就是不稳的。
    se_good, se_bad = [], []
    for sd in range(30, 40):
        imu_s, seg_s, _ = synth_session(h=3.0e-4, seed=sd)
        ts = np.array([r[0] for r in imu_s])
        accs = np.array([[r[1], r[2], r[3]] for r in imu_s])
        segs_s = [dict(t_start=s[0], t_end=s[1], plateau_id=s[2], branch=s[3],
                       temp_c=s[4], pose_id=s[5]) for s in seg_s]
        pls = group_plateaus(ts, accs, segs_s)
        Ts = np.array([p["temp_c"] for p in pls])
        ds = np.array([+1.0 if p["branch"] == "heat" else -1.0 for p in pls])
        gg, gb = [], []
        for p in pls:
            r = plateau_scale(p["acc"], p["poses"])
            gg.append(r["g"]); gb.append(float(r["radii"][0] / G_NOMINAL - 1.0))
        se_good.append(fit_hysteresis(Ts, ds, np.array(gg), sigma=None)["se_h"])
        se_bad.append(fit_hysteresis(Ts, ds, np.array(gb), sigma=None)["se_h"])
    ratio = float(np.mean(se_bad) / np.mean(se_good))
    red = ratio > 1.5
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC2 用排序敏感的 radii[0] 代替 det^(1/3) → "
              f"se(ĥ) 放大 {ratio:.1f}×  (10 seed 平均,期望 >1.5×)")

    # NC3: 用**单样本**自举代替 cluster 自举 → σ_g 必须被严重低估
    def sigma_iid(p, draws=80):
        rng2 = np.random.default_rng(5)
        gs = []
        n = len(p["acc"])
        for _ in range(draws):
            idx = rng2.integers(0, n, n)
            r = plateau_scale(p["acc"][idx], p["poses"][idx])
            if r:
                gs.append(r["g"])
        return float(np.std(gs, ddof=1)) if len(gs) > 10 else float("nan")
    s_cl, _ = plateau_scale_bootstrap(pl[0]["acc"], pl[0]["poses"], draws=80, seed=5)
    s_iid = sigma_iid(pl[0])
    red = np.isfinite(s_iid) and s_iid < 0.5 * s_cl
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC3 单样本自举 σ={s_iid * 100:.6f}% vs "
              f"cluster 自举 σ={s_cl * 100:.6f}%  期望前者被低估 >2×")

    # NC4: 直接破坏 fit_hysteresis —— 把 d 列常数化(等价于只采了一支),设计矩阵应当秩亏
    T4 = np.array([p["temp_c"] for p in pl])
    g4 = np.array([plateau_scale(p["acc"], p["poses"])["g"] for p in pl])
    try:
        fit_hysteresis(T4, np.ones_like(T4), g4, sigma=None)
        red = False
    except (ValueError, np.linalg.LinAlgError):
        red = True
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC4 branch 列常数化(只有单支)→ 期望抛秩亏错误")

    # NC5: 篡改 selftest 的判据本身 —— 把真值改错,正向对照必须失败
    rows, fit, tr = _run_case("tamper", h=3.0e-4, seed=12)
    fake_truth_h = 3.0e-3            # 故意把真值写错一个数量级
    would_pass = abs(fit["h"] - fake_truth_h) < max(3 * fit["se_h"], 1.0e-4)
    red = not would_pass
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC5 把真值篡改成 {fake_truth_h * 100:.3f}% → "
              f"正向对照的比对必须失败")

    print("\n  " + ("✅ 负向对照全部变红 —— 测试确实在测东西" if allred else
                    "❌ 有负向对照没变红 —— 测试是空的,结论不可信"))
    return 0 if allred else 1


# ==================================================================== CLI

def main():
    ap = argparse.ArgumentParser(description="加计 scale factor 温度滞回量化")
    ap.add_argument("--imu", help="imu.csv (t,ax,ay,az)")
    ap.add_argument("--segments", help="segments.csv")
    ap.add_argument("--budget-pct", type=float, default=0.10,
                    help="可忽略门槛:滞回环全宽的百分比上限(默认 0.10%%,见 README 的预算推导)")
    ap.add_argument("--draws", type=int, default=BOOTSTRAP_DRAWS)
    ap.add_argument("--time-offset", type=float, default=0.0,
                    help="segments.csv 的时间戳减去这个秒数后再和 imu.csv 对齐"
                         "(手机时钟 vs Mac 时钟的偏差,用同步敲击标定)")
    ap.add_argument("--guard", type=float, default=1.5,
                    help="每个姿态段首尾各扣掉的秒数(时钟偏差 + 沉降),默认 1.5")
    ap.add_argument("--json", help="结果写 JSON")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--negative-control", action="store_true")
    ap.add_argument("--make-synthetic", metavar="OUTDIR", help="生成一份合成 session 到目录")
    a = ap.parse_args()

    if a.make_synthetic:
        imu, seg, tr = synth_session()
        p1, p2 = write_session(a.make_synthetic, imu, seg)
        print(f"已写出 {p1}\n         {p2}\n真值: {tr}")
        return 0
    if a.negative_control:
        return negative_control()
    if a.selftest or not (a.imu and a.segments):
        return selftest()

    print("先跑正向 + 负向对照 —— 求解器有 bug 会被误读成 'IMU 路线不行'")
    if selftest() != 0 or negative_control() != 0:
        return 1
    t, acc = load_imu(a.imu)
    segs = load_segments(a.segments)
    if a.time_offset:
        for sg in segs:
            sg["t_start"] -= a.time_offset; sg["t_end"] -= a.time_offset
        print(f"  segments 时间戳整体平移 {-a.time_offset:+.3f}s")
    pl = group_plateaus(t, acc, segs, guard_s=a.guard)
    print(f"  护带 {a.guard}s/端;{len(pl)} 个平台")
    thin = [p["plateau_id"] for p in pl if len(np.unique(p["poses"])) < MIN_POSES_PER_PLATEAU]
    if thin:
        print(f"\n  ⚠️ 平台 {thin} 的姿态数 < {MIN_POSES_PER_PLATEAU},椭球拟合病态,结果不可信")
    rows, fit = analyze_session(pl, budget_pct=a.budget_pct, draws=a.draws)
    report(rows, fit)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(dict(plateaus=rows, fit=fit, verdict=verdict(fit)), f,
                      indent=2, ensure_ascii=False, default=float)
        print(f"\n结果已写入 {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
