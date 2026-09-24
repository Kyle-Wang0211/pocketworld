#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""S1: one estimator suite for "XRSLAM scale vs reference", signed, with CI + controls.

Reuses ate.py's umeyama()/load() (exec'd exactly the way accept_scale.py@3a908f5 does)
and ate.py's 10 ms nearest-timestamp association (copied verbatim there).

Conventions (all reported numbers):
    k = est_scale / ref_scale  (k > 1  => XRSLAM trajectory is BIGGER than the reference)
    ate.py / accept_scale.py report s = ref/est and |1-s|;  k = 1/s.

Estimators:
    sim3_fwd   Umeyama Y ~ s R X + t (X=est, Y=ref)  -> k = 1/s   (== ate.py/accept_scale)
    sim3_rev   Umeyama X ~ s R Y + t                   -> k = s     (other regression direction)
    sim3_sym   sqrt(k_fwd * k_rev) = ratio of RMS spreads after rotation (symmetric)
    pair_med   median over frame pairs with |dP_ref| >= min_base of |dP_est|/|dP_ref|
               (alignment-free; no rotation/translation fitted)
Body->camera: XRSLAM tum rows are BODY(IMU) poses (euroc_runner GetResult(BODY_POSE));
    ARKit rows are camera poses.  --cam converts est to camera centres: p_c = p_b + R_wb p_bc.
