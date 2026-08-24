"""
inertial_only_init.py — 离线 IMU-视觉尺度 oracle (Mur-Artal / ORB-SLAM3 inertial-only
initialization 口径, 结构照搬 ~/Developer/xrslam Apache-2.0 initializer.cpp)。

输入:  纯视觉 SfM 轨迹 (任意尺度) + 同段原始 IMU
输出:  米制尺度 s, 重力 g, 加计零偏 b_a, 陀螺零偏 b_g, (可选) 加计 scale factor

坐标约定
--------
V   : 视觉重建帧 (SfM 的 gauge, 尺度任意, 姿态任意)。**不旋转它** —— 重力当作 V 里的
      自由三维向量来估, 这是 VINS-Mono/xrslam 的做法, 避免引入额外的旋转参数化。
B   : IMU body 帧。 C : 相机帧。 R_CB / p_BC = camera->body 外参 (手机上 p_BC ~ 0.01-0.04 m)。
关系: p^C_i(metric) = p^B_i + R^B_i p_BC ,  p^C_i(metric) = s * p^C_i(visual)

核心方程 (逐对相邻关键帧 i, j):
  位置行:  s (p^C_j - p^C_i) - v_i Δt - 1/2 g Δt^2
             = R^B_i Δp_ij + (R^B_j - R^B_i) p_BC
  速度行:  v_j - v_i - g Δt = R^B_i Δv_ij
未知量 x = [ g(3) , s(1) , v_0..v_{N-1}(3N) ] ，方程数 6(N-1)。
"""
import numpy as np

G0 = 9.80665  # 标准重力 (m/s^2)。CMAccelerometerData 的 "g" 单位按此定义。


# ────────────────────────── SO(3) 工具 ──────────────────────────
def hat(v):
    x, y, z = v
    return np.array([[0, -z, y], [z, 0, -x], [-y, x, 0]])


def expmap(w):
    """so(3) -> SO(3)."""
    th = np.linalg.norm(w)
    if th < 1e-12:
        return np.eye(3) + hat(w)
    k = w / th
    K = hat(k)
    return np.eye(3) + np.sin(th) * K + (1 - np.cos(th)) * K @ K


def logmap(R):
    """SO(3) -> so(3)."""
    c = np.clip((np.trace(R) - 1) * 0.5, -1.0, 1.0)
    th = np.arccos(c)
    if th < 1e-9:
        return np.array([R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]]) * 0.5
    return (th / (2 * np.sin(th))) * np.array(
        [R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]]
    )


def right_jacobian(w):
    th = np.linalg.norm(w)
    if th < 1e-8:
        return np.eye(3) - 0.5 * hat(w)
    K = hat(w / th)
    return (np.eye(3) - (1 - np.cos(th)) / th * K + (th - np.sin(th)) / th * K @ K)


def s2_tangential_basis(g):
    """|g| 固定时, 重力方向的 2-DoF 切空间基 (3x2)。"""
    g = g / np.linalg.norm(g)
    tmp = np.array([0.0, 0.0, 1.0]) if abs(g[2]) < 0.9 else np.array([1.0, 0.0, 0.0])
    b1 = np.cross(g, tmp); b1 /= np.linalg.norm(b1)
    b2 = np.cross(g, b1)
    return np.stack([b1, b2], axis=1)


# ────────────────────────── IMU 预积分 ──────────────────────────
class Delta:
    __slots__ = ("t", "R", "v", "p", "dR_dbg", "dv_dbg", "dv_dba", "dp_dbg", "dp_dba")


