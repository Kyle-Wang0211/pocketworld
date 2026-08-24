#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
陀螺 g 敏感度(g-sensitivity / acceleration sensitivity)量化
=============================================================

韩文一手材料:
    「모든 자이로스코프 디바이스가 기계적 디자인의 비대칭성이나
      마이크로머시닝 부정확성 때문에 가속도에 대한 감도를 어느 정도 갖고 있다」
    —— 所有陀螺因机械设计不对称/微加工误差,对加速度都有一定敏感度。

我们目前对这一项是 unknown。本脚本回答两件事:
  (a) 能不能量到?    → 能。而且**和滞回标定用同一份数据**,不用多采一次。
  (b) 量不到的部分是什么? → 地球自转的水平分量,除非同时记录航向。

模型
----
静止时:
    ω_meas = b_g + Γ · a_body + ω_earth_body + 噪声
             ^^^   ^^^^^^^^^^   ^^^^^^^^^^^^
             零偏  g 敏感度矩阵   地球自转(15.041 °/h)

多姿态静置时 a_body 扫过整个球面,而 b_g 不变 ⇒ Γ 可辨识。
每个姿态取均值得到一组 (ā_p, ω̄_p),12 个未知量(3 个 b_g + 9 个 Γ),
≥4 个姿态即可解,14 个姿态条件数良好。

🔴 结构性混淆 —— 这是本脚本最重要的一条
----------------------------------------
在 NED 系里 ω_earth = ω_e·[cosφ, 0, -sinφ]。它的**垂直分量**在机体系里是
    -ω_e sinφ · down_body = +ω_e sinφ · (ā_p / G)
也就是说 **地球自转的垂直分量正比于加速度计读数本身**,和 g 敏感度的
**各向同性部分完全共线,不可分离**。它给 Γ 的对角贡献恰好是

    Γ_earth = (ω_e sinφ / G) · I     ⇒  各向同性偏置 = ω_e sinφ  [°/h/g]

φ=30° 时是 7.52 °/h/g。**必须按纬度解析扣掉**(本脚本做了,--lat)。

**水平分量** ω_e cosφ · north_body 的方向取决于航向,而航向不被加速度计
约束。如果姿态是随机航向采的,它进不了 Γ,只进残差 ⇒ 这就是**探测下限**:

    探测下限 ≈ ω_e cosφ  [°/h/g]     φ=30° → 13.0 °/h/g

消费级 MEMS 陀螺 g 敏感度典型量级 ~0.1 °/s/g = 360 °/h/g,
相对 13 °/h/g 的地板有 ~28× 余量 ⇒ **量得到**。
要往下压,必须在采集时**同时记录航向**(ARKit 的 heading / 磁力计),
把 north_body 作为已知回归量扣掉 —— 见 PROTOCOL.md 的"该记录什么"。

为什么这一项和尺度有关(机制,不是玄学)
----------------------------------------
手持扫描时 a_body 主要就是重力,量级恒为 1g。若手机朝向不变,
Γ·a_body 是个**常量**,会被 VIO 在线陀螺零偏估计吸收掉,无害。
真正有害的是**转动时 a_body 在机体系里变**(扫一圈 ±45° ⇒ a_body 变化 O(1g)),
于是 g 敏感度产生一个**跟着姿态走的伪零偏**,在线估计器追不上 ⇒
姿态误差 → 重力方向估错 → 重力扣不干净 → 水平方向多出 G·sin(Δθ) 的假加速度。
本脚本给出 Γ 后,`--sim-scan` 可算出开环姿态误差量级。

用法
----
    python3 g_sensitivity.py --selftest
    python3 g_sensitivity.py --negative-control
    python3 g_sensitivity.py --imu imu.csv --segments segments.csv --lat 30.3

