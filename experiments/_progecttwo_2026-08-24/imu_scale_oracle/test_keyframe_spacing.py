"""G10: 关键帧间距 vs 视觉噪声 —— 线性解把含噪的视觉位移放在【设计矩阵】一侧,
所以视觉噪声造成的是 regression dilution (系统性低估 s), 不只是方差。
唯一免费的解药 = 拉大关键帧间距, 让 |Δp_C| >> sigma_vis。"""
import numpy as np, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from inertial_only_init import *
REAL = dict(motion_amp=0.03, att_amp=0.6, imu_hz=100.0, dur=30.0)
print(f"{'kf_hz':>6}{'kf数':>6}{'|dp_C|_m':>10}{'sig/|dp|':>10} | " + "  ".join(f"{v*1000:>7.2f}mm" for v in (0.0,0.0005,0.00214,0.005,0.010)))
for kf_hz in (5.0, 3.0, 1.5, 1.0, 0.5, 0.33, 0.2):
    row = []
    dpc = None
    for vn in (0.0, 0.0005, 0.00214, 0.005, 0.010):
        es = []
        for seed in range(5):
            syn = make_synthetic(**REAL, kf_hz=kf_hz, seed=seed, vis_noise=vn,
                                 ba=(0.05,-0.03,0.02), bg=(0.002,-0.001,0.003),
                                 accel_scale=0.00116, acc_noise=0.02, gyr_noise=0.002)
            o = run_pipeline(syn, nonlinear=False)
            g = np.linalg.norm(o["lin"]["g"])
            es.append(100*(o["lin"]["s"]*G0/g/syn["s_true"]-1))
            if dpc is None:
                P = np.array([k["p_C"] for k in syn["kf"]])*syn["s_true"]
                dpc = float(np.mean(np.linalg.norm(np.diff(P,axis=0),axis=1)))
                nkf = len(syn["kf"])
        row.append(f"{np.mean(es):+7.3f}%")
    print(f"{kf_hz:6.2f}{nkf:6d}{dpc:10.3f}{0.00214/dpc:10.4f} | " + "  ".join(row), flush=True)