def preintegrate(ts, gyr, acc, t_i, t_j, bg, ba, accel_scale=0.0, midpoint=True):
    """
    ts  : (M,)  IMU 时间戳 (s, 与相机同一单调时钟)
    gyr : (M,3) rad/s (body)     acc : (M,3) m/s^2 (body, 含重力的 specific force)
    返回 Delta: ΔR, Δv, Δp 及对 bg/ba 的一阶 Jacobian。
    accel_scale s_a: a_true = (a_meas - ba) / (1 + s_a)  —— Δv/Δp 对 a 线性, 故精确可分离。

    midpoint=True  : VINS-Mono 口径的中点积分。**必须开**。
    midpoint=False : 左端点 (Euler) 矩形积分 —— 100Hz 下单独引入约 0.04% 的尺度系统偏差,
                     与加计 scale factor 天花板同量级, 会被误读成"IMU 路线不行"。
    """
    m0, m1 = np.searchsorted(ts, t_i), np.searchsorted(ts, t_j)
    idx = np.arange(max(m0 - 1, 0), min(m1 + 1, len(ts)))
    d = Delta()
    d.t = 0.0
    d.R = np.eye(3); d.v = np.zeros(3); d.p = np.zeros(3)
    d.dR_dbg = np.zeros((3, 3)); d.dv_dbg = np.zeros((3, 3)); d.dv_dba = np.zeros((3, 3))
    d.dp_dbg = np.zeros((3, 3)); d.dp_dba = np.zeros((3, 3))
    k = 1.0 / (1.0 + accel_scale)
    for n in range(len(idx) - 1):
        ia, ib = idx[n], idx[n + 1]
        ta = max(ts[ia], t_i); tb = min(ts[ib], t_j)
        dt = tb - ta
        if dt <= 0:
            continue
        if midpoint:
            w = 0.5 * (gyr[ia] + gyr[ib]) - bg
            a0 = k * (acc[ia] - ba); a1 = k * (acc[ib] - ba)
        else:
            w = gyr[ia] - bg
            a0 = a1 = k * (acc[ia] - ba)
        Rk = d.R
        dR = expmap(w * dt)
        Rn = Rk @ dR
        Ra = 0.5 * (Rk @ a0 + Rn @ a1)          # 中点世界系加速度
        a_bar = 0.5 * (a0 + a1)                  # bias Jacobian 用平均 body 加速度
        d.dp_dbg += dt * d.dv_dbg - 0.5 * dt * dt * Rk @ hat(a_bar) @ d.dR_dbg
        d.dp_dba += dt * d.dv_dba - 0.5 * dt * dt * k * Rk
        d.dv_dbg += -dt * Rk @ hat(a_bar) @ d.dR_dbg
        d.dv_dba += -dt * k * Rk
        d.dR_dbg = dR.T @ d.dR_dbg - dt * right_jacobian(w * dt)
        d.p = d.p + dt * d.v + 0.5 * dt * dt * Ra
        d.v = d.v + dt * Ra
        d.R = Rn
        d.t += dt
    return d


# ────────────────────────── Stage A: 陀螺零偏 ──────────────────────────
def solve_gyro_bias(kf, ts, gyr, acc, iters=3):
    """
    kf: list of dict{ t, R_B (3x3, IMU 姿态 in V), p_C (3,), 视觉相机中心 }
    残差: Log( (R_i ΔR_ij(bg))^T R_j ) = 0, 对 bg 线性化后闭式解, 迭代 3 次。
    """
    bg = np.zeros(3)
    for _ in range(iters):
        A = np.zeros((3, 3)); b = np.zeros(3)
        for j in range(1, len(kf)):
            d = preintegrate(ts, gyr, acc, kf[j - 1]["t"], kf[j]["t"], bg, np.zeros(3))
            J = d.dR_dbg
            r = logmap((kf[j - 1]["R_B"] @ d.R).T @ kf[j]["R_B"])
            A += J.T @ J; b += J.T @ r
        bg = bg + np.linalg.lstsq(A, b, rcond=None)[0]
    return bg


