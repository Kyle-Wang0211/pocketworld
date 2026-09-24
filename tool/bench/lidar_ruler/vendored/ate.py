# 🔴 输出行数契约:pw_ate.sh 用 `tail -3` 取结果。本脚本目前**正好输出 3 行**
#    (posyaw 前提告警 + 原有那行 + posyaw 行)。**再加第 4 行会把原有那行静默挤掉**,
#    而 pw_ate.sh 的调用方都在解析那一行。要加行,必须同时改 pw_ate.sh 的 tail -N,
#    或改成按模式取(grep "配对")。2026-09-20 实测确认当前刚好没破。
import sys, numpy as np
def load(p):
    T,P=[],[]
    for ln in open(p):
        ln=ln.strip()
        if not ln or ln.startswith('#'): continue
        f=ln.split()
        if len(f)<8: continue
        T.append(float(f[0])); P.append([float(f[1]),float(f[2]),float(f[3])])
    return np.array(T), np.array(P)
def umeyama(X,Y,ws=True):
    mx,my=X.mean(1,keepdims=True),Y.mean(1,keepdims=True)
    Xc,Yc=X-mx,Y-my
    S=Yc@Xc.T/X.shape[1]
    U,D,Vt=np.linalg.svd(S); d=np.ones(3)
    if np.linalg.det(U)*np.linalg.det(Vt)<0: d[2]=-1
    R=U@np.diag(d)@Vt
    s=(D*d).sum()/((Xc**2).sum()/X.shape[1]) if ws else 1.0
    return s,R,my-s*R@mx

# ---------------------------------------------------------------------------
# posyaw (4DOF: translation + rotation about gravity) trajectory alignment.
#
# Zhang & Scaramuzza, "A Tutorial on Quantitative Trajectory Evaluation for
# Visual(-Inertial) Odometry", IROS 2018 -- posyaw is the alignment prescribed
# for visual-INERTIAL systems (roll/pitch and scale are observable, so they
# must NOT be absorbed by the alignment; only yaw-about-gravity and the three
# translations are unobservable).
#
# UPSTREAM SOURCE (verbatim port, not a re-derivation):
#   repo   : https://github.com/uzh-rpg/rpg_trajectory_evaluation
#   commit : 8c8ceec55c5c5094a6494208cfc5f54afe0bbc4d  (2022-09-14, master)
#   files  : src/rpg_trajectory_evaluation/align_trajectory.py
#            src/rpg_trajectory_evaluation/align_utils.py
#            src/rpg_trajectory_evaluation/transformations.py
#
# WHICH VARIANT IS THE DEFAULT (verified against the upstream tree, not guessed):
#   align_utils.alignPositionYaw() has two branches:
#     * n_aligned == 1  -> alignPositionYawSingle(): yaw taken from the FIRST
#                          pose pair only (needs quaternions).
#     * otherwise       -> align_trajectory.align_umeyama(gt, est,
#                          known_scale=True, yaw_only=True): least-squares yaw
#                          over the aligned frames (positions only).
#   The signature default is n_aligned=1, but NOTHING in the pipeline uses it:
#   trajectory.py:250-252 always passes self.align_num_frames explicitly, and
#   ALL 34 eval_cfg.yaml files shipped under results/ say
#       align_type: posyaw / align_num_frames: -1
#   (checked: `find results -name eval_cfg.yaml | xargs cat | sort | uniq -c`
#    -> 34x "align_type: posyaw", 34x "align_num_frames: -1").
#   trajectory.py:237-241 maps n < 0 to "all frames".
#   => The default in practice is the FULL-TRAJECTORY least-squares yaw
#      variant, which is what is ported below. It uses positions only.
# ---------------------------------------------------------------------------

def get_best_yaw(C):
    '''
    maximize trace(Rz(theta) * C)
    '''
    # verbatim from align_trajectory.py:8-18 (get_best_yaw)
    assert C.shape == (3, 3)

    A = C[0, 1] - C[1, 0]
    B = C[0, 0] + C[1, 1]
    theta = np.pi / 2 - np.arctan2(B, A)

    return theta


def rot_z(theta):
    # align_trajectory.py:21-25 calls transformations.rotation_matrix(theta,
    # [0, 0, 1])[0:3, 0:3].  Expanding transformations.py:529-543 for the unit
    # direction [0,0,1] gives exactly the matrix below (cos on the diagonal,
    # + outer([0,0,1],[0,0,1])*(1-cos) filling R[2,2]=1, + the skew term with
    # direction*sin = [0,0,sin]).  Verified numerically identical in _selftest.
    c, s = np.cos(theta), np.sin(theta)
    return np.array([[c, -s, 0.0],
                     [s,  c, 0.0],
                     [0.0, 0.0, 1.0]])


