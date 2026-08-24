"""正向对照 v2: 已知尺度合成数据 -> 求解器必须还原 s/g/ba/bg。
轨迹 = 真实 dome 扫描 (半径 1m 绕行 25s 一圈 + 手抖), 12s / 3.2m / 37 关键帧 / |a|rms 0.58。
逐级放开误差源, 每级一道门。任何一级不过 = 求解器写错, 不是 IMU 路线不行。"""
import numpy as np, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inertial_only_init as M
from inertial_only_init import *

REAL = dict(motion_amp=0.03, att_amp=0.6, imu_hz=100.0, kf_hz=3.0, dur=12.0)
def err(a, b): return 100.0 * (a / b - 1.0)

def line(name, syn, o, nl=True, sa=False):
    g = np.linalg.norm(o["lin"]["g"]); st = syn["s_true"]
    s_corr = o["lin"]["s"] * G0 / g          # ★ 用 |g_hat| 反解掉加计 scale factor
    r = [f"{name:<30}", f"lin={err(o['lin']['s'],st):+8.4f}%",
         f"lin/|g|校正={err(s_corr,st):+8.4f}%",
         f"S2={err(o['ref']['s'],st):+8.4f}%",
         f"|g|hat={g:.5f}({100*(g/G0-1):+7.4f}%)",
         f"sig_s={100*o['obs']['sigma_s_rel']:6.3f}%"]
    if nl and "nl" in o:
        r.append(f"NL={err(o['nl']['s'],st):+8.4f}%")
        r.append(f"|ba-ba*|={np.linalg.norm(o['nl']['ba']-syn['ba']):.4f}(|ba*|={np.linalg.norm(syn['ba']):.4f})")
        if sa: r.append(f"sa_hat={100*o['nl']['accel_scale']:+7.4f}%(真{100*syn['accel_scale']:+.4f}%)")
    print("  ".join(r), flush=True)

print("="*190)
print("【G0】零噪声零零偏 —— 只剩预积分离散误差 = 整条链的精度地板")
for hz in (50, 100, 200, 400):
    for mid in (True, False):
        o0 = M.preintegrate
        M.preintegrate = (lambda *a, _m=mid, _o=o0, **k: _o(*a, **{**k, "midpoint": _m}))
        syn = make_synthetic(**{**REAL, "imu_hz": hz}, acc_noise=0, gyr_noise=0, ba=(0,0,0), bg=(0,0,0))
        line(f"G0 {'midpoint' if mid else 'euler':8s}{hz:4d}Hz", syn, run_pipeline(syn, nonlinear=False), nl=False)
        M.preintegrate = o0

print("\n【G7】误差来源分解 —— 逐项单独打开 (其余全零), 各自贡献多少 s 误差 (100Hz midpoint)")
base = dict(**REAL, seed=3, acc_noise=0, gyr_noise=0, ba=(0,0,0), bg=(0,0,0), accel_scale=0, vis_noise=0)
for name, kw in [("baseline (只剩离散误差)", {}),
                 ("acc 白噪 0.02 m/s^2", dict(acc_noise=0.02)),
                 ("acc 白噪 0.10 m/s^2", dict(acc_noise=0.10)),
                 ("gyr 白噪 0.002 rad/s", dict(gyr_noise=0.002)),
                 ("ba=0.005 m/s^2 (0.5mg)", dict(ba=(0.004,-0.002,0.002))),
                 ("ba=0.05 m/s^2 (5mg)", dict(ba=(0.05,-0.03,0.02))),
                 ("ba=0.20 m/s^2 (20mg)", dict(ba=(0.2,-0.12,0.08))),
                 ("bg=0.003 rad/s", dict(bg=(0.002,-0.001,0.003))),
                 ("★ accel scale +0.116%", dict(accel_scale=0.00116)),
                 ("★ accel scale +1.0%", dict(accel_scale=0.01)),
                 ("视觉噪声 2.14mm", dict(vis_noise=0.00214)),
                 ("视觉噪声 10mm", dict(vis_noise=0.010)),
                 ("视觉噪声 30mm", dict(vis_noise=0.030))]:
    cfg = dict(base); cfg.update(kw)
    syn = make_synthetic(**cfg); line(name, syn, run_pipeline(syn, nonlinear=False), nl=False)