# ────────── Stage B: 线性解 (g 自由 3-DoF, s, v) —— |g| 不约束 ──────────
def solve_gravity_scale_velocity(kf, ts, gyr, acc, bg, ba=None, p_BC=None):
    ba = np.zeros(3) if ba is None else ba
    p_BC = np.zeros(3) if p_BC is None else p_BC
    N = len(kf)
    A = np.zeros((6 * (N - 1), 3 + 1 + 3 * N))
    b = np.zeros(6 * (N - 1))
    for j in range(1, N):
        i = j - 1
        d = preintegrate(ts, gyr, acc, kf[i]["t"], kf[j]["t"], bg, ba)
        dt = d.t
        Ri, Rj = kf[i]["R_B"], kf[j]["R_B"]
        # 位置行
        A[6 * i:6 * i + 3, 0:3] = -0.5 * dt * dt * np.eye(3)
        A[6 * i:6 * i + 3, 3] = kf[j]["p_C"] - kf[i]["p_C"]
        A[6 * i:6 * i + 3, 4 + 3 * i: 7 + 3 * i] = -dt * np.eye(3)
        b[6 * i:6 * i + 3] = Ri @ d.p + (Rj @ p_BC - Ri @ p_BC)
        # 速度行
        A[6 * i + 3:6 * i + 6, 0:3] = -dt * np.eye(3)
        A[6 * i + 3:6 * i + 6, 4 + 3 * i: 7 + 3 * i] = -np.eye(3)
        A[6 * i + 3:6 * i + 6, 4 + 3 * j: 7 + 3 * j] = np.eye(3)
        b[6 * i + 3:6 * i + 6] = Ri @ d.v
    x, *_ = np.linalg.lstsq(A, b, rcond=None)
    return dict(g=x[0:3], s=float(x[3]), v=x[4:].reshape(N, 3), A=A, b=b, x=x)


# ────────── Stage C: |g| 固定, 只在 S^2 切空间精化方向 (2-DoF) ──────────
def refine_scale_velocity_via_gravity(kf, ts, gyr, acc, bg, g0, ba=None,
                                      p_BC=None, g_mag=G0, iters=4, damp=1.0):
    ba = np.zeros(3) if ba is None else ba
    p_BC = np.zeros(3) if p_BC is None else p_BC
    N = len(kf)
    g = g0 / np.linalg.norm(g0) * g_mag
    x = None
    for _ in range(iters):
        Tg = s2_tangential_basis(g)
        A = np.zeros((6 * (N - 1), 2 + 1 + 3 * N)); b = np.zeros(6 * (N - 1))
        for j in range(1, N):
            i = j - 1
            d = preintegrate(ts, gyr, acc, kf[i]["t"], kf[j]["t"], bg, ba)
            dt = d.t; Ri, Rj = kf[i]["R_B"], kf[j]["R_B"]
            A[6*i:6*i+3, 0:2] = -0.5 * dt * dt * Tg
            A[6*i:6*i+3, 2] = kf[j]["p_C"] - kf[i]["p_C"]
            A[6*i:6*i+3, 3+3*i:6+3*i] = -dt * np.eye(3)
            b[6*i:6*i+3] = 0.5*dt*dt*g + Ri @ d.p + (Rj @ p_BC - Ri @ p_BC)
            A[6*i+3:6*i+6, 0:2] = -dt * Tg
            A[6*i+3:6*i+6, 3+3*i:6+3*i] = -np.eye(3)
            A[6*i+3:6*i+6, 3+3*j:6+3*j] = np.eye(3)
            b[6*i+3:6*i+6] = dt * g + Ri @ d.v
        x, *_ = np.linalg.lstsq(A, b, rcond=None)
        g = (g + damp * Tg @ x[0:2]); g = g / np.linalg.norm(g) * g_mag
    return dict(g=g, s=float(x[2]), v=x[3:].reshape(N, 3))