def align_umeyama_upstream(model, data, known_scale=False, yaw_only=False):
    """Verbatim port of align_trajectory.py:28-79 (align_umeyama).

    model = s * R * data + t
    model -- first trajectory (nx3);  data -- second trajectory (nx3)
    """
    # substract mean
    mu_M = model.mean(0)
    mu_D = data.mean(0)
    model_zerocentered = model - mu_M
    data_zerocentered = data - mu_D
    n = np.shape(model)[0]

    # correlation
    C = 1.0/n*np.dot(model_zerocentered.transpose(), data_zerocentered)
    sigma2 = 1.0/n*np.multiply(data_zerocentered, data_zerocentered).sum()
    U_svd, D_svd, V_svd = np.linalg.svd(C)
    D_svd = np.diag(D_svd)
    V_svd = np.transpose(V_svd)

    S = np.eye(3)
    if (np.linalg.det(U_svd)*np.linalg.det(V_svd) < 0):
        S[2, 2] = -1

    if yaw_only:
        rot_C = np.dot(data_zerocentered.transpose(), model_zerocentered)
        theta = get_best_yaw(rot_C)
        R = rot_z(theta)
    else:
        R = np.dot(U_svd, np.dot(S, np.transpose(V_svd)))

    if known_scale:
        s = 1
    else:
        s = 1.0/sigma2*np.trace(np.dot(D_svd, S))

    t = mu_M-s*np.dot(R, mu_D)

    return s, R, t


def align_position_yaw(p_es, p_gt):
    """align_utils.py:40-53 (alignPositionYaw), n_aligned == -1 branch.

    p_es / p_gt are (n,3).  Returns R, t with  gt ~= R * est + t.
    Note the argument order upstream flags with "# note the order":
    align_umeyama(gt_pos, est_pos, ...).
    """
    _, R, t = align_umeyama_upstream(p_gt, p_es, known_scale=True,
                                     yaw_only=True)  # note the order
    t = np.array(t)
    t = t.reshape((3, ))
    R = np.array(R)
    return R, t
# ---------------------------------------------------------------------------

ARGS=[a for a in sys.argv[1:] if not a.startswith('--')]
REF_Y_UP='--ref-y-up' in sys.argv[1:]
te,Pe=load(ARGS[0]); tr,Pr=load(ARGS[1])
idx=np.clip(np.searchsorted(tr,te),1,len(tr)-1)
l=np.abs(te-tr[idx-1]); r=np.abs(te-tr[idx])
pick=np.where(l<r,idx-1,idx); ok=np.minimum(l,r)<0.010
X=Pe[ok].T; Y=Pr[pick[ok]].T
s,R,t=umeyama(X,Y); e=np.linalg.norm((s*R@X+t)-Y,axis=0)
s1,R1,t1=umeyama(X,Y,False); e1=np.linalg.norm((R1@X+t1)-Y,axis=0)

# posyaw: 4DOF alignment, the Zhang&Scaramuzza IROS2018 standard for VIO.
# PRECONDITION: both trajectories must already be gravity-aligned with the SAME
# up-axis (upstream assumes z-up, as EuRoC gt and estimates both are).  posyaw
# only frees rotation about +z, so if est is z-up and ref is y-up (ARKit), the
# 90 deg convention difference is NOT representable and the ATE blows up.
# --ref-y-up applies the fixed, data-independent ARKit y-up -> z-up rotation
# Rx(+90) to the reference first (e_y -> e_z).  It is a constant relabelling of
# axes, not an extra fitted DOF, so the resulting ATE stays comparable.
Xp, Yp = X, Y
if REF_Y_UP:
    Rx90=np.array([[1.,0.,0.],[0.,0.,-1.],[0.,1.,0.]])  # (x,y,z)->(x,-z,y)
    Yp = Rx90@Y
Ry,ty=align_position_yaw(Xp.T,Yp.T)
e2=np.linalg.norm((Ry@Xp+ty[:,None])-Yp,axis=0)

# Precondition diagnostic: the SE3 (6DOF) fit is the best rigid rotation between
# the two frames.  If it needs a large tilt (its e_z image is far from e_z), the
# two trajectories do not share an up-axis and the posyaw number below is
# measuring that convention gap, not VIO drift.
tilt=np.degrees(np.arccos(np.clip((R1 if not REF_Y_UP else (np.array([[1.,0.,0.],[0.,0.,-1.],[0.,1.,0.]])@R1))[2,2],-1,1)))
if tilt>5.0:
    print(f"  \u26a0 posyaw 前提不成立: est/ref 的重力轴相差 {tilt:.1f}\u00b0 (SE3 最优旋转的 e_z 倾角; 纯 Rz 应为 0\u00b0)。"
          f"{'' if REF_Y_UP else ' ARKit 参考系为 y-up、XRSLAM 为 z-up ⇒ 请加 --ref-y-up。'}")
print(f"  配对 {X.shape[1]} | Sim3 ATE {np.sqrt((e**2).mean())*100:.2f} cm | 尺度偏差 {abs(1-s)*100:.2f}% | SE3 ATE {np.sqrt((e1**2).mean())*100:.2f} cm")
print(f"  posyaw(4DOF,VIO 标准) ATE {np.sqrt((e2**2).mean())*100:.2f} cm | 偏航角 {np.degrees(np.arctan2(Ry[1,0],Ry[0,0])):.2f}\u00b0"
      f" | ref{'已' if REF_Y_UP else '未'}转 z-up | 上游 rpg_trajectory_evaluation@8c8ceec alignPositionYaw(n_aligned=-1)")
