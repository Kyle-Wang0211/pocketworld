#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
traj_score.py — 实验一评分口径唯一实现。

同时报三个数(缺一不可):
  1) SE3-ATE   : 刚体(6dof)对齐后的平移 RMSE  —— 含尺度误差
  2) Sim3-ATE  : 相似(7dof)对齐后的平移 RMSE  —— 尺度被吸收,对尺度失明
  3) scale err : 尺度误差百分比,三条独立口径
       (a) alignment 口径 : Umeyama 的 s      (相对参考轨迹)
       (b) 相对基线谱      : 距离比,不做任何对齐(相对参考轨迹, 无 gauge)
       (c) 物理控制长度    : 卷尺真值          (绝对, 唯一可用于产品判定)

恒等式(本脚本用它做自检, 数值上精确成立):
      ATE_SE3^2 == ATE_Sim3^2 + sigma_est^2 * (1 - s)^2
  sigma_est = 估计轨迹相机中心相对其质心的 RMS 半径。
  推论: 单看 SE3-ATE 无法区分"形状差"与"尺度错"; 单看 Sim3-ATE 对尺度 100% 失明。

用法:
  python3 traj_score.py score --ref ref.tum --est est.tum \
      [--assoc exact|nearest] [--t-max-diff 0.01] \
      [--trim-head 3.0] [--trim-sweep 0,2,5,10] \
      [--controls controls.csv] [--out outdir] [--json]
  python3 traj_score.py convert-colmap --images images.txt --out ref.tum [--name-to-id map.csv]
  python3 traj_score.py timeoffset --ref a.tum --est b.tum
  python3 traj_score.py selftest