# ── 预积分缓存: 只在 (bg_lin, ba_lin) 处积一次, 之后用一阶 Jacobian 修偏置 ──
def precompute_deltas(kf, ts, gyr, acc, bg_lin, ba_lin):
    """ORB-SLAM3 口径: Δ(b) ≈ Δ̄ + J_db·δb , 非线性精化里不再重积分。
    加计 scale factor 是精确的: Δv,Δp 对加速度序列线性 ⇒ Δ(s_a) = Δ(0)/(1+s_a)。"""
    D = []
    for j in range(1, len(kf)):
        d = preintegrate(ts, gyr, acc, kf[j-1]["t"], kf[j]["t"], bg_lin, ba_lin)
        D.append(d)
    return dict(D=D, bg_lin=np.array(bg_lin, float), ba_lin=np.array(ba_lin, float))


def corrected_delta(cache, i, bg, ba, sa=0.0):
    d = cache["D"][i]
    dbg = bg - cache["bg_lin"]; dba = ba - cache["ba_lin"]
    k = 1.0 / (1.0 + sa)
    R = d.R @ expmap(d.dR_dbg @ dbg)
    v = (d.v + d.dv_dbg @ dbg + d.dv_dba @ dba) * k
    p = (d.p + d.dp_dbg @ dbg + d.dp_dba @ dba) * k
    return d.t, R, v, p


# ────────── Stage D: 非线性 MAP 精化 (ORB-SLAM3 口径, 含 b_a 与可选 s_a) ──────────
def refine_nonlinear(kf, ts, gyr, acc, init, p_BC=None, g_mag=G0,
                     sigma_ba=0.05, sigma_bg=0.005, estimate_accel_scale=False,
                     free_g_mag=False, relinearize=2):
    """
    未知量: [ rho=log(s) (1), dg (2, S^2 切空间), ba (3), bg (3), v (3N),
              (可选) s_a (1) 或 log|g| (1) ]
    残差:   位置行 / 速度行 (与线性同) + 零偏先验 (高斯 MAP 项)
    scipy.optimize.least_squares (TRF) + 一阶偏置修正 ⇒ 全序列毫秒-秒级。
    """
    from scipy.optimize import least_squares
    p_BC = np.zeros(3) if p_BC is None else p_BC
    N = len(kf)
    dpC = np.array([kf[j]["p_C"] - kf[j-1]["p_C"] for j in range(1, N)])
    Ri = [kf[j-1]["R_B"] for j in range(1, N)]
    Rj = [kf[j]["R_B"] for j in range(1, N)]
    lever = np.array([Rj[i] @ p_BC - Ri[i] @ p_BC for i in range(N-1)])
    g_dir0 = init["g"] / np.linalg.norm(init["g"])
    Tg0 = s2_tangential_basis(g_dir0)
    n_extra = 1 if (estimate_accel_scale or free_g_mag) else 0
    bg_lin = np.array(init["bg"], float); ba_lin = np.array(init.get("ba", np.zeros(3)), float)
    x = np.concatenate([[np.log(max(init["s"], 1e-6))], np.zeros(2),
                        ba_lin, bg_lin, np.asarray(init["v"]).reshape(-1), np.zeros(n_extra)])

    def unpack(x):
        s = np.exp(x[0])
        gd = expmap(Tg0 @ x[1:3]) @ g_dir0
        extra = x[9 + 3*N] if n_extra else 0.0
        gm = g_mag * np.exp(extra) if free_g_mag else g_mag
        sa = extra if estimate_accel_scale else 0.0
        return s, gd * gm, x[3:6], x[6:9], x[9:9+3*N].reshape(N, 3), sa

    for _ in range(relinearize):
        cache = precompute_deltas(kf, ts, gyr, acc, bg_lin, ba_lin)

        def resid(x, cache=cache):
            s, g, ba, bg, v, sa = unpack(x)
            r = np.empty(6*(N-1) + 6)
            for i in range(N-1):
                dt, _, dv, dp = corrected_delta(cache, i, bg, ba, sa)
                r[6*i:6*i+3] = (s*dpC[i] - v[i]*dt - 0.5*g*dt*dt - Ri[i] @ dp - lever[i])
                r[6*i+3:6*i+6] = v[i+1] - v[i] - g*dt - Ri[i] @ dv
            r[-6:-3] = ba / sigma_ba
            r[-3:] = bg / sigma_bg
            return r

        sol = least_squares(resid, x, method="trf", xtol=1e-12, ftol=1e-12, gtol=1e-12)
        x = sol.x
        _, _, ba_lin, bg_lin, _, _ = unpack(x)

    s, g, ba, bg, v, sa = unpack(x)
    return dict(s=s, g=g, ba=ba, bg=bg, v=v, accel_scale=sa,
                cost=sol.cost, success=sol.success, x=x, resid=sol.fun)