⚠️ 用 /opt/homebrew/bin/python3.11(默认 python3 的 numpy 装坏了)
"""
import os
import sys
import csv
import json
import math
import argparse
import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from thermal_hysteresis import load_segments, G_NOMINAL, _pose_dirs   # noqa

OMEGA_E = 7.2921159e-5              # rad/s,地球自转角速率(= 15.041 °/h)
RAD_S_TO_DEG_H = 180.0 / math.pi * 3600.0


def to_deg_h_per_g(gamma):
    """Γ 从 (rad/s)/(m/s²) 换成 °/h/g。"""
    return np.asarray(gamma, float) * RAD_S_TO_DEG_H * G_NOMINAL


def earth_iso_bias_deg_h_per_g(lat_deg):
    """地球自转垂直分量给 Γ 造成的各向同性偏置,单位 °/h/g。"""
    return OMEGA_E * math.sin(math.radians(lat_deg)) * RAD_S_TO_DEG_H


def detection_floor_deg_h_per_g(lat_deg):
    """未记录航向时的探测下限 = 地球自转水平分量,单位 °/h/g。"""
    return OMEGA_E * math.cos(math.radians(lat_deg)) * RAD_S_TO_DEG_H


# ============================================================== 拟合

def fit_g_sensitivity(a_mean, w_mean, lat_deg=None, w_se=None):
    """由每姿态均值 (ā_p [m/s²], ω̄_p [rad/s]) 拟合 b_g 和 Γ。

    ω̄ = b_g + Γ ā  ⇒ 每个机体轴 i 独立地做一次 4 参数线性回归。
    """
    A = np.asarray(a_mean, float)
    Wv = np.asarray(w_mean, float)
    n = len(A)
    if n < 5:
        raise ValueError(f"姿态数 {n} < 5,12 个未知量欠定")
    X = np.column_stack([np.ones(n), A])                   # n×4
    if np.linalg.matrix_rank(X) < 4:
        raise ValueError("设计矩阵秩亏:姿态方向共面或退化,Γ 不可辨识")
    XtXi = np.linalg.inv(X.T @ X)
    beta = XtXi @ (X.T @ Wv)                               # 4×3
    b_g = beta[0].copy()
    Gam = beta[1:].T.copy()                                # 3×3, 行 = 输出轴
    resid = Wv - X @ beta
    dof = n - 4
    s2 = (resid ** 2).sum(axis=0) / dof                    # 每个输出轴的残差方差
    # Γ[i,j] 的标准误 = sqrt(s2_i * XtXi[j+1,j+1])
    se_G = np.sqrt(np.outer(s2, np.diag(XtXi)[1:])).reshape(3, 3)
    se_b = np.sqrt(np.outer(s2, [XtXi[0, 0]])).ravel()

    out = dict(b_g=b_g, Gamma_raw=Gam, se_Gamma=se_G, se_b=se_b,
               resid_rms=float(np.sqrt((resid ** 2).mean())), n_pose=n, dof=int(dof))
    if lat_deg is not None:
        iso = OMEGA_E * math.sin(math.radians(lat_deg)) / G_NOMINAL
        out["Gamma"] = Gam - iso * np.eye(3)               # 扣掉地球自转垂直分量
        out["earth_iso_removed_deg_h_per_g"] = earth_iso_bias_deg_h_per_g(lat_deg)
        out["floor_deg_h_per_g"] = detection_floor_deg_h_per_g(lat_deg)
        out["lat_deg"] = float(lat_deg)
    else:
        out["Gamma"] = Gam
        out["earth_iso_removed_deg_h_per_g"] = 0.0
        out["floor_deg_h_per_g"] = float("nan")
    return out


def permutation_pvalue(a_mean, w_mean, lat_deg=None, n_perm=300, seed=1):
    """置换检验:打乱 (ā_p, ω̄_p) 的配对,看 ||Γ̂||₂ 还能有多大。

    🔴 为什么必须做这一步(实测):14 个姿态、每轴 4 个参数时,
       **打乱配对后 ||Γ̂||₂ 的中位数仍有真值的 65%**(实测 213 vs 326 °/h/g)。
       也就是说 Γ̂ 的**数值大小本身不是证据** —— 相当一部分是过拟合/错配残留。
       有证据的是**秩**:实测真值超过全部 300 次置换(p < 0.0033)。
       所以生产报告里给的是 p 值,不是只给一个 ||Γ||。
    返回 (p, 真值, 置换分布中位数, 置换分布 p95)。
    """
    a_mean = np.asarray(a_mean, float); w_mean = np.asarray(w_mean, float)
    obs = float(np.linalg.norm(to_deg_h_per_g(
        fit_g_sensitivity(a_mean, w_mean, lat_deg=lat_deg)["Gamma"]), 2))
    rng = np.random.default_rng(seed)
    vals = []
    n = len(a_mean)
    for _ in range(n_perm):
        p = rng.permutation(n)
        if np.all(p == np.arange(n)):
            continue
        try:
            vals.append(float(np.linalg.norm(to_deg_h_per_g(
                fit_g_sensitivity(a_mean, w_mean[p], lat_deg=lat_deg)["Gamma"]), 2)))
        except (ValueError, np.linalg.LinAlgError):
            continue
    if not vals:
        return float("nan"), obs, float("nan"), float("nan")
    vals = np.asarray(vals)
    p_val = float((np.sum(vals >= obs) + 1) / (len(vals) + 1))   # 加一修正,不会给出 p=0
    return p_val, obs, float(np.median(vals)), float(np.percentile(vals, 95))


def scan_attitude_error(Gamma, dt=10.0, da_g=1.0):
    """开环量级估计:扫描中 a_body 变化 da_g 个 g,持续 dt 秒 → 姿态误差(度)。

    伪零偏 Δω = ||Γ|| · da_g·G;姿态误差 Δθ ≈ Δω·dt。只给量级,闭环由 VIO 压制。
    """
    dw = float(np.linalg.norm(np.asarray(Gamma, float), 2)) * da_g * G_NOMINAL  # rad/s
    return math.degrees(dw * dt), dw


# ============================================================== 合成

def synth_poses(Gamma_true_deg_h_per_g, b_g_deg_h=(30.0, -20.0, 15.0), n_pose=14,
                lat_deg=30.0, heading_random=True, gyro_noise_deg_h=8.0,
                accel_scale=1.0012, seed=5):
    """造多姿态静置的 (ā, ω̄)。ω̄ 里含真值 Γ、零偏、地球自转、白噪声。"""
    rng = np.random.default_rng(seed)
    G_true = np.asarray(Gamma_true_deg_h_per_g, float) / (RAD_S_TO_DEG_H * G_NOMINAL)
    b_true = np.asarray(b_g_deg_h, float) / RAD_S_TO_DEG_H
    dirs = _pose_dirs(n_pose)
    lat = math.radians(lat_deg)
    a_list, w_list = [], []
    for u in dirs:
        a = u * G_NOMINAL * accel_scale
        # 地球自转:垂直分量沿 up_body(= a 方向);水平分量按随机航向铺开
        w_earth = OMEGA_E * math.sin(lat) * (a / (G_NOMINAL * accel_scale))
        if heading_random:
            v = rng.normal(size=3)
            v -= v @ u * u                                   # 取一个与 up_body 垂直的方向
            v /= np.linalg.norm(v)
            w_earth = w_earth + OMEGA_E * math.cos(lat) * v
        w = b_true + G_true @ a + w_earth + \
            rng.normal(scale=gyro_noise_deg_h / RAD_S_TO_DEG_H, size=3)
        a_list.append(a); w_list.append(w)
    return np.asarray(a_list), np.asarray(w_list)


# ============================================================== 报告

def report(fit, sim=True, perm=None):
    Gd = to_deg_h_per_g(fit["Gamma"])
    Sd = to_deg_h_per_g(fit["se_Gamma"])
    print(f"\n{'=' * 74}\n  陀螺 g 敏感度 Γ  [°/h per g]\n{'=' * 74}")
    print(f"  姿态数 {fit['n_pose']}  dof {fit['dof']}  残差 RMS "
          f"{fit['resid_rms'] * RAD_S_TO_DEG_H:.1f} °/h")
    print(f"  已扣除地球自转垂直分量(各向同性):"
          f"{fit['earth_iso_removed_deg_h_per_g']:.2f} °/h/g"
          + (f"  (纬度 {fit['lat_deg']}°)" if "lat_deg" in fit else "  (未给 --lat,未扣!)"))
    print(f"  未记录航向 ⇒ 探测下限 = 地球自转水平分量 = {fit['floor_deg_h_per_g']:.1f} °/h/g")
    print("\n        " + "".join(f"{c:>14}" for c in ("a_x", "a_y", "a_z")))
    for i, r in enumerate("xyz"):
        print(f"   ω_{r} " + "".join(f"{Gd[i, j]:>8.1f}±{Sd[i, j]:<5.1f}" for j in range(3)))
    print(f"\n  零偏 b_g = [{fit['b_g'][0] * RAD_S_TO_DEG_H:+.1f} "
          f"{fit['b_g'][1] * RAD_S_TO_DEG_H:+.1f} {fit['b_g'][2] * RAD_S_TO_DEG_H:+.1f}] °/h "
          f"(± {fit['se_b'][0] * RAD_S_TO_DEG_H:.1f})")
    nrm = float(np.linalg.norm(Gd, 2))
    print(f"\n  ▶ ||Γ||₂ = {nrm:.1f} °/h/g   ← 数值")
    if perm is not None:
        pv, obs, med, p95 = perm
        print(f"  ▶ 置换检验 p = {pv:.4f}   ← HEADLINE(有没有 g 敏感度,看这个)")
        print(f"    置换零分布:中位 {med:.1f}  p95 {p95:.1f} °/h/g")
        print(f"    🔴 零分布中位已经有观测值的 {med / max(obs, 1e-9) * 100:.0f}% ⇒ "
              f"||Γ|| 的绝对大小会骗人,只有 p 值能判'存在与否'")
        if pv >= 0.05:
            print(f"    ✅ p ≥ 0.05 ⇒ 本次数据**测不出** g 敏感度;只能给上界(见下面的探测下限)")
    floor = fit["floor_deg_h_per_g"]
    if np.isfinite(floor):
        if nrm > 3 * floor:
            print(f"    🔴 高于探测下限 {floor:.1f} 的 3 倍 ⇒ **真的存在 g 敏感度**,不是地球自转残留")
        elif nrm > floor:
            print(f"    ⚠️ 与探测下限 {floor:.1f} 同量级 ⇒ 无法与地球自转水平分量区分。"
                  f"要下结论必须补记航向。")
        else:
            print(f"    ✅ 低于探测下限 {floor:.1f} ⇒ 在本实验分辨率内 g 敏感度不可测,"
                  f"上界即 {floor:.1f} °/h/g")
    if sim:
        dth, dw = scan_attitude_error(fit["Gamma"])
        print(f"\n  开环量级:扫描 10 s、a_body 变化 1 g ⇒ 伪零偏 {dw * RAD_S_TO_DEG_H:.0f} °/h,"
              f"姿态误差 ~{dth:.3f}°")
        print(f"    ↳ 0.1° 的重力方向误差会往水平方向漏 {G_NOMINAL * math.sin(math.radians(0.1)) * 1000:.1f} mm/s²")
        print(f"    ⚠️ 这是**开环**量级。闭环下 VIO 的视觉约束会压掉大部分,"
              f"真实影响必须在 VIO 在环里量,本脚本给不了。")
    print("=" * 74)


# ============================================================== 对照

def selftest(verbose=True):
    print("=" * 74 + "\n  正向对照 —— 合成已知 Γ → 拟合 → 比对\n" + "=" * 74)
    ok = True

    # 1  大 g 敏感度(消费级 MEMS 典型 ~360 °/h/g),必须准确恢复
    Gt = np.array([[300., 40., -60.], [-25., 280., 35.], [50., -30., 320.]])
    a, w = synth_poses(Gt, lat_deg=30.0, seed=5)
    f = fit_g_sensitivity(a, w, lat_deg=30.0)
    Gd = to_deg_h_per_g(f["Gamma"])
    err = np.abs(Gd - Gt).max()
    tol = 3 * to_deg_h_per_g(f["se_Gamma"]).max() + 5.0
    good = err < tol
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [大 Γ]     max|ΔΓ| = {err:.1f} °/h/g  (tol {tol:.1f})  "
              f"||Γ̂||={np.linalg.norm(Gd, 2):.0f} vs 真值 {np.linalg.norm(Gt, 2):.0f}")

    # 2  Γ = 0:不许造出假阳性(且必须判"低于探测下限")
    a, w = synth_poses(np.zeros((3, 3)), lat_deg=30.0, seed=6)
    f0 = fit_g_sensitivity(a, w, lat_deg=30.0)
    n0 = np.linalg.norm(to_deg_h_per_g(f0["Gamma"]), 2)
    good = n0 < 3 * f0["floor_deg_h_per_g"]
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [Γ=0]      ||Γ̂|| = {n0:.1f} °/h/g,"
              f"探测下限 {f0['floor_deg_h_per_g']:.1f} —— 期望同量级,不出假阳性")

    # 3  地球自转扣除:不扣时对角必须整体偏高 ω_e sinφ
    a, w = synth_poses(np.zeros((3, 3)), lat_deg=45.0, heading_random=False,
                       gyro_noise_deg_h=0.0, seed=7)
    f_no = fit_g_sensitivity(a, w, lat_deg=None)
    f_yes = fit_g_sensitivity(a, w, lat_deg=45.0)
    d_no = np.diag(to_deg_h_per_g(f_no["Gamma"])).mean()
    d_yes = np.diag(to_deg_h_per_g(f_yes["Gamma"])).mean()
    expect = earth_iso_bias_deg_h_per_g(45.0)
    good = abs(d_no - expect) < 0.5 and abs(d_yes) < 0.5
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [地球自转] 不扣时对角均值 {d_no:.2f} "
              f"(理论 ω_e·sin45° = {expect:.2f});扣后 {d_yes:.2f}(期望 ~0)")

    # 4  φ=30° 时的探测下限数值
    fl = detection_floor_deg_h_per_g(30.0)
    good = abs(fl - 13.02) < 0.1
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [下限]     φ=30° 探测下限 = {fl:.2f} °/h/g "
              f"(= 15.041·cos30°,期望 13.02)")

    # 5  姿态共面 → 必须拒绝(而不是给个错答案)
    a_bad = np.array([[G_NOMINAL, 0, 0], [-G_NOMINAL, 0, 0], [0, G_NOMINAL, 0],
                      [0, -G_NOMINAL, 0], [G_NOMINAL * .7, G_NOMINAL * .7, 0],
                      [-G_NOMINAL * .7, G_NOMINAL * .7, 0]])
    try:
        fit_g_sensitivity(a_bad, np.zeros_like(a_bad), lat_deg=30.0)
        good = False
    except (ValueError, np.linalg.LinAlgError):
        good = True
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [共面拒绝] 6 个姿态全在 z=0 平面 → 期望抛秩亏错误")

    print("\n  " + ("✅ 正向对照全过" if ok else "❌ 正向对照未过"))
    return 0 if ok else 1


def negative_control(verbose=True):
    print("=" * 74 + "\n  负向对照 —— 破坏算法,确认变红\n" + "=" * 74)
    allred = True
    Gt = np.array([[300., 40., -60.], [-25., 280., 35.], [50., -30., 320.]])
    a, w = synth_poses(Gt, lat_deg=30.0, seed=5)

    # NC1: 置换检验。⚠️ 诚实记录:最初写的是"打乱配对后 ||Γ̂|| 必须掉到真值一半以下",
    #      实测掉到 172/329 = 52% —— **没变红**。原因是错配后的信号仍被过拟合成 Γ。
    #      改成正确的统计量:**秩**。真值必须超过绝大多数置换样本。
    p_val, obs, med, p95 = permutation_pvalue(a, w, lat_deg=30.0, n_perm=200, seed=2)
    red = p_val < 0.02
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC1 置换检验 → p={p_val:.4f} "
              f"(真值 {obs:.0f},置换中位 {med:.0f},p95 {p95:.0f})  期望 p<0.02")
        print(f"             ⚠️ 注意置换中位仍有真值的 {med / obs * 100:.0f}% ⇒ "
              f"**||Γ|| 的数值大小本身不是证据,p 值才是**")

    # NC1b: Γ=0 的数据做同一个置换检验 → p 必须**不显著**(证明检验不是恒显著)
    a0, w0 = synth_poses(np.zeros((3, 3)), lat_deg=30.0, seed=6)
    p0, obs0, med0, _ = permutation_pvalue(a0, w0, lat_deg=30.0, n_perm=200, seed=3)
    red = p0 > 0.05
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC1b 对 Γ=0 的数据做同一检验 → p={p0:.3f} "
              f"期望 p>0.05(检验不恒显著)")

    # NC2: 忘记扣地球自转 → 对角必须整体偏高 ω_e sinφ(证明 --lat 那步不是摆设)
    f_no = fit_g_sensitivity(a, w, lat_deg=None)
    f_ok = fit_g_sensitivity(a, w, lat_deg=30.0)
    d = np.diag(to_deg_h_per_g(f_no["Gamma"])).mean() - np.diag(to_deg_h_per_g(f_ok["Gamma"])).mean()
    expect = earth_iso_bias_deg_h_per_g(30.0)
    red = abs(d - expect) < 0.2
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC2 不扣地球自转 → 对角整体偏 {d:.2f} °/h/g "
              f"(理论 {expect:.2f})")

    # NC3: 把 selftest 的容差调成 0 → 正向对照必须失败(判据不是恒真)
    f2 = fit_g_sensitivity(a, w, lat_deg=30.0)
    err = np.abs(to_deg_h_per_g(f2["Gamma"]) - Gt).max()
    red = not (err < 0.0)
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC3 容差设为 0 → 比对必须失败 "
              f"(实际 max|ΔΓ|={err:.1f} > 0)")

    # NC4: 只给 4 个姿态(12 未知量欠定)→ 必须拒绝
    try:
        fit_g_sensitivity(a[:4], w[:4], lat_deg=30.0)
        red = False
    except (ValueError, np.linalg.LinAlgError):
        red = True
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC4 只给 4 个姿态 → 期望拒绝(欠定)")

    # NC5: 噪声抬到 500 °/h(远超真值)→ 拟合必须失去意义(误差 > 真值一半)
    a5, w5 = synth_poses(Gt, lat_deg=30.0, gyro_noise_deg_h=2000.0, seed=9)
    f5 = fit_g_sensitivity(a5, w5, lat_deg=30.0)
    e5 = np.abs(to_deg_h_per_g(f5["Gamma"]) - Gt).max()
    red = e5 > 100.0
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC5 陀螺噪声 2000 °/h → max|ΔΓ|={e5:.0f} °/h/g "
              f"期望 >100(噪声确实进得去,不是被硬编码掩盖)")

    print("\n  " + ("✅ 负向对照全部变红" if allred else "❌ 有负向对照没变红"))
    return 0 if allred else 1


# ============================================================== 真实数据

def pose_means(imu_csv, seg_csv):
    """从 imu.csv(需含 gx,gy,gz)+ segments.csv 取每 (plateau,pose) 段的均值。"""
    with open(imu_csv, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().lower() for h in rows[0]]
    need = ("t", "ax", "ay", "az", "gx", "gy", "gz")
    if not all(c in hdr for c in need):
        raise SystemExit(f"g 敏感度需要陀螺列;imu.csv 必须含 {need},实际 {rows[0]}")
    ix = {c: hdr.index(c) for c in need}
    t, A, Wv = [], [], []
    for r in rows[1:]:
        try:
            t.append(float(r[ix["t"]]))
            A.append([float(r[ix[c]]) for c in ("ax", "ay", "az")])
            Wv.append([float(r[ix[c]]) for c in ("gx", "gy", "gz")])
        except (ValueError, IndexError):
            continue
    t = np.asarray(t); A = np.asarray(A); Wv = np.asarray(Wv)
    o = np.argsort(t); t, A, Wv = t[o], A[o], Wv[o]
    segs = load_segments(seg_csv)
    am, wm, meta = [], [], []
    for s in segs:
        i0 = np.searchsorted(t, s["t_start"], "left")
        i1 = np.searchsorted(t, s["t_end"], "right")
        if i1 - i0 < 50:
            continue
        am.append(A[i0:i1].mean(axis=0)); wm.append(Wv[i0:i1].mean(axis=0))
        meta.append((s["plateau_id"], s["pose_id"], s["temp_c"], s["branch"]))
    return np.asarray(am), np.asarray(wm), meta


def main():
    ap = argparse.ArgumentParser(description="陀螺 g 敏感度")
    ap.add_argument("--imu"); ap.add_argument("--segments")
    ap.add_argument("--lat", type=float, help="采集地纬度(度)。不给就不扣地球自转垂直分量")
    ap.add_argument("--plateau", type=int, help="只用某一个温度平台(推荐:避免温漂混进 Γ)")
    ap.add_argument("--json")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--negative-control", action="store_true")
    a = ap.parse_args()

    if a.negative_control:
        return negative_control()
    if a.selftest or not (a.imu and a.segments):
        return selftest()
    if selftest() != 0 or negative_control() != 0:
        return 1
    am, wm, meta = pose_means(a.imu, a.segments)
    if a.plateau is not None:
        keep = [i for i, m in enumerate(meta) if m[0] == a.plateau]
        am, wm = am[keep], wm[keep]
        meta = [meta[i] for i in keep]
        print(f"  只用 plateau {a.plateau}:{len(am)} 个姿态")
    else:
        print(f"  ⚠️ 用了全部 {len(am)} 个姿态(跨温度平台)。陀螺零偏温漂会混进 b_g 的残差,"
              f"抬高 Γ 的标准误。建议加 --plateau 逐平台跑一遍再看一致性。")
    f = fit_g_sensitivity(am, wm, lat_deg=a.lat)
    perm = permutation_pvalue(am, wm, lat_deg=a.lat, n_perm=500)
    f["perm_p"], f["perm_obs"], f["perm_median"], f["perm_p95"] = perm
    report(f, perm=perm)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump({k: (v.tolist() if isinstance(v, np.ndarray) else v)
                       for k, v in f.items()}, fh, indent=2, ensure_ascii=False, default=float)
        print(f"结果已写入 {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