print("\n【G8】|g| 真值不同 (纬度) —— 自由|g| 解免疫, 固定|g| 解不免疫")
for nm, gm in [("标准 9.80665", G0), ("深圳 22.5N = 9.78779", 9.78779),
               ("北京 39.9N = 9.80161", 9.80161), ("sensors_plus 常数 9.81", 9.81)]:
    syn = make_synthetic(**{**base, "g_mag": gm}); o = run_pipeline(syn, nonlinear=False)
    g = np.linalg.norm(o["lin"]["g"])
    print(f"  真|g|={nm:<24} lin(自由)={err(o['lin']['s'],syn['s_true']):+8.4f}%  "
          f"lin·(真γ/|g|hat)={err(o['lin']['s']*gm/g,syn['s_true']):+8.4f}%  "
          f"S2(强按9.80665)={err(o['ref']['s'],syn['s_true']):+8.4f}%  |g|hat={g:.5f}", flush=True)

print("\n【G2】全误差源同开 (iPhone 档): ba=5mg, bg=3mrad/s, acc噪0.02, gyr噪0.002, 视觉2.14mm, sa=0.116%")
for s in range(5):
    syn = make_synthetic(**REAL, seed=s, vis_noise=0.00214, accel_scale=0.00116)
    line(f"G2 seed={s}", syn, run_pipeline(syn, estimate_accel_scale=True), sa=True)

print("\n【G9】b_a 可观性: 松先验 + 长时长 + 强姿态 —— 到底要多少数据才估得出 ba")
for dur, att, sig in [(12, 0.6, 0.05), (12, 0.6, 1.0), (30, 0.6, 1.0),
                      (60, 0.6, 1.0), (30, 2.0, 1.0), (60, 2.0, 1.0)]:
    syn = make_synthetic(**{**REAL, "dur": dur, "att_amp": att}, seed=1, acc_noise=0.02, gyr_noise=0.002)
    o = run_pipeline(syn); bg = o["bg"]
    init = dict(s=o["ref"]["s"], g=o["ref"]["g"], bg=bg, ba=np.zeros(3), v=o["ref"]["v"])
    nl = refine_nonlinear(syn["kf"], syn["ts"], syn["gyr"], syn["acc"], init,
                          p_BC=syn["p_BC"], sigma_ba=sig)
    print(f"  dur={dur:3d}s att={att:.1f} sigma_ba={sig:<5.2f} "
          f"ba_hat={np.round(nl['ba'],4)} 真ba={np.round(syn['ba'],4)} "
          f"|err|={np.linalg.norm(nl['ba']-syn['ba']):.4f}  NL s_err={err(nl['s'],syn['s_true']):+8.4f}%", flush=True)

print("\n【G6】时长 × 激励 扫描 —— sigma_s_rel 能不能提前拒掉估不出的段?")
print(f"{'dur':>5}{'amp':>7}{'|a|rms':>8}{'len_m':>7}{'kf':>5}{'sig_s%':>9}{'cond':>9}{'lin%':>9}{'lin/g%':>9}{'S2%':>9}", flush=True)
for dur in (2.0, 4.0, 8.0, 15.0, 30.0):
    for amp, orb in ((0.005, 0.0), (0.03, 0.3), (0.03, 1.0), (0.10, 1.0)):
        syn = make_synthetic(**{**REAL, "dur": dur, "motion_amp": amp}, orbit_r=orb, seed=2,
                             vis_noise=0.00214)
        o = run_pipeline(syn, nonlinear=False); g = np.linalg.norm(o["lin"]["g"])
        print(f"{dur:5.1f}{amp:7.3f}{syn['acc_exc']:8.3f}{syn['traj_len']:7.2f}{len(syn['kf']):5d}"
              f"{100*o['obs']['sigma_s_rel']:9.3f}{o['obs']['cond']:9.1e}"
              f"{err(o['lin']['s'],syn['s_true']):+9.3f}{err(o['lin']['s']*G0/g,syn['s_true']):+9.3f}"
              f"{err(o['ref']['s'],syn['s_true']):+9.3f}", flush=True)