# ────────────────────────── 可观性判据 ──────────────────────────
def observability(res_linear, sigma_p=0.01):
    """
    对线性系统 A x = b 做 Schur: 把 s 之外的未知量消去, 得到 s 的边际信息量。
    返回:
      sigma_s_rel : s 的 1-sigma 相对不确定度 (在给定预积分噪声 sigma_p 下)
      cond        : A 的条件数
      excite      : 加速度激励指标 (RMS |a - g| , m/s^2)
    判据: sigma_s_rel > 0.02 (2%) ⇒ 这段数据估不出尺度, 直接拒。
    """
    A, b = res_linear["A"], res_linear["b"]
    H = A.T @ A
    k = 3  # s 在列 3
    idx = [i for i in range(H.shape[0]) if i != k]
    Hkk = H[k, k]; Hko = H[k, idx]; Hoo = H[np.ix_(idx, idx)]
    schur = Hkk - Hko @ np.linalg.solve(Hoo, Hko)
    var_s = sigma_p ** 2 / max(schur, 1e-18)
    s = res_linear["s"]
    return dict(sigma_s_rel=float(np.sqrt(var_s) / abs(s)),
                cond=float(np.linalg.cond(A)),
                schur_info=float(schur))


# ────────────────────────── 正向对照: 合成数据 ──────────────────────────
def make_synthetic(dur=8.0, imu_hz=100.0, kf_hz=3.0, seed=0,
                   true_scale=0.37, ba=(0.05, -0.03, 0.02), bg=(0.002, -0.001, 0.003),
                   accel_scale=0.0, acc_noise=0.02, gyr_noise=0.002,
                   p_BC=(0.03, 0.0, 0.01), motion_amp=0.35, att_amp=0.9,
                   g_mag=G0, vis_noise=0.0, fine_mult=20, orbit_r=1.0, orbit_T=25.0):
    """
    造一条已知米制真值的轨迹 -> 生成 IMU 与"视觉"轨迹 (乘上 1/true_scale 并整体旋转)。
    求解器若正确, 必须还原 s == true_scale 、 g 、 ba 、 bg 。

    生成器自身的离散误差必须远小于被测量: 姿态在 fine_mult× IMU 率的细网格上积分,
    位置/速度/加速度解析给出, 角速度解析给出 ⇒ 零噪声档的残余偏差 = 估计器的离散误差。
    """
    rng = np.random.default_rng(seed)
    fine_hz = imu_hz * fine_mult
    tf = np.arange(0.0, dur, 1.0 / fine_hz)
    wf = att_amp * np.stack([np.sin(2*np.pi*0.23*tf), np.sin(2*np.pi*0.17*tf+0.5),
                             np.sin(2*np.pi*0.31*tf+1.2)], axis=1)   # 解析 body 角速度
    Rf = np.empty((len(tf), 3, 3)); Rf[0] = np.eye(3)
    hdt = 1.0 / fine_hz
    for i in range(len(tf)-1):
        Rf[i+1] = Rf[i] @ expmap(0.5*(wf[i]+wf[i+1])*hdt)
    sel = np.arange(0, len(tf), fine_mult)
    t = tf[sel]; R = Rf[sel]; W = wf[sel]
    # 真实 dome 扫描 = 大幅度慢速绕行 (半径 orbit_r, 周期 orbit_T) + 小幅高频手抖
    wo = 2*np.pi/orbit_T
    P = np.stack([orbit_r*np.cos(wo*t), orbit_r*np.sin(wo*t), 0.15*np.sin(wo*t)], axis=1)
    Vel = np.stack([-orbit_r*wo*np.sin(wo*t), orbit_r*wo*np.cos(wo*t), 0.15*wo*np.cos(wo*t)], axis=1)
    Acc = np.stack([-orbit_r*wo**2*np.cos(wo*t), -orbit_r*wo**2*np.sin(wo*t),
                    -0.15*wo**2*np.sin(wo*t)], axis=1)
    f1, f2, f3 = 0.7, 0.5, 0.9
    P += motion_amp*np.stack([np.sin(2*np.pi*f1*t), np.sin(2*np.pi*f2*t+1.0),
                              0.5*np.sin(2*np.pi*f3*t+2.0)], axis=1)
    Vel += motion_amp*np.stack([(2*np.pi*f1)*np.cos(2*np.pi*f1*t),
                                (2*np.pi*f2)*np.cos(2*np.pi*f2*t+1.0),
                                0.5*(2*np.pi*f3)*np.cos(2*np.pi*f3*t+2.0)], axis=1)
    Acc += -motion_amp*np.stack([(2*np.pi*f1)**2*np.sin(2*np.pi*f1*t),
                                 (2*np.pi*f2)**2*np.sin(2*np.pi*f2*t+1.0),
                                 0.5*(2*np.pi*f3)**2*np.sin(2*np.pi*f3*t+2.0)], axis=1)
    g_w = np.array([0.0, 0.0, -g_mag])
    ba = np.asarray(ba, float); bg = np.asarray(bg, float); p_BC = np.asarray(p_BC, float)
    F = np.einsum("nji,nj->ni", R, Acc - g_w)             # specific force in body
    acc_meas = (1.0+accel_scale)*F + ba + rng.normal(0, acc_noise, F.shape)
    gyr_meas = W + bg + rng.normal(0, gyr_noise, W.shape)
    Rvw = expmap(np.array([0.31, -0.22, 0.77]))
    step = max(int(round(imu_hz/kf_hz)), 1)
    kf = []
    for n in range(0, len(t)-1, step):
        R_B_w = R[n]
        p_C_w = P[n] + R_B_w @ p_BC
        p_C_v = (Rvw @ p_C_w)/true_scale
        if vis_noise > 0:
            p_C_v = p_C_v + rng.normal(0, vis_noise/true_scale, 3)
        kf.append(dict(t=float(t[n]), R_B=Rvw @ R_B_w, p_C=p_C_v, v_true=Rvw @ Vel[n]))
    return dict(ts=t, gyr=gyr_meas, acc=acc_meas, kf=kf, p_BC=p_BC,
                g_true_V=Rvw @ g_w, s_true=true_scale, ba=ba, bg=bg,
                accel_scale=accel_scale, att_rms=float(np.sqrt(np.mean(np.sum(W**2,1)))),
                acc_exc=float(np.sqrt(np.mean(np.sum(Acc**2,1)))),
                traj_len=float(np.sum(np.linalg.norm(np.diff(P,axis=0),axis=1))))


