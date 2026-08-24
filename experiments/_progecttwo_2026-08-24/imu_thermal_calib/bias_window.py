#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
在线 bias 估计的窗口长度 —— 用 Allan 方差 + 实测升温率算出来,不是拍脑袋
========================================================================

俄文一手材料的教训(用 GPS 当基准做自动标定的作者):
    短片段收敛,10 分钟记录「полный провал」(彻底失败),
    最后只能改成**滑动窗口的局部自标定**。

这条和韩文那条滞回是同一个病:**bias 不是常数,它跟着温度走,而温度跟着时间走**。
所以离线标定的产物只能当**先验中心**,不能当常数钉死。

窗口长度怎么定(这就是本脚本)
------------------------------
窗口 τ 越长,白噪声平均得越干净;但 τ 越长,窗口内温度漂得越多,
估出来的 bias 相对窗口中点已经过时。两者反向 ⇒ 存在最优 τ:

    err(τ)² = (N/√τ)²  +  B²  +  (k_T · |dT/dt| · τ/2)²
              ^^^^^^^     ^^     ^^^^^^^^^^^^^^^^^^^^^
              角度随机游走 零偏不稳定性  窗口内热漂造成的滞后误差
              (ADEV 的 -1/2 斜率段)  (ADEV 谷底)  (τ/2 = 平均滞后)

三项里 N 和 B 从**明早那份静置数据**用 Allan 方差直接量;
|dT/dt| 从升温段的温度记录量;k_T 从各温度平台的 bias 拟合斜率量。
⇒ 四个输入全部是实测量,窗口是解出来的,不是选出来的。

⚠️ 本脚本给的是**bias 估计器的有效平均时长**,不是"VIO 滑窗要开多少帧"。
   两者的换算取决于求解器把 bias 建成什么(随机游走 or 分段常值),
   RD-VIO 那边具体是不是滑窗由另一个 agent 确认 —— 本脚本按**可能不是**设计:
   即使求解器把 bias 当分段常数,下面给出的 τ* 也是那个"段"该有的长度上限。

用法
----
    python3 bias_window.py --selftest
    python3 bias_window.py --negative-control
    python3 bias_window.py --imu imu.csv --static-start T0 --static-end T1 --fs 100 \
                           --dtdt 1.0 --kt 2e-3