"""
import argparse, csv, json, math, os, sys
import numpy as np

# ---------------------------------------------------------------- I/O
def load_tum(path):
    """TUM: t tx ty tz qx qy qz qw   (位置=相机中心 C, 世界系; 四元数=R_cam->world)"""
    ts, P, Q = [], [], []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln[0] == '#':
                continue
            v = [float(x) for x in ln.replace(',', ' ').split()]
            if len(v) != 8:
                raise ValueError(f"{path}: 需要 8 列 (t tx ty tz qx qy qz qw), 实得 {len(v)}")
            ts.append(v[0]); P.append(v[1:4]); Q.append(v[4:8])
    o = np.argsort(np.asarray(ts))
    return np.asarray(ts)[o], np.asarray(P)[o], np.asarray(Q)[o]

def quat_to_R(q):
    """q = (x,y,z,w) -> 3x3。自带归一化。"""
    q = np.asarray(q, float)
    q = q / np.linalg.norm(q, axis=-1, keepdims=True)
    x, y, z, w = q[..., 0], q[..., 1], q[..., 2], q[..., 3]
    R = np.empty(q.shape[:-1] + (3, 3))
    R[..., 0, 0] = 1 - 2 * (y * y + z * z); R[..., 0, 1] = 2 * (x * y - z * w); R[..., 0, 2] = 2 * (x * z + y * w)
    R[..., 1, 0] = 2 * (x * y + z * w);     R[..., 1, 1] = 1 - 2 * (x * x + z * z); R[..., 1, 2] = 2 * (y * z - x * w)
    R[..., 2, 0] = 2 * (x * z - y * w);     R[..., 2, 1] = 2 * (y * z + x * w);     R[..., 2, 2] = 1 - 2 * (x * x + y * y)
    return R

# ---------------------------------------------------------------- 关联
def associate(t_ref, t_est, mode="exact", t_max_diff=0.01):
    """返回 (idx_ref, idx_est)。exact: 时间戳列当作 frame_id 精确配。"""
    if mode == "exact":
        m = {round(t, 6): i for i, t in enumerate(t_ref)}
        ir, ie = [], []
        for j, t in enumerate(t_est):
            i = m.get(round(t, 6))
            if i is not None:
                ir.append(i); ie.append(j)
        return np.array(ir, int), np.array(ie, int)
    ir, ie = [], []
    for j, t in enumerate(t_est):
        i = int(np.argmin(np.abs(t_ref - t)))
        if abs(t_ref[i] - t) <= t_max_diff:
            ir.append(i); ie.append(j)
    return np.array(ir, int), np.array(ie, int)

# ---------------------------------------------------------------- Umeyama
def umeyama(X, Y, with_scale):
    """求 s,R,t 使 s*R*X_i + t ≈ Y_i。X=估计, Y=参考。Umeyama 1991 闭式解。
       注意: R 与 s 无关(R 只来自 Sigma 的 SVD), 因此旋转误差对 SE3/Sim3 完全相同。"""
    X = np.asarray(X, float); Y = np.asarray(Y, float)
    n = X.shape[0]
    if n < 3:
        raise ValueError("对齐至少需要 3 个位姿")
    mx, my = X.mean(0), Y.mean(0)
    Xc, Yc = X - mx, Y - my
    Sigma = (Yc.T @ Xc) / n
    U, D, Vt = np.linalg.svd(Sigma)
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(Vt) < 0:
        S[2, 2] = -1.0
    R = U @ S @ Vt
    var_x = float((Xc ** 2).sum() / n)          # = sigma_est^2
    s = float((D * np.diag(S)).sum() / var_x) if with_scale else 1.0
    t = my - s * (R @ mx)
    return s, R, t, var_x, float(np.linalg.matrix_rank(Sigma, tol=1e-9))

def stats(e):
    e = np.asarray(e, float)
    return dict(rmse=float(np.sqrt((e ** 2).mean())), mean=float(e.mean()),
                median=float(np.median(e)), std=float(e.std()),
                p95=float(np.percentile(e, 95)), max=float(e.max()), n=int(e.size))

def rot_err_deg(R_align, Q_est, Q_ref):
    Re, Rr = quat_to_R(Q_est), quat_to_R(Q_ref)
    Rd = np.einsum('ij,njk,nlk->nil', R_align, Re, Rr)     # R_align*R_est*R_ref^T
    tr = np.clip((np.trace(Rd, axis1=1, axis2=2) - 1.0) / 2.0, -1.0, 1.0)
    return np.degrees(np.arccos(tr))

# ---------------------------------------------------------------- 三个数
def score_pair(P_est, P_ref, Q_est=None, Q_ref=None):
    s3, R3, t3, var_x, rk = umeyama(P_est, P_ref, with_scale=False)
    e_se3 = np.linalg.norm((R3 @ P_est.T).T + t3 - P_ref, axis=1)
    s7, R7, t7, _, _ = umeyama(P_est, P_ref, with_scale=True)
    e_sim3 = np.linalg.norm(s7 * (R7 @ P_est.T).T + t7 - P_ref, axis=1)
    out = dict(
        n=int(P_est.shape[0]),
        sigma_est_m=float(math.sqrt(var_x)),
        sigma_rank=rk,
        se3_ate=stats(e_se3),
        sim3_ate=stats(e_sim3),
        umeyama_s=float(s7),                       # est -> ref
        k_est_over_true=float(1.0 / s7),           # 估计/真值
        scale_err_pct_align=float((1.0 / s7 - 1.0) * 100.0),
    )
    a, b = out['se3_ate']['rmse'] ** 2, out['sim3_ate']['rmse'] ** 2 + var_x * (1 - s7) ** 2
    out['identity_residual'] = float(abs(a - b))
    out['identity_ok'] = bool(abs(a - b) <= 1e-9 * max(1.0, a))
    out['se3_share_from_scale_pct'] = float(100.0 * var_x * (1 - s7) ** 2 / a) if a > 0 else 0.0
    if Q_est is not None and Q_ref is not None:
        r = rot_err_deg(R3, Q_est, Q_ref)
        out['rot_err_deg'] = stats(r)              # SE3 与 Sim3 相同
    out['_res_se3'] = e_se3; out['_res_sim3'] = e_sim3
    return out

# ------------------------------------------------- 口径(b) 相对基线谱(免对齐)
def relative_scale_spectrum(P_est, P_ref, bins=(0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 1e9),
                            max_pairs=200000, seed=0):
    n = P_est.shape[0]
    ii, jj = np.triu_indices(n, k=1)
    if ii.size > max_pairs:
        rs = np.random.default_rng(seed)
        sel = rs.choice(ii.size, max_pairs, replace=False)
        ii, jj = ii[sel], jj[sel]
    b_ref = np.linalg.norm(P_ref[jj] - P_ref[ii], axis=1)
    b_est = np.linalg.norm(P_est[jj] - P_est[ii], axis=1)
    keep = b_ref > 1e-6
    b_ref, b_est = b_ref[keep], b_est[keep]
    r = b_est / b_ref
    rows = []
    for lo, hi in zip(bins[:-1], bins[1:]):
        m = (b_ref >= lo) & (b_ref < hi)
        if m.sum() < 20:
            continue
        rr = r[m]
        rows.append(dict(bin_m=[lo, None if hi > 1e8 else hi], n=int(m.sum()),
                         median=float(np.median(rr)),
                         p16=float(np.percentile(rr, 16)), p84=float(np.percentile(rr, 84)),
                         scale_err_pct=float((np.median(rr) - 1) * 100)))
    m = b_ref >= 0.5
    glob = float(np.median(r[m])) if m.sum() >= 20 else float('nan')
    return dict(bins=rows, global_median_ratio=glob,
                global_scale_err_pct=float((glob - 1) * 100) if glob == glob else float('nan'))

# ------------------------------------------------- 尺度随时间(热漂移探针)
def scale_vs_time(t, P_est, P_ref, win_s=20.0, hop_s=5.0, min_sigma_m=0.20):
    out = []
    t0, t1 = t[0], t[-1]
    a = t0
    while a + win_s <= t1 + 1e-9:
        m = (t >= a) & (t < a + win_s)
        if m.sum() >= 10:
            try:
                s, _, _, var_x, _ = umeyama(P_est[m], P_ref[m], True)
                if math.sqrt(var_x) >= min_sigma_m:
                    out.append(dict(t_mid=float(a + win_s / 2), n=int(m.sum()),
                                    sigma_est_m=float(math.sqrt(var_x)),
                                    k=float(1 / s), scale_err_pct=float((1 / s - 1) * 100)))
            except ValueError:
                pass
        a += hop_s
    drift = None
    if len(out) >= 3:
        x = np.array([o['t_mid'] for o in out]); y = np.array([o['k'] for o in out])
        A = np.vstack([x, np.ones_like(x)]).T
        sl = float(np.linalg.lstsq(A, y, rcond=None)[0][0])
        drift = dict(ppm_per_min=sl * 1e6 * 60.0,
                     span_pct=float((y.max() - y.min()) * 100))
    return dict(windows=out, drift=drift)

# ------------------------------------------------- 口径(c) 物理控制长度
def scale_from_controls(path):
    """CSV 列: name,L_true_mm,L_true_sigma_mm,L_est_mm[,axis]
       k_ls    = sum(Le*Lt)/sum(Lt^2)   <- 端点误差为绝对量(mm级)时的最优估计, 长基线按 L^2 加权
       k_med   = median(Le/Lt)          <- 稳健对照
       两者差 >0.3% 必须查原因, 不许挑一个报。"""
    rows = []
    with open(path) as f:
        for d in csv.DictReader(f):
            if not d.get('name'):
                continue
            rows.append(dict(name=d['name'].strip(),
                             Lt=float(d['L_true_mm']), st=float(d.get('L_true_sigma_mm') or 0.0),
                             Le=float(d['L_est_mm']), axis=(d.get('axis') or 'mixed').strip()))
    if not rows:
        raise ValueError("controls.csv 为空")
    Lt = np.array([r['Lt'] for r in rows]); Le = np.array([r['Le'] for r in rows])
    k_ls = float((Le * Lt).sum() / (Lt ** 2).sum())
    res = Le - k_ls * Lt
    dof = max(len(rows) - 1, 1)
    sig = float(np.sqrt((res ** 2).sum() / dof))                     # 端点识别噪声 sigma (mm)
    sk = float(sig / math.sqrt((Lt ** 2).sum()))                     # k 的标准差
    ratios = Le / Lt
    per_axis = {}
    for ax in sorted(set(r['axis'] for r in rows)):
        m = np.array([r['axis'] == ax for r in rows])
        if m.sum() >= 1:
            per_axis[ax] = dict(n=int(m.sum()),
                                k_ls=float((Le[m] * Lt[m]).sum() / (Lt[m] ** 2).sum()),
                                scale_err_pct=float(((Le[m] * Lt[m]).sum() / (Lt[m] ** 2).sum() - 1) * 100))
    truth_floor = float(np.sqrt((np.array([r['st'] for r in rows]) ** 2 * Lt ** 2).sum()) / (Lt ** 2).sum()) \
        if any(r['st'] for r in rows) else 0.0
    return dict(
        n=len(rows), k_ls=k_ls, scale_err_pct=float((k_ls - 1) * 100),
        k_median=float(np.median(ratios)), scale_err_pct_median=float((np.median(ratios) - 1) * 100),
        sigma_k=sk, sigma_k_pct=float(sk * 100), endpoint_sigma_mm=sig,
        truth_floor_pct=float(truth_floor * 100),
        sqrt_sum_L2_mm=float(math.sqrt((Lt ** 2).sum())),
        consistency_ok=bool(abs(k_ls - np.median(ratios)) < 0.003),
        per_axis=per_axis,
        items=[dict(name=r['name'], axis=r['axis'], L_true_mm=r['Lt'], L_est_mm=r['Le'],
                    ratio=float(r['Le'] / r['Lt']), err_pct=float((r['Le'] / r['Lt'] - 1) * 100),
                    resid_mm=float(r['Le'] - k_ls * r['Lt'])) for r in rows])

# ------------------------------------------------- 时间偏移(仅独立参考时才需要)
def angular_rate(t, Q):
    R = quat_to_R(Q)
    dR = np.einsum('nij,nkj->nik', R[1:], R[:-1])
    tr = np.clip((np.trace(dR, axis1=1, axis2=2) - 1) / 2, -1, 1)
    dt = np.diff(t); dt[dt <= 0] = 1e-6
    return t[:-1] + dt / 2, np.arccos(tr) / dt

def estimate_time_offset(t_ref, Q_ref, t_est, Q_est, rng_s=0.5, step_s=0.001):
    """互相关角速度模长(尺度无关)。返回 dt: t_est + dt ≈ t_ref。"""
    ta, wa = angular_rate(t_ref, Q_ref)
    tb, wb = angular_rate(t_est, Q_est)
    grid = np.arange(max(ta[0], tb[0]), min(ta[-1], tb[-1]), 0.005)
    if grid.size < 50:
        raise ValueError("重叠时间太短")
    A = np.interp(grid, ta, wa); A = (A - A.mean()) / (A.std() + 1e-12)
    best, bd = -2.0, 0.0
    for d in np.arange(-rng_s, rng_s + 1e-9, step_s):
        B = np.interp(grid, tb + d, wb); B = (B - B.mean()) / (B.std() + 1e-12)
        c = float((A * B).mean())
        if c > best:
            best, bd = c, float(d)
    return bd, best

# ------------------------------------------------- COLMAP -> TUM
def convert_colmap(images_txt, out_tum):
    """COLMAP images.txt 存的是 world->cam 的 (qw,qx,qy,qz,tx,ty,tz)。
       相机中心 C = -R^T t ; TUM 四元数是 (qx,qy,qz,qw) 且代表 cam->world。
       两处不转换 = 静默错误(ATE 全错但脚本不报错), 这是最常见的一类 bug。"""
    rows = []
    with open(images_txt) as f:
        lines = [l for l in f if not l.startswith('#')]
    for i in range(0, len(lines), 2):                      # 奇数行位姿, 偶数行 2D 点
        p = lines[i].split()
        if len(p) < 10:
            continue
        qw, qx, qy, qz = map(float, p[1:5]); tx, ty, tz = map(float, p[5:8]); name = p[9]
        Rw2c = quat_to_R(np.array([qx, qy, qz, qw]))
        C = -Rw2c.T @ np.array([tx, ty, tz])
        Rc2w = Rw2c.T
        w = math.sqrt(max(0.0, 1 + Rc2w[0, 0] + Rc2w[1, 1] + Rc2w[2, 2])) / 2
        if w < 1e-8:
            u, _, vt = np.linalg.svd(Rc2w); Rc2w = u @ vt
            w = math.sqrt(max(1e-16, 1 + np.trace(Rc2w))) / 2
        x = (Rc2w[2, 1] - Rc2w[1, 2]) / (4 * w); y = (Rc2w[0, 2] - Rc2w[2, 0]) / (4 * w); z = (Rc2w[1, 0] - Rc2w[0, 1]) / (4 * w)
        fid = ''.join(ch for ch in os.path.splitext(name)[0] if ch.isdigit())
        rows.append((float(fid) if fid else float(p[0]), C[0], C[1], C[2], x, y, z, w, name))
    rows.sort()
    with open(out_tum, 'w') as f:
        f.write("# frame_id tx ty tz qx qy qz qw   (由 COLMAP images.txt 转换: C=-R^T t, cam->world)\n")
        for r in rows:
            f.write("%.6f %.9f %.9f %.9f %.9f %.9f %.9f %.9f\n" % r[:8])
    return len(rows)

# ---------------------------------------------------------------- 主流程
def run(args):
    t_ref, P_ref, Q_ref = load_tum(args.ref)
    t_est, P_est, Q_est = load_tum(args.est)
    ir, ie = associate(t_ref, t_est, args.assoc, args.t_max_diff)
    if ir.size < 3:
        sys.exit("关联失败: 匹配到 %d 帧。参考与估计必须建立在同一批帧上(时间戳列填 frame_id)。" % ir.size)
    rep = dict(ref=os.path.abspath(args.ref), est=os.path.abspath(args.est),
               assoc=dict(mode=args.assoc, matched=int(ir.size),
                          n_ref=int(t_ref.size), n_est=int(t_est.size),
                          coverage_pct=float(100.0 * ir.size / max(t_est.size, 1))))
    T = t_ref[ir]; A = P_est[ie]; B = P_ref[ir]; QA = Q_est[ie]; QB = Q_ref[ir]
    # 时间戳列若填的是 frame_id(整数、间距~1), 时间域分析必须先换算成秒
    d = np.diff(T)
    is_fid = bool(np.allclose(T, np.round(T), atol=1e-6) and d.size and abs(np.median(d) - 1.0) < 1e-6)
    if is_fid:
        if not args.fps:
            sys.exit("时间戳列看起来是 frame_id 而不是秒。时间域分析(尺度热漂移)必须知道帧率: 加 --fps 30。")
        T = (T - T[0]) / args.fps
    rep['timestamp_domain'] = 'frame_id->sec@%gfps' % args.fps if is_fid else 'seconds'
    rep['ref_path_length_m'] = float(np.linalg.norm(np.diff(B, axis=0), axis=1).sum())

    rep['duration_s'] = float(T[-1] - T[0])
    sweep = [float(x) for x in args.trim_sweep.split(',')] if args.trim_sweep else [args.trim_head]
    rep['trim_sweep'] = {}
    for cut in sweep:
        m = T >= (T[0] + cut)
        if m.sum() < 3:
            continue
        r = score_pair(A[m], B[m], QA[m], QB[m])
        res_se3, res_sim3 = r.pop('_res_se3'), r.pop('_res_sim3')
        r['relative_scale'] = relative_scale_spectrum(A[m], B[m])
        if (T[m][-1] - T[m][0]) > 3 * args.win:
            r['scale_vs_time'] = scale_vs_time(T[m], A[m], B[m], args.win, args.hop)
        rep['trim_sweep']['cut_%gs' % cut] = r
        if abs(cut - args.trim_head) < 1e-9 and args.out:
            os.makedirs(args.out, exist_ok=True)
            with open(os.path.join(args.out, 'residuals.csv'), 'w') as f:
                f.write("t,se3_err_m,sim3_err_m\n")
                for a, b, c in zip(T[m], res_se3, res_sim3):
                    f.write("%.6f,%.6f,%.6f\n" % (a, b, c))
    rep['headline_cut_s'] = args.trim_head

    if args.controls:
        rep['controls'] = scale_from_controls(args.controls)

    # ---- 判定
    h = rep['trim_sweep'].get('cut_%gs' % args.trim_head)
    v = []
    if h:
        if not h['identity_ok']:
            v.append("恒等式自检失败 -> 实现有 bug, 三个数全部作废")
        if h['sigma_est_m'] < 0.5:
            v.append("sigma_est=%.2fm <0.5m: 轨迹范围太小, s 的不确定度被放大, 尺度结论不可用" % h['sigma_est_m'])
        sp = [abs(b['scale_err_pct']) for b in h['relative_scale']['bins']]
        if sp and max(sp) - min(sp) > 0.5:
            v.append("相对基线谱跨 bin 差 %.2fpp: 尺度非均匀(漂移或各向异性), 单一 s 不成立" % (max(sp) - min(sp)))
        d = (h.get('scale_vs_time') or {}).get('drift')
        if d and abs(d['span_pct']) > 0.5:
            v.append("尺度随时间摆动 %.2f%%: 疑似热漂移, 必须报 s(t) 而不是单一 s" % d['span_pct'])
    c = rep.get('controls')
    if c:
        if not c['consistency_ok']:
            v.append("控制长度 k_ls 与 k_median 差 >0.3%: 有离群基线或各向异性")
        if c['sigma_k_pct'] > 0.1:
            v.append("控制网 sigma_k=%.3f%% >0.1%%: 基线太短/太少, 加长到 sqrt(sum L^2)>=3m" % c['sigma_k_pct'])
        if h and abs(c['scale_err_pct'] - h['scale_err_pct_align']) > 0.5:
            v.append("物理口径 %.2f%% 与 alignment 口径 %.2f%% 差 >0.5pp: 参考轨迹的米制锚定本身有问题"
                     % (c['scale_err_pct'], h['scale_err_pct_align']))
    rep['verdict_flags'] = v
    return rep

def fmt(rep):
    L = []
    a = rep['assoc']
    L.append("关联: %d/%d 帧 (%s, 覆盖 %.1f%%)  时长 %.1fs  参考路径长 %.2fm"
             % (a['matched'], a['n_est'], a['mode'], a['coverage_pct'], rep['duration_s'], rep['ref_path_length_m']))
    L.append("")
    L.append("%-10s %10s %10s %10s %10s %10s" % ("剪头(s)", "SE3-ATE", "Sim3-ATE", "sigma_est", "尺度误差%", "旋转中位°"))
    for k, r in rep['trim_sweep'].items():
        L.append("%-10s %9.1fmm %9.1fmm %9.3fm %9.3f%% %9.3f"
                 % (k.replace('cut_', '').replace('s', ''), r['se3_ate']['rmse'] * 1000,
                    r['sim3_ate']['rmse'] * 1000, r['sigma_est_m'], r['scale_err_pct_align'],
                    r.get('rot_err_deg', {}).get('median', float('nan'))))
    h = rep['trim_sweep'].get('cut_%gs' % rep['headline_cut_s'])
    if h:
        L.append("")
        L.append("SE3-ATE 中来自尺度的份额: %.1f%%   恒等式残差 %.2e (%s)"
                 % (h['se3_share_from_scale_pct'], h['identity_residual'], "OK" if h['identity_ok'] else "FAIL"))
        L.append("相对基线谱(免对齐):")
        for b in h['relative_scale']['bins']:
            hi = "inf" if b['bin_m'][1] is None else "%g" % b['bin_m'][1]
            L.append("  基线 %g-%s m  n=%-7d 比值中位 %.5f  (%.3f%%)  16/84: %.5f/%.5f"
                     % (b['bin_m'][0], hi, b['n'], b['median'], b['scale_err_pct'], b['p16'], b['p84']))
        d = (h.get('scale_vs_time') or {}).get('drift')
        if d:
            L.append("尺度随时间: 斜率 %.0f ppm/min, 极差 %.3f%%" % (d['ppm_per_min'], d['span_pct']))
    c = rep.get('controls')
    if c:
        L.append("")
        L.append("物理控制长度(唯一绝对口径): k_ls=%.5f -> %.3f%% ± %.3f%% (n=%d, 端点sigma=%.1fmm, sqrt(sum L^2)=%.0fmm)"
                 % (c['k_ls'], c['scale_err_pct'], c['sigma_k_pct'], c['n'], c['endpoint_sigma_mm'], c['sqrt_sum_L2_mm']))
        L.append("                      k_median=%.5f -> %.3f%%   一致性 %s"
                 % (c['k_median'], c['scale_err_pct_median'], "OK" if c['consistency_ok'] else "FAIL"))
        for ax, d in c['per_axis'].items():
            L.append("  轴 %-8s n=%d  %.3f%%" % (ax, d['n'], d['scale_err_pct']))
    if rep['verdict_flags']:
        L.append("")
        L.append("!! 阻断/警告:")
        for f in rep['verdict_flags']:
            L.append("   - " + f)
    return "\n".join(L)

# ---------------------------------------------------------------- selftest
def selftest():
    rng = np.random.default_rng(7)
    n = 400
    th = np.linspace(0, 2 * np.pi, n)
    P_ref = np.stack([2.5 * np.cos(th), 0.1 * np.sin(3 * th) + 1.4, 2.0 * np.sin(th)], 1)
    Rt = quat_to_R(np.array([0.1, 0.2, 0.3, 0.9]))
    k = 0.97                                        # 估计比真值小 3%
    P_est = (Rt.T @ ((P_ref - P_ref.mean(0)) * k).T).T + np.array([5., -2., 1.])
    Q = np.tile(np.array([0., 0., 0., 1.]), (n, 1))
    r = score_pair(P_est, P_ref, Q, Q)
    sig = r['sigma_est_m']
    assert r['sim3_ate']['rmse'] < 1e-9, r['sim3_ate']
    assert abs(r['scale_err_pct_align'] - (k - 1) * 100) < 1e-6, r['scale_err_pct_align']
    assert abs(r['se3_ate']['rmse'] - sig * abs(1 - 1 / k)) < 1e-9
    assert r['identity_ok']
    print("[1] 纯尺度误差 %.1f%%: Sim3-ATE=%.3e mm(=0, 完全失明), SE3-ATE=%.1f mm, sigma_est=%.3f m, s恢复=%.4f%%"
          % ((k - 1) * 100, r['sim3_ate']['rmse'] * 1e3, r['se3_ate']['rmse'] * 1e3, sig, r['scale_err_pct_align']))
    P_est2 = P_est + rng.normal(0, 0.02, P_est.shape)
    r2 = score_pair(P_est2, P_ref, Q, Q)
    assert r2['identity_ok'], r2['identity_residual']
    print("[2] 尺度+20mm 抖动: SE3-ATE=%.1f mm, Sim3-ATE=%.1f mm, 尺度=%.3f%%, 恒等式残差=%.2e, 尺度占SE3能量 %.1f%%"
          % (r2['se3_ate']['rmse'] * 1e3, r2['sim3_ate']['rmse'] * 1e3, r2['scale_err_pct_align'],
             r2['identity_residual'], r2['se3_share_from_scale_pct']))
    P_est3 = (Rt.T @ (P_ref - P_ref.mean(0)).T).T + rng.normal(0, 0.038, P_ref.shape)
    r3 = score_pair(P_est3, P_ref, Q, Q)
    print("[3] 零尺度误差 + 纯抖动, SE3-ATE=%.1f mm (与[1]几乎相同) 但尺度=%.3f%% -> 单看 SE3-ATE 不可归因"
          % (r3['se3_ate']['rmse'] * 1e3, r3['scale_err_pct_align']))
    sp = relative_scale_spectrum(P_est2, P_ref)
    print("[4] 免对齐相对基线谱: 全局 %.3f%%; 分 bin " % sp['global_scale_err_pct']
          + " ".join("%g-%s:%.3f%%" % (b['bin_m'][0], b['bin_m'][1], b['scale_err_pct']) for b in sp['bins']))
    import tempfile
    p = os.path.join(tempfile.mkdtemp(), 'c.csv')
    with open(p, 'w') as f:
        f.write("name,L_true_mm,L_true_sigma_mm,L_est_mm,axis\n")
        for nm, Lt, ax in [("A", 5000, 'x'), ("B", 3000, 'y'), ("C", 2000, 'z'), ("D", 1000, 'x')]:
            f.write("%s,%d,1.3,%.1f,%s\n" % (nm, Lt, Lt * k + rng.normal(0, 3), ax))
    c = scale_from_controls(p)
    print("[5] 控制长度: k_ls=%.5f (%.3f%% ± %.3f%%) k_med=%.5f (%.3f%%) 端点sigma=%.1fmm"
          % (c['k_ls'], c['scale_err_pct'], c['sigma_k_pct'], c['k_median'], c['scale_err_pct_median'],
             c['endpoint_sigma_mm']))
    print("selftest PASS")

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('score')
    s.add_argument('--ref', required=True); s.add_argument('--est', required=True)
    s.add_argument('--assoc', default='exact', choices=['exact', 'nearest'])
    s.add_argument('--t-max-diff', type=float, default=0.01)
    s.add_argument('--trim-head', type=float, default=3.0)
    s.add_argument('--trim-sweep', default='0,2,3,5,10')
    s.add_argument('--win', type=float, default=20.0); s.add_argument('--hop', type=float, default=5.0)
    s.add_argument('--fps', type=float, default=0.0,
                   help='时间戳列填的是 frame_id 时必须给, 用于把时间域分析换算到秒')
    s.add_argument('--controls', default=None); s.add_argument('--out', default=None)
    s.add_argument('--json', action='store_true')
    c = sub.add_parser('convert-colmap')
    c.add_argument('--images', required=True); c.add_argument('--out', required=True)
    o = sub.add_parser('timeoffset'); o.add_argument('--ref', required=True); o.add_argument('--est', required=True)
    sub.add_parser('selftest')
    a = ap.parse_args()
    if a.cmd == 'selftest':
        selftest(); return
    if a.cmd == 'convert-colmap':
        print("wrote %d poses -> %s" % (convert_colmap(a.images, a.out), a.out)); return
    if a.cmd == 'timeoffset':
        tr, _, qr = load_tum(a.ref); te, _, qe = load_tum(a.est)
        d, cc = estimate_time_offset(tr, qr, te, qe)
        print("dt = %.4f s (t_est + dt ~= t_ref), 归一化互相关 %.4f" % (d, cc)); return
    rep = run(a)
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, 'score.json'), 'w') as f:
            json.dump(rep, f, indent=2, ensure_ascii=False, default=float)
    print(json.dumps(rep, indent=2, ensure_ascii=False, default=float) if a.json else fmt(rep))
    sys.exit(1 if any('作废' in v or 'bug' in v for v in rep['verdict_flags']) else 0)

if __name__ == '__main__':
    main()