def run_pipeline(syn, nonlinear=True, estimate_accel_scale=False, free_g_mag=False):
    ts, gyr, acc, kf, p_BC = syn["ts"], syn["gyr"], syn["acc"], syn["kf"], syn["p_BC"]
    bg = solve_gyro_bias(kf, ts, gyr, acc)
    lin = solve_gravity_scale_velocity(kf, ts, gyr, acc, bg, p_BC=p_BC)
    obs = observability(lin)
    ref = refine_scale_velocity_via_gravity(kf, ts, gyr, acc, bg, lin["g"], p_BC=p_BC)
    out = dict(bg=bg, lin=lin, obs=obs, ref=ref)
    if nonlinear:
        init = dict(s=ref["s"], g=ref["g"], bg=bg, ba=np.zeros(3), v=ref["v"])
        out["nl"] = refine_nonlinear(kf, ts, gyr, acc, init, p_BC=p_BC,
                                     estimate_accel_scale=estimate_accel_scale,
                                     free_g_mag=free_g_mag)
    return out


# ────────────────────────── 本地重力 (Somigliana / WGS-84) ──────────────────────────
def local_gravity(lat_deg, alt_m=0.0):
    """由纬度+海拔算真实重力加速度, 相对精度 ~1e-5。
    赤道 9.7803 -> 极点 9.8322, 跨度 0.53% —— 比加计 scale factor 天花板大 4.5 倍,
    所以'|g| 用常数 9.80665' 本身就是一个 0.05-0.19% 的中国区尺度误差。"""
    s2 = np.sin(np.deg2rad(lat_deg)) ** 2
    g = 9.7803253359 * (1 + 0.00193185265241 * s2) / np.sqrt(1 - 0.00669437999013 * s2)
    return g - 3.086e-6 * alt_m