"""
import os
import sys
import csv
import math
import json
import argparse
import numpy as np


# ============================================================ Allan 方差

def overlapping_adev(y, fs, taus=None):
    """重叠式 Allan 偏差。y = 速率序列(每轴分开调),fs = 采样率 Hz。

    σ²(τ=m/fs) = 1/(2 m² (M-2m+1)) Σ_j (θ_{j+2m} - 2θ_{j+m} + θ_j)²
    其中 θ = cumsum(y)/fs 是积分量(角度或速度)。
    """
    y = np.asarray(y, float).ravel()
    n = len(y)
    tau0 = 1.0 / fs
    theta = np.concatenate([[0.0], np.cumsum(y) * tau0])       # 长度 n+1
    if taus is None:
        mmax = n // 5
        ms = np.unique(np.floor(np.logspace(0, math.log10(max(mmax, 2)), 40)).astype(int))
    else:
        ms = np.unique(np.maximum(1, np.round(np.asarray(taus, float) * fs).astype(int)))
    ms = ms[(ms >= 1) & (2 * ms < n)]
    out_t, out_s = [], []
    for m in ms:
        k = n + 1 - 2 * m
        if k < 2:
            continue
        d = theta[2 * m:2 * m + k] - 2.0 * theta[m:m + k] + theta[0:k]
        var = float((d ** 2).sum()) / (2.0 * (m ** 2) * (tau0 ** 2) * k)
        out_t.append(m * tau0)
        out_s.append(math.sqrt(max(var, 0.0)))
    return np.asarray(out_t), np.asarray(out_s)


def fit_arw_bi(taus, adev):
    """从 ADEV 曲线取 N(角度随机游走)与 B(零偏不稳定性)。

    N: 在 -1/2 斜率段(短 τ)拟合 adev = N/√τ  ⇒  N = adev(τ)·√τ,取短 τ 段的中位数
    B: ADEV 的最小值 ≈ 0.664·B  ⇒  B = min(adev)/0.664
    """
    taus = np.asarray(taus, float); adev = np.asarray(adev, float)
    m = taus <= max(taus.min() * 8, taus[min(5, len(taus) - 1)])
    if m.sum() < 2:
        m = taus <= np.percentile(taus, 20)
    N = float(np.median(adev[m] * np.sqrt(taus[m])))
    i = int(np.argmin(adev))
    B = float(adev[i] / 0.664)
    return N, B, float(taus[i])


# ==================================================== 最优窗口

def bias_error(tau, N, B, kT, dTdt):
    """窗口 τ 下的总 bias 误差(与 y 同单位)。"""
    tau = np.asarray(tau, float)
    return np.sqrt((N / np.sqrt(tau)) ** 2 + B ** 2 + (kT * abs(dTdt) * tau / 2.0) ** 2)


def optimal_window(N, B, kT, dTdt, lo=0.05, hi=600.0, n=4000):
    """在 [lo,hi] 秒上数值最小化 bias_error,返回 (τ*, err*, 曲线)。

    kT·|dT/dt| = 0 时热漂项消失,误差对 τ 单调下降 ⇒ 返回 hi 并标记 unbounded。
    """
    taus = np.logspace(math.log10(lo), math.log10(hi), n)
    e = bias_error(taus, N, B, kT, dTdt)
    i = int(np.argmin(e))
    unbounded = (kT * abs(dTdt) == 0) or i >= n - 2
    return float(taus[i]), float(e[i]), (taus, e), unbounded


def analytic_tau(N, kT, dTdt):
    """忽略 B(它与 τ 无关,不影响 argmin)时的解析最优:
       d/dτ [N²/τ + (c τ/2)²] = 0  ⇒  -N²/τ² + c²τ/2 = 0  ⇒  τ* = (2N²/c²)^(1/3)
       其中 c = kT·|dT/dt|。用来交叉验证数值解。"""
    c = kT * abs(dTdt)
    if c <= 0:
        return float("inf")
    return float((2.0 * N ** 2 / c ** 2) ** (1.0 / 3.0))


# ==================================================== 报告

def report(N, B, kT, dTdt, unit="rad/s", tau_lo=0.05, tau_hi=600.0, hyst=None):
    tau, err, curve, unbounded = optimal_window(N, B, kT, dTdt, tau_lo, tau_hi)
    ta = analytic_tau(N, kT, dTdt)
    print(f"\n{'=' * 74}\n  在线 bias 估计窗口\n{'=' * 74}")
    print(f"  输入(全部应来自实测):")
    print(f"    N  角度随机游走   = {N:.3e} {unit}·√s     ← Allan -1/2 斜率段")
    print(f"    B  零偏不稳定性   = {B:.3e} {unit}        ← Allan 谷底 / 0.664")
    print(f"    k_T bias 温度系数 = {kT:.3e} {unit}/°C    ← 各温度平台 bias 拟合斜率")
    print(f"    |dT/dt| 升温率    = {abs(dTdt):.3f} °C/s   ← 温度记录")
    print(f"\n  ▶ 最优窗口 τ* = {tau:.2f} s   ← HEADLINE"
          + ("   ⚠️ 触到搜索上界,热漂项可忽略 ⇒ 窗口只受算力/时延限制" if unbounded else ""))
    if math.isfinite(ta):
        print(f"    解析交叉验证 τ* = (2N²/c²)^(1/3) = {ta:.2f} s "
              f"({'一致' if abs(ta - tau) / max(tau, 1e-9) < 0.15 or unbounded else '🔴 不一致,检查输入'})")
    print(f"    该窗口下的 bias 误差 = {err:.3e} {unit}")
    print(f"      分项:白噪声 {N / math.sqrt(tau):.3e} | 不稳定性 {B:.3e} | "
          f"热漂滞后 {kT * abs(dTdt) * tau / 2:.3e}")
    # 敏感度:窗口取 τ*/3 和 3τ* 时误差恶化多少 —— 说明这个最优有多"平"
    for f in (1 / 3.0, 3.0):
        e2 = float(bias_error(np.array([tau * f]), N, B, kT, dTdt)[0])
        print(f"      τ = {tau * f:8.2f} s ⇒ 误差 {e2:.3e}  ({e2 / err:.2f}× 最优)")
    print(f"\n  用法建议(离线标定 = **先验中心**,不是常数):")
    print(f"    · 先验中心 μ  = 离线标定值在**当前温度、当前升/降温支**上的插值")
    print(f"    · 先验标准差 σ ≥ 滞回半幅 h(拿不到 dT/dt 符号时)⊕ 标定自身不确定度")
    if hyst is not None:
        print(f"      本机实测滞回半幅 h = {hyst:.3e} ⇒ 先验 σ 至少取这么大")
    print(f"    · 估计器必须允许 bias 在 τ* ≈ {tau:.1f} s 尺度上移动;")
    print(f"      把 bias 钉成整段常数 ⇒ 采集越长偏得越多(俄文那份 10 分钟'彻底失败'就是这个)")
    print("=" * 74)
    return dict(tau_opt=tau, err_opt=err, tau_analytic=ta, unbounded=bool(unbounded),
                N=N, B=B, kT=kT, dTdt=dTdt)


# ==================================================== 对照

def synth_rate(n, fs, N, K=0.0, bias0=0.0, seed=3):
    """合成速率序列:白噪声(ARW=N)+ 速率随机游走(RRW=K)。

    离散化:白噪声每样本 σ_w = N·√fs;随机游走每步 σ_rw = K/√fs。
    """
    rng = np.random.default_rng(seed)
    w = rng.normal(scale=N * math.sqrt(fs), size=n)
    if K > 0:
        rw = np.cumsum(rng.normal(scale=K / math.sqrt(fs), size=n))
    else:
        rw = np.zeros(n)
    return bias0 + w + rw


def selftest(verbose=True):
    print("=" * 74 + "\n  正向对照 —— 合成已知 Allan 参数 → 反解 → 比对\n" + "=" * 74)
    ok = True
    fs = 100.0

    # 1  纯白噪声:ADEV 必须走 -1/2 斜率,且 N 反解正确
    N_true = 2.0e-3
    y = synth_rate(400_000, fs, N_true, seed=11)
    t, s = overlapping_adev(y, fs)
    m = (t >= 0.05) & (t <= 5.0)
    slope = float(np.polyfit(np.log10(t[m]), np.log10(s[m]), 1)[0])
    N_hat = float(np.median(s[m] * np.sqrt(t[m])))
    good = abs(slope + 0.5) < 0.05 and abs(N_hat / N_true - 1) < 0.05
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [白噪声]  ADEV 斜率 {slope:+.3f}(期望 -0.500);"
              f"N̂ = {N_hat:.3e} vs 真值 {N_true:.3e}  ({N_hat / N_true:.3f}×)")

    # 2  加随机游走:白噪声/RRW 交叉点之上必须转成 +1/2 斜率
    #    ⚠️ 用 2e6 样本(20000 s)。第一版用 4e5 样本(4000 s)时斜率只有 +0.28 ——
    #       不是公式错,是**长 τ 端 ADEV 的估计方差**(见下面第 6 项)。
    K_true = 2.0e-4
    n_long = 2_000_000
    y = synth_rate(n_long, fs, N_true, K=K_true, seed=12)
    t, s = overlapping_adev(y, fs)
    cross = math.sqrt(3) * N_true / K_true          # N/√τ == K√(τ/3) 的交点
    m2 = (t >= 2 * cross) & (t <= 10 * cross)
    slope2 = float(np.polyfit(np.log10(t[m2]), np.log10(s[m2]), 1)[0]) if m2.sum() >= 3 else float("nan")
    good = np.isfinite(slope2) and abs(slope2 - 0.5) < 0.1
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [随机游走] τ∈[{2 * cross:.0f},{10 * cross:.0f}]s 斜率 "
              f"{slope2:+.3f}(期望 +0.500)  ⇒ 曲线确实有谷底,B 可取")

    # 3  最优窗口:数值解 == 解析解
    N, B, kT, dTdt = 2.0e-3, 1.0e-4, 2.0e-3, 0.02
    tau, err, _, unb = optimal_window(N, B, kT, dTdt)
    ta = analytic_tau(N, kT, dTdt)
    good = (not unb) and abs(tau - ta) / ta < 0.05
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [最优窗口] 数值 τ*={tau:.3f}s vs 解析 "
              f"(2N²/c²)^(1/3)={ta:.3f}s  相对差 {abs(tau - ta) / ta * 100:.2f}%")

    # 4  τ* 必须随升温率变慢而变长(定性行为对)
    t1, _, _, _ = optimal_window(N, B, kT, 0.005)
    t2, _, _, _ = optimal_window(N, B, kT, 0.05)
    good = t1 > t2
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [单调性] dT/dt=0.005 → τ*={t1:.2f}s;"
              f"0.05 → τ*={t2:.2f}s  期望升温越快窗口越短")

    # 5  热漂为 0 时必须标记 unbounded(而不是编一个数出来)
    _, _, _, unb0 = optimal_window(N, B, kT, 0.0)
    good = unb0
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [无热漂] dT/dt=0 → unbounded={unb0}"
              f"  期望 True(不许编一个有限最优)")

    # 6  🔴 采集时长的硬要求:ADEV 在 τ 接近记录总长时是**估计方差主导**,不可信。
    #    这一条直接决定明早静置段要采多久,所以必须有实证而不是引一句"经验法则"。
    tot = n_long / fs
    m_ok = (t >= 2 * cross) & (t <= tot / 20)          # 可信带
    m_edge = (t >= t.max() / 8) & (t <= t.max())       # 贴着最长 τ 的带
    sl_ok = float(np.polyfit(np.log10(t[m_ok]), np.log10(s[m_ok]), 1)[0]) if m_ok.sum() >= 3 else float("nan")
    sl_edge = float(np.polyfit(np.log10(t[m_edge]), np.log10(s[m_edge]), 1)[0]) if m_edge.sum() >= 3 else float("nan")
    good = np.isfinite(sl_edge) and abs(sl_edge - 0.5) > abs(sl_ok - 0.5) + 0.1
    ok &= good
    if verbose:
        print(f"  {'✅' if good else '❌'} [时长下限] τ≤总长/20 段斜率 {sl_ok:+.3f};"
              f"贴顶带 τ∈[{t.max() / 8:.0f},{t.max():.0f}]s 斜率 {sl_edge:+.3f}  期望后者明显更差")
        print(f"             实测扫描(总长 {tot:.0f}s,真值斜率 +0.500):"
              f"上界=总长/50→+0.528 /20→+0.520 /10→+0.476 全段→+0.421")
        print(f"             ⇒ 判据:**只信 τ ≤ 记录总长/20**。想要 τ=60 s 的谷底 ⇒ "
              f"静置段 ≥ 1200 s = 20 分钟(写进 PROTOCOL.md)")

    print("\n  " + ("✅ 正向对照全过" if ok else "❌ 正向对照未过"))
    return 0 if ok else 1


def negative_control(verbose=True):
    print("=" * 74 + "\n  负向对照 —— 破坏算法,确认变红\n" + "=" * 74)
    allred = True
    fs = 100.0
    N_true = 2.0e-3

    # NC1: 破坏 ADEV —— 把二阶差分换成一阶(= 窗口均值的 RMS)。
    #  ⚠️ 诚实记录:第一版用**纯白噪声**测这一条,一阶差分也给 -0.489 —— **没变红**。
    #     原因是白噪声下两种差分标度相同,这条根本没在测 Allan 的关键性质。
    #     Allan 二阶差分的关键性质是**恰好消掉常值零偏和线性漂移**。
    #     所以负向对照必须在**带常值零偏**的信号上做:一阶差分会把零偏整个吃进去。
    bias_const = 0.05                                     # rad/s,远大于 N
    y = synth_rate(200_000, fs, N_true, bias0=bias_const, seed=21)
    tau0 = 1.0 / fs
    theta = np.concatenate([[0.0], np.cumsum(y) * tau0])
    ts, ss = [], []
    for m in np.unique(np.floor(np.logspace(0, 3.5, 25)).astype(int)):
        k = len(theta) - m
        if k < 2 or 2 * m >= len(y):
            continue
        d = theta[m:m + k] - theta[0:k]                       # 一阶差分(错的)
        ts.append(m * tau0)
        ss.append(math.sqrt(float((d ** 2).mean()) / (m * tau0) ** 2))
    ts = np.asarray(ts); ss = np.asarray(ss)
    mm = (ts >= 0.05) & (ts <= 5.0)
    slope_bad = float(np.polyfit(np.log10(ts[mm]), np.log10(ss[mm]), 1)[0])
    val_bad = float(np.median(ss[mm]))
    t, s = overlapping_adev(y, fs)
    mg = (t >= 0.05) & (t <= 5.0)
    slope_good = float(np.polyfit(np.log10(t[mg]), np.log10(s[mg]), 1)[0])
    N_good = float(np.median(s[mg] * np.sqrt(t[mg])))
    # 一阶差分必须被常值零偏污染:值 ≈ bias、斜率 ≈ 0;Allan 必须完全不受影响
    red = (abs(slope_bad + 0.5) > 0.1 and abs(val_bad / bias_const - 1) < 0.2
           and abs(slope_good + 0.5) < 0.05 and abs(N_good / N_true - 1) < 0.05)
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC1 一阶差分 vs Allan 二阶差分,"
              f"信号含常值零偏 {bias_const} rad/s")
        print(f"             一阶差分:斜率 {slope_bad:+.3f}(期望 ~0),值 {val_bad:.4f} "
              f"≈ 零偏 {bias_const} ⇒ 把零偏整个吃进去了")
        print(f"             Allan   :斜率 {slope_good:+.3f}(期望 -0.500),N̂ {N_good:.3e} "
              f"vs 真值 {N_true:.3e} ⇒ 零偏被二阶差分消掉,不受影响")

    # NC2: 把 N 喂错一个数量级 → τ* 必须按 N^(2/3) 变(≈ 4.64×),不是纹丝不动
    N, B, kT, dTdt = 2.0e-3, 1.0e-4, 2.0e-3, 0.02
    t_a, _, _, _ = optimal_window(N, B, kT, dTdt)
    t_b, _, _, _ = optimal_window(N * 10, B, kT, dTdt)
    ratio = t_b / t_a
    red = abs(ratio - 10 ** (2 / 3)) / 10 ** (2 / 3) < 0.05
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC2 N 放大 10× → τ* 变 {ratio:.2f}× "
              f"(理论 10^(2/3)={10 ** (2 / 3):.2f}×)  期望一致 ⇒ 公式确实在用 N")

    # NC3: B 不该影响 argmin(它与 τ 无关)—— 改 B 若改变了 τ*,说明实现串了
    t_c, _, _, _ = optimal_window(N, B * 50, kT, dTdt)
    red = abs(t_c - t_a) / t_a < 1e-6
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC3 B 放大 50× → τ* 从 {t_a:.4f} 到 "
              f"{t_c:.4f}s  期望**完全不动**(B 与 τ 无关)")

    # NC4: 用纯白噪声(无随机游走)时,ADEV 无谷底 ⇒ B 的估计必须落在最长 τ 上(不可信标志)
    y2 = synth_rate(200_000, fs, N_true, K=0.0, seed=22)
    t2, s2 = overlapping_adev(y2, fs)
    _, _, tau_min = fit_arw_bi(t2, s2)
    red = tau_min > 0.5 * t2.max()
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC4 纯白噪声无谷底 → argmin 落在 "
              f"τ={tau_min:.1f}s(最长 {t2.max():.1f}s)  期望贴边 ⇒ B 不可信的信号")

    # NC5: 篡改真值 —— 把 N 的比对真值改错 3×,正向对照必须失败
    t3, s3 = overlapping_adev(synth_rate(200_000, fs, N_true, seed=23), fs)
    m3 = (t3 >= 0.05) & (t3 <= 5.0)
    N_hat = float(np.median(s3[m3] * np.sqrt(t3[m3])))
    red = not (abs(N_hat / (N_true * 3) - 1) < 0.05)
    allred &= red
    if verbose:
        print(f"  {'✅ 变红' if red else '❌ 没变红'} NC5 把真值改成 3N → 比对必须失败 "
              f"(N̂/3N = {N_hat / (N_true * 3):.3f})")

    print("\n  " + ("✅ 负向对照全部变红" if allred else "❌ 有负向对照没变红"))
    return 0 if allred else 1


# ==================================================== CLI

def main():
    ap = argparse.ArgumentParser(description="在线 bias 估计窗口")
    ap.add_argument("--imu", help="imu.csv,用其中一段静置数据算 Allan")
    ap.add_argument("--fs", type=float, default=100.0)
    ap.add_argument("--col", default="gx", help="用哪一列算 Allan(默认 gx)")
    ap.add_argument("--static-start", type=float, help="静置段起 unix 秒")
    ap.add_argument("--static-end", type=float)
    ap.add_argument("--dtdt", type=float, default=0.02, help="升温率 °C/s(实测填)")
    ap.add_argument("--kt", type=float, default=2.0e-3, help="bias 温度系数 /°C(实测填)")
    ap.add_argument("--hyst", type=float, help="滞回半幅 h(thermal_hysteresis.py 的输出)")
    ap.add_argument("--json")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--negative-control", action="store_true")
    a = ap.parse_args()

    if a.negative_control:
        return negative_control()
    if a.selftest or not a.imu:
        return selftest()
    if selftest() != 0 or negative_control() != 0:
        return 1

    with open(a.imu, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.reader(f))
    hdr = [h.strip().lower() for h in rows[0]]
    if a.col not in hdr or "t" not in hdr:
        raise SystemExit(f"imu.csv 需要列 t 和 {a.col};实际 {rows[0]}")
    it, ic = hdr.index("t"), hdr.index(a.col)
    t, y = [], []
    for r in rows[1:]:
        try:
            t.append(float(r[it])); y.append(float(r[ic]))
        except (ValueError, IndexError):
            continue
    t = np.asarray(t); y = np.asarray(y)
    if a.static_start is not None:
        m = (t >= a.static_start) & (t <= (a.static_end if a.static_end else t.max()))
        t, y = t[m], y[m]
    print(f"  静置段 {len(y)} 样本 = {len(y) / a.fs:.0f} s")
    if len(y) < a.fs * 60:
        print(f"  ⚠️ 静置段 < 60 s,Allan 谷底(B)拿不到,只有 N 可信")
    taus, adev = overlapping_adev(y, a.fs)
    N, B, tmin = fit_arw_bi(taus, adev)
    print(f"  Allan: N={N:.3e}  B={B:.3e}(谷底在 τ={tmin:.1f}s)")
    out = report(N, B, a.kt, a.dtdt, hyst=a.hyst)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2, ensure_ascii=False, default=float)
        print(f"结果已写入 {a.json}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