"""
import json
import os
import sys

import numpy as np

ATE_PY = os.path.expanduser("~/Developer/viobench-recordings/ate.py")


def _load_ate():
    src = open(ATE_PY, encoding="utf-8").read()
    cut = src.find("ARGS=[a for a in sys.argv")
    ns = {"__name__": "_ate_funcs"}
    exec(compile(src[:cut], ATE_PY, "exec"), ns)
    return ns


ATE = _load_ate()

# p_bc and R_bc from the device yaml used by every replay of these three recordings
# (cfg/dev_r6e2d.yaml, identical T_BS in all three: q_bc [-0.7071068, 0.7071068, 0, 0]).
P_BC = np.array([0.03290364, -0.00696553, -0.00286231])


def load_full(p):
    T, P, Q = [], [], []
    for ln in open(p):
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        f = ln.replace(',', ' ').split()
        if len(f) < 8:
            continue
        T.append(float(f[0]))
        P.append([float(f[1]), float(f[2]), float(f[3])])
        Q.append([float(f[4]), float(f[5]), float(f[6]), float(f[7])])  # x y z w
    return np.array(T), np.array(P), np.array(Q)


def qrot(q, v):
    """rotate v (N,3) by unit quaternions q (N,4) in x,y,z,w order."""
    x, y, z, w = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    n = np.sqrt(x * x + y * y + z * z + w * w)
    x, y, z, w = x / n, y / n, z / n, w / n
    R = np.empty((len(q), 3, 3))
    R[:, 0, 0] = 1 - 2 * (y * y + z * z); R[:, 0, 1] = 2 * (x * y - z * w); R[:, 0, 2] = 2 * (x * z + y * w)
    R[:, 1, 0] = 2 * (x * y + z * w); R[:, 1, 1] = 1 - 2 * (x * x + z * z); R[:, 1, 2] = 2 * (y * z - x * w)
    R[:, 2, 0] = 2 * (x * z - y * w); R[:, 2, 1] = 2 * (y * z + x * w); R[:, 2, 2] = 1 - 2 * (x * x + y * y)
    if v.ndim == 1:
        return R @ v
    return np.einsum('nij,nj->ni', R, v)


def body_to_cam(P, Q, p_bc=P_BC):
    return P + qrot(Q, np.tile(p_bc, (len(P), 1)))


def associate(te, tr, max_dt=0.010):
    # verbatim ate.py association (4 lines)
    idx = np.clip(np.searchsorted(tr, te), 1, len(tr) - 1)
    l = np.abs(te - tr[idx - 1]); r = np.abs(te - tr[idx])
    pick = np.where(l < r, idx - 1, idx); ok = np.minimum(l, r) < max_dt
    return ok, pick


def valid_ref_mask(Pr, Qr):
    # ARKit rows that are exactly zero translation + identity quat are "not tracking yet"
    z = (np.abs(Pr).sum(1) == 0)
    return ~z


def sim3(X, Y):
    s, R, t = ATE["umeyama"](X, Y)
    e = np.linalg.norm((s * R @ X + t) - Y, axis=0)
    return s, R, t, float(np.sqrt((e ** 2).mean()))


def se3_ate(X, Y):
    _, R, t = ATE["umeyama"](X, Y, False)
    e = np.linalg.norm((R @ X + t) - Y, axis=0)
    return float(np.sqrt((e ** 2).mean()))


def pair_median(X, Y, min_base=0.10, max_pairs=200000, rng=None):
    n = X.shape[1]
    rng = rng or np.random.default_rng(0)
    i = rng.integers(0, n, max_pairs); j = rng.integers(0, n, max_pairs)
    dY = np.linalg.norm(Y[:, i] - Y[:, j], axis=0)
    dX = np.linalg.norm(X[:, i] - X[:, j], axis=0)
    m = dY >= min_base
    if m.sum() < 50:
        return float('nan'), int(m.sum())
    return float(np.median(dX[m] / dY[m])), int(m.sum())


def estimators(X, Y, t=None, min_base=0.10):
    s_f, _, _, ate_f = sim3(X, Y)
    s_r, _, _, ate_r = sim3(Y, X)
    k_f = 1.0 / s_f
    k_r = s_r
    pm, npair = pair_median(X, Y, min_base)
    return {
        "n": int(X.shape[1]),
        "k_sim3_fwd": k_f, "k_sim3_rev": k_r, "k_sim3_sym": float(np.sqrt(k_f * k_r)),
        "k_pair_med": pm, "n_pairs": npair,
        "ate_sim3_cm": ate_f * 100, "ate_se3_cm": se3_ate(X, Y) * 100,
        "ref_extent_m": float(np.linalg.norm(Y.max(1) - Y.min(1))),
        "ref_rms_spread_m": float(np.sqrt(((Y - Y.mean(1, keepdims=True)) ** 2).sum(0).mean())),
    }


def block_bootstrap(X, Y, t, fn, n_boot=400, block_s=1.0, seed=1):
    """moving-block bootstrap over time (blocks of block_s seconds) of fn(X,Y)->float."""
    rng = np.random.default_rng(seed)
    blk = np.floor((t - t[0]) / block_s).astype(int)
    ub = np.unique(blk)
    groups = [np.where(blk == b)[0] for b in ub]
    out = []
    for _ in range(n_boot):
        pick = rng.integers(0, len(groups), len(groups))
        idx = np.concatenate([groups[p] for p in pick])
        out.append(fn(X[:, idx], Y[:, idx]))
    out = np.array(out)
    return float(np.percentile(out, 2.5)), float(np.percentile(out, 97.5)), float(out.std())


def segments(X, Y, t, nseg=4):
    res = []
    edges = np.linspace(t[0], t[-1], nseg + 1)
    for a, b in zip(edges[:-1], edges[1:]):
        m = (t >= a) & (t <= b)
        if m.sum() < 30:
            res.append(None); continue
        s, _, _, _ = sim3(X[:, m], Y[:, m])
        res.append(1.0 / s)
    return res


def remap_to_frames(te, frame_t, shift, tol=0.0005):
    """est pose time = frame time + shift_i (shift_i = td [+ exposure_i/2]); map back to frame time."""
    tt = frame_t + shift
    o = np.argsort(tt); tts = tt[o]
    idx = np.clip(np.searchsorted(tts, te), 1, len(tts) - 1)
    l = np.abs(te - tts[idx - 1]); r = np.abs(te - tts[idx])
    pick = np.where(l < r, idx - 1, idx); ok = np.minimum(l, r) < tol
    out = np.full(len(te), np.nan); out[ok] = frame_t[o[pick[ok]]]
    return out


def pair_up(est_path, ref_path, cam=True, subset_times=None, max_dt=0.010, td=0.0, frame_map=None):
    te, Pe, Qe = load_full(est_path)
    if frame_map is not None:  # (frame_t, shift_i): exact inverse of the reader's time shift
        te = remap_to_frames(te, *frame_map)
        k = ~np.isnan(te); te, Pe, Qe = te[k], Pe[k], Qe[k]
    else:
        te = te - td  # XRSLAM output time = image time + cam0.time_offset (euroc_dataset_reader.cpp:16)
    tr, Pr, Qr = load_full(ref_path)
    v = valid_ref_mask(Pr, Qr)
    tr, Pr, Qr = tr[v], Pr[v], Qr[v]
    if cam:
        Pe = body_to_cam(Pe, Qe)
    if subset_times is not None:
        ok, pick = associate(np.asarray(subset_times), te, max_dt)
        sel = pick[ok]
        te, Pe, Qe = te[sel], Pe[sel], Qe[sel]
    ok, pick = associate(te, tr, max_dt)
    return te[ok], Pe[ok].T, Pr[pick[ok]].T


def evaluate(est_path, ref_path, cam=True, subset_times=None, boot=True, nseg=4, td=0.0, max_dt=0.010, frame_map=None):
    t, X, Y = pair_up(est_path, ref_path, cam, subset_times, max_dt=max_dt, td=td, frame_map=frame_map)
    r = estimators(X, Y, t)
    r["duration_s"] = float(t[-1] - t[0])
    if boot and X.shape[1] >= 30:
        lo, hi, sd = block_bootstrap(X, Y, t, lambda a, b: 1.0 / sim3(a, b)[0])
        r["k_sim3_fwd_ci95"] = [lo, hi]; r["k_sim3_fwd_bsd"] = sd
    if nseg and X.shape[1] >= 4 * 30:
        r["seg_k"] = segments(X, Y, t, nseg)
    return r


if __name__ == "__main__":
    est, ref = sys.argv[1], sys.argv[2]
    cam = "--body" not in sys.argv
    print(json.dumps(evaluate(est, ref, cam), indent=1))
