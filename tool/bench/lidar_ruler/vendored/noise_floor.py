"""Empirical noise floor of the Sim3 scale estimator per recording.
Take the REAL (XRSLAM cam-centre vs ARKit) Sim3 residual time series, circularly shift it by a random lag
(keeps its spectrum incl. slow drift, breaks its correlation with the motion), add it to k0 * ARKit path,
re-estimate k.  k0=1.00 = negative control (estimator must not invent scale), k0=1.05 = positive control."""
import sys, os, json, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from scale_eval import pair_up, sim3, pair_median
R = os.path.expanduser("~/Developer/viobench-recordings"); W = os.path.dirname(os.path.abspath(__file__))
SB = "/private/tmp/claude-501/-Users-kaidongwang-Documents-progecttwo/0b67e90b-a648-4571-8c8b-efe50b991a36/scratchpad/sb/out/6e2d4b99"
RUN = {"6e2d": f"{R}/run-6e2d4b99-896b-4372-ae47-ac0b4679cf18", "5966": f"{R}/run-5966aec0-cbf1-4abc-af0e-c1fc559da44c", "4ad6": f"{R}/run-4ad6e500-ff59-4e67-9bb5-25fb2efe2faa"}
def ts(rec): return np.array([int(l.split(',')[0]) for l in list(open(RUN[rec]+'/camera_index.csv'))[1:]])*1e-9
def fmap(rec, td, eh=False):
    t = ts(rec); sh = np.full(len(t), td)
    if eh: sh = sh + np.load(W+'/e_4ad6.npy')/2
    return (t, sh)
cases = [("6e2d","S C perframeK (0923)",f"{W}/archive/pfk/out/r6e2d_C.tum",0.008,False),
         ("6e2d","S base_prod (0924)",f"{SB}/base_prod_r1.tum",0.008,False),
         ("6e2d","M td+8 (0922)",f"{R}/_sweep_phone/p_td+8_ba0.tum",0.008,False),
         ("5966","S C perframeK (0923)",f"{W}/archive/pfk/out/r5966_C.tum",0.008,False),
         ("5966","M td+8 (0922)",f"{R}/_sweep_phone2/p_td+8_ba0.tum",0.008,False),
         ("4ad6","S C perframeK c+8 (0923)",f"{W}/archive/pfk/out/r4ad6_C.tum",0.008,True),
         ("4ad6","M c+3 (0922)",f"{R}/_sweep_c_4ad6e500/p_td+3_ba0.tum",0.003,True)]
rng = np.random.default_rng(7)
print("| rec | traj | k_meas | Sim3 res cm | NC k0=1.00: mean / sd / 95% band | PC k0=1.05: mean / sd | PC recovered? | meas k 95% (noise-floor) |")
print("|"+"---|"*8)
out = []
for rec, nm, p, td, eh in cases:
    t, X, Y = pair_up(p, RUN[rec]+'/arkit_poses.tum', cam=True, max_dt=0.001, frame_map=fmap(rec, td, eh))
    s, Rm, tt, ate = sim3(X, Y); k = 1/s
    res = Y - (s*Rm@X + tt)          # residuals in the ARKit frame
    Yc = Y - Y.mean(1, keepdims=True)
    stats = {}
    for k0 in (1.00, 1.05):
        ks = []
        for _ in range(300):
            lag = rng.integers(len(t)//10, len(t) - len(t)//10)
            Xs = k0*Yc + np.roll(res, lag, axis=1)    # synthetic "est" in ref frame (rotation irrelevant for Sim3)
            ks.append(1/sim3(Xs, Y)[0])
        ks = np.array(ks); stats[k0] = ks
    nc, pc = stats[1.00], stats[1.05]
    lo, hi = np.percentile(nc, [2.5, 97.5])
    rec_ok = abs(pc.mean()-1.05) < 0.005
    print(f"| {rec} | {nm} | {k:.4f} | {ate*100:.2f} | {nc.mean():.4f} / {100*nc.std():.2f}% / {lo:.3f}–{hi:.3f} | {pc.mean():.4f} / {100*pc.std():.2f}% | {'PASS' if rec_ok else 'FAIL'} | {k*lo:.3f}–{k*hi:.3f} |")
    out.append(dict(rec=rec, name=nm, k=k, ate_cm=ate*100, nc_mean=nc.mean(), nc_sd=nc.std(), nc_band=[lo, hi], pc_mean=pc.mean(), pc_sd=pc.std()))
json.dump(out, open(W+'/results_noise_floor.json', 'w'), indent=1)