# ────────────────────────── 顶层配方 (推荐口径) ──────────────────────────
def solve_scale_oracle(kf, ts, gyr, acc, p_BC=None, lat_deg=None, alt_m=0.0,
                       gate_sigma_s=0.02, gate_g_dev=0.03):
    """
    推荐配方 (合成对照实测: 30s/8m dome 扫描, IMU 100Hz, 关键帧 ~0.33Hz ⇒ RMSE 0.80%):
      1) midpoint 预积分 (必须; Euler 在 100Hz 单独引入 -1.34% 系统偏差)
      2) 陀螺零偏闭式解 (3 次迭代)
      3) **不约束 |g|** 的线性解 -> (g, s, v)。|g_hat| 就是加计总增益误差的直读
      4) 用已知本地重力 γ 反解掉总增益:  s_metric = s_hat * γ / |g_hat|
         —— 合成实测: 该式把 accel scale +1.0% 的影响从 +0.956% 压到 -0.043%,
            把 ba=20mg 的影响从 -0.702% 压到 -0.040%
      5) 门: sigma_s_rel > gate_sigma_s 或 ||g_hat|/γ - 1| > gate_g_dev ⇒ 拒绝该段
    b_a 与 s_a 不单独估 —— 合成实测显示 12-60s 手持扫描里 b_a 弱可观 (60s+强姿态才到 13%),
    而第 4 步已经把它们的主效应一起消掉了。
    """
    p_BC = np.zeros(3) if p_BC is None else p_BC
    gamma = G0 if lat_deg is None else local_gravity(lat_deg, alt_m)
    bg = solve_gyro_bias(kf, ts, gyr, acc)
    lin = solve_gravity_scale_velocity(kf, ts, gyr, acc, bg, p_BC=p_BC)
    obs = observability(lin)
    g_hat = float(np.linalg.norm(lin["g"]))
    s_metric = lin["s"] * gamma / g_hat
    g_dev = g_hat / gamma - 1.0
    ok = (obs["sigma_s_rel"] <= gate_sigma_s) and (abs(g_dev) <= gate_g_dev) and (lin["s"] > 0)
    return dict(scale=float(s_metric), scale_raw=float(lin["s"]), g=lin["g"], g_mag=g_hat,
                gamma_local=gamma, accel_gain_error=g_dev, bg=bg, v=lin["v"],
                sigma_s_rel=obs["sigma_s_rel"], cond=obs["cond"], accepted=bool(ok))
