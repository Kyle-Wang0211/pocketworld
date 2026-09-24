#!/usr/bin/env python3
"""合成验证:不开摄像头、不拍摄,证明尺度仲裁工具能把尺度恢复到 1.000±0.5%。

══ 这一步为什么不可省 ═══════════════════════════════════════════════════════
`charuco_scale_arbiter.py` 的全部价值就是那个尺度因子 s。真机上 s 没有真值
(板本身带印刷误差),所以「s 对不对」**只能在合成数据上验**:合成时我们
**知道**相机每一帧在板系里的米制位置,也就**知道**每条轨迹该落出什么 s。

══ 怎么合成(不自研,全用 OpenCV 自己的函数)═══════════════════════════════
1. 画板   : `CharucoBoard(...).generateImage((W,H))` —— 官方样例用的就是它
            https://github.com/opencv/opencv/blob/4.13.0/samples/cpp/tutorial_code/objectDetection/create_board_charuco.cpp
   🔑 纹理像素 ↔ 板物点的对应是 **实测出来的,不是猜的**(见 `--probe-texture`):
        x = u / W_img * (squares_x * square)      ← 分母是 **W_img,不是 W_img−1**
        y = v / H_img * (squares_y * square),  z = 0
      验法:对 `generateImage` 出来的纹理直接跑 `findHomography`,得到的四角
      是 (0,0) / ((W−1)/W·bw, …) —— 正好对上上式。
      🔴 第一版我写的是 `W_img−1`,那是 **0.05% 的系统尺度误差**,恰好和我们
         在真机上追的 4.13% 同一量级的 1/80 —— 合成验证里这种 bug **不会报错,
         只会让判据偷偷偏一点**,所以下面把「渲染几何」单独立了一道硬闸。
2. 渲染   : 板是**平面**、零畸变 ⇒ 平面→像面**就是一个单应**。
            `cv2.projectPoints` 投板的 4 个角 → `cv2.getPerspectiveTransform`
            → `cv2.warpPerspective`。这是**精确**的针孔渲染,不是近似:
            本脚本会亲自验 `M∘formula(obj)` 与 `cv2.projectPoints(obj)` 的最大差
            (实测 5.7e-5 px)。
   🔑 **超采样 SS×**:`warpPerspective` 每个输出像素只做一次双线性取样,
      3× 缩小一张二值纹理会混叠。按 SS 倍分辨率渲染再**块平均**降采样
      (= 真实传感器的面积积分)。实测 SS 1→3 让恢复出的相机中心误差
      从 **1.88 mm 降到 0.41 mm**(中位,0.45–0.9 m),最坏 30.9 → 4.3 mm。
3. 相机位姿: look-at 构造。
   🔴 **相机必须在板的 −Z 侧**。OpenCV ≥4.7 的板物点是 x 右 / y 下,官方教程原话:
      "the coordinate systems are placed in the boards plane with the Z axis
       pointing **in** the plane (previously the axis pointed out the plane)"
      (https://docs.opencv.org/4.x/df/d4a/tutorial_charuco_detection.html,
       改动来自 opencv_contrib#3174)。搞反就是镜像,镜像的 ArUco 解不出来 ⇒
      检出率直接归零,这一条自带阴性对照。
4. 落盘   : 写成与台架 `run-*` **同格式**的录制目录,验的是工具的**真实读取路径**,
            不是一条绕过 frames.bin / frames.pwvi / intrinsics.jsonl 的测试捷径。

══ 五条被仲裁的轨迹 ═════════════════════════════════════════════════════════
把真值相机中心 C_b 施加一个**任意刚体变换**(随机旋转 R_rand + 平移)得到
p_rigid,姿态同步写成 R_rand·R_bc(位置与姿态必须同处一个世界系,否则
`--lever-mm` 那条就验了个寂寞):
  truth_metric : p = p_rigid            ⇒ 期望过报因子 k = 1.0000
  over_0413    : p = 1.0413 × p_rigid   ⇒ k = 1.0413(照抄真机那个 4.13%)
  under_0800   : p = 0.92   × p_rigid   ⇒ k = 0.9200
  noisy_metric : p_rigid + 3 mm 高斯噪声 ⇒ k = 1.0000
  lever_body   : p = p_rigid − R·p_bc,p_bc = (10, −20, 33.75) mm,
                 仲裁时喂 `--lever-mm`  ⇒ k = 1.0000(杠杆臂往返自证)
(k = 1/s;s 是「轨迹 × s = 米」。)

══ 判据(硬闸,不过就 exit 1)═══════════════════════════════════════════════
 ① 渲染几何    : max |M∘formula(obj) − projectPoints(obj)| ≤ 0.01 px
                 —— 这是渲染器唯一的假设,它必须是精确的。
 ② 纹理映射    : 实测纹理单应 vs 上面那个公式 ≤ 0.05 px
 ③ 检出率      : ≥ 90%
 ④ **板系位置** : 恢复出的相机中心 vs 合成真值,RMSE ≤ 3 mm,
                 且两者之间的 Umeyama 尺度在 1.000±0.2% —— **这是主判据**
 ⑤ 五条轨迹    : |恢复 k − 期望 k| / 期望 k ≤ 0.5%
 ⑥ 诊断(报数不设闸): 检出角点 vs projectPoints 的残差。
    🔑 实测它是 ~0.4 px 的**近似常量像素偏置**,与渲染无关 —— 证据:把同一张纹理
       1:1 贴到大画布上直接检测,偏置只有 0.0103 px;而 ①②已把渲染几何钉死到
       1e-5 px。它是 ChArUco 角点在**板变小之后**的亚像素定位偏置,真机上同样存在。
       常量像素偏置主要污染**平移**,不污染**尺度**,而尺度才是本工具的输出 ⇒
       这里如实报数,不拿它当闸。

跑法:
  python3 synth_verify.py                      # 系统临时目录,跑完删
  python3 synth_verify.py --work /tmp/synth    # 指定目录并保留
  python3 synth_verify.py --probe-texture      # 只打印纹理↔物点映射的实测结果
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
ARBITER = os.path.join(HERE, 'charuco_scale_arbiter.py')

# 板:照抄官方样例 aruco_detect_board_charuco.py 帮助里的示例
#     (-w=5 -h=7 -sl=0.04 -ml=0.02 -d=10),d=10 就是 DICT_6X6_250。
SQX, SQY = 5, 7
SQUARE_M, MARKER_M = 0.04, 0.02
DICT_NAME = 'DICT_6X6_250'

# 相机:照抄真机录制 run-4ad6e500 的第 0 帧(1920×1440 + ARKit 内参)
IMG_W, IMG_H = 1920, 1440
FX = FY = 1279.01953125
CX, CY = 957.751708984375, 719.0894775390625

N_FRAMES = 80
FPS = 30.0
T0_NS = 78685_122068208          # 与真机录制同量级的时间戳起点
TEX_PX_PER_M = 10000.0           # 纹理分辨率,远高于成像分辨率 ⇒ 只降采样不升采样
SUPERSAMPLE = 3


def look_at(C, target, up):
    """OpenCV 相机系(x 右 / y 下 / z 前)的 look-at,返回 R_bc(相机→板)。"""
    z = target - C
    z = z / np.linalg.norm(z)
    d = -up                                    # 相机的「下」大致沿 −up
    d = d - np.dot(d, z) * z
    d = d / np.linalg.norm(d)
    x = np.cross(d, z)                         # 右手系:x = y × z
    x = x / np.linalg.norm(x)
    return np.column_stack([x, d, z])


def make_trajectory():
    """相机中心在板系里的真值轨迹(米)。板中心 (0.10, 0.14, 0),相机在 −Z 侧。"""
    center = np.array([SQX * SQUARE_M / 2.0, SQY * SQUARE_M / 2.0, 0.0])
    up = np.array([0.0, -1.0, 0.0])            # 板图里的「上」就是 −Y
    poses = []
    for i in range(N_FRAMES):
        u = i / (N_FRAMES - 1.0)
        # 横扫 + 升降 + 远近 —— Sim3 要求运动不退化;
        # 同时保证不是长时间正对板(正对时平面 PnP 的深度最弱,实测 0.9 m 正对
        # 单帧相机中心误差能到 30 mm,而 35° 斜视只有 1.9 mm)。
        ang = np.deg2rad(-35.0 + 70.0 * u)
        dist = 0.45 + 0.35 * (0.5 - 0.5 * np.cos(2 * np.pi * u))
        Cx = center[0] + dist * np.sin(ang)
        Cz = -dist * np.cos(ang)
        Cy = center[1] + 0.12 * np.sin(2 * np.pi * u) - 0.04
        C = np.array([Cx, Cy, Cz])
        tgt = center + np.array([0.03 * np.cos(3 * u), 0.03 * np.sin(3 * u), 0.0])
        poses.append((C, look_at(C, tgt, up)))
    return poses


def K_at(ss):
    """超采样 ss 倍时的内参。像素**面积**中心要跟着走:c' = (c+0.5)·ss − 0.5。"""
    return np.array([[FX * ss, 0.0, (CX + 0.5) * ss - 0.5],
                     [0.0, FY * ss, (CY + 0.5) * ss - 0.5],
                     [0.0, 0.0, 1.0]])


def tex_to_obj(uv, tex_wh, board_wh):
    """纹理像素 → 板物点(米)。分母是 W/H 本身,不是 W−1 —— 见文件头。"""
    Wp, Hp = tex_wh
    bw, bh = board_wh
    return np.stack([uv[:, 0] / Wp * bw, uv[:, 1] / Hp * bh], 1)


def render(board_img, board_wh, C, R_bc, dist, ss, noise_sigma, rng):
    """平面 → 单应 → warpPerspective,再块平均降采样。返回 (img, rvec, tvec)。"""
    bw, bh = board_wh
    R_cb = R_bc.T
    tvec = (-R_cb @ C).reshape(3, 1)
    rvec, _ = cv2.Rodrigues(R_cb)
    Hp, Wp = board_img.shape[:2]
    objq = np.array([[0.0, 0.0, 0.0], [bw, 0.0, 0.0],
                     [bw, bh, 0.0], [0.0, bh, 0.0]], dtype=np.float64)
    proj, _ = cv2.projectPoints(objq, rvec, tvec, K_at(ss), dist)
    src = np.array([[0, 0], [Wp, 0], [Wp, Hp], [0, Hp]], dtype=np.float32)
    M = cv2.getPerspectiveTransform(src, proj.reshape(-1, 2).astype(np.float32))
    big = cv2.warpPerspective(board_img, M, (IMG_W * ss, IMG_H * ss),
                              flags=cv2.INTER_LINEAR,
                              borderMode=cv2.BORDER_CONSTANT, borderValue=200)
    if ss > 1:
        big = big.reshape(IMG_H, ss, IMG_W, ss).mean(axis=(1, 3))
        img = np.clip(big, 0, 255).astype(np.uint8)
    else:
        img = big
    if noise_sigma > 0:
        img = np.clip(img.astype(np.float32)
                      + rng.normal(0.0, noise_sigma, img.shape), 0, 255).astype(np.uint8)
    return img, rvec, tvec, M


def rmat_to_quat(R):
    tr = R[0, 0] + R[1, 1] + R[2, 2]
    if tr > 0:
        S = math.sqrt(tr + 1.0) * 2
        return ((R[2, 1] - R[1, 2]) / S, (R[0, 2] - R[2, 0]) / S,
                (R[1, 0] - R[0, 1]) / S, 0.25 * S)
    if R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        S = math.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        return (0.25 * S, (R[0, 1] + R[1, 0]) / S, (R[0, 2] + R[2, 0]) / S,
                (R[2, 1] - R[1, 2]) / S)
    if R[1, 1] > R[2, 2]:
        S = math.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        return ((R[0, 1] + R[1, 0]) / S, 0.25 * S, (R[1, 2] + R[2, 1]) / S,
                (R[0, 2] - R[2, 0]) / S)
    S = math.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
    return ((R[0, 2] + R[2, 0]) / S, (R[1, 2] + R[2, 1]) / S, 0.25 * S,
            (R[1, 0] - R[0, 1]) / S)


def umeyama_scale(model, data):
    """rpg_trajectory_evaluation@8c8ceec align_trajectory.align_umeyama 的尺度分支。"""
    mu_M, mu_D = model.mean(0), data.mean(0)
    mz, dz = model - mu_M, data - mu_D
    n = len(model)
    C = 1.0 / n * np.dot(mz.T, dz)
    sigma2 = 1.0 / n * np.multiply(dz, dz).sum()
    U, D, V = np.linalg.svd(C)
    D = np.diag(D)
    V = np.transpose(V)
    S = np.eye(3)
    if np.linalg.det(U) * np.linalg.det(V) < 0:
        S[2, 2] = -1
    R = np.dot(U, np.dot(S, np.transpose(V)))
    s = 1.0 / sigma2 * np.trace(np.dot(D, S))
    t = mu_M - s * np.dot(R, mu_D)
    res = np.linalg.norm((s * (R @ data.T).T + t) - model, axis=1)
    return s, float(np.sqrt((res ** 2).mean()))


def write_tum(path, ts_ns, P, Q):
    with open(path, 'w') as f:
        for t, p, q in zip(ts_ns, P, Q):
            f.write(f'{t / 1e9:.9f} {p[0]:.9f} {p[1]:.9f} {p[2]:.9f} '
                    f'{q[0]:.9f} {q[1]:.9f} {q[2]:.9f} {q[3]:.9f}\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', help='工作目录(默认系统临时目录,跑完删)')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--noise-sigma', type=float, default=2.0,
                    help='渲染后加的高斯像素噪声 sigma(0 = 干净)')
    ap.add_argument('--supersample', type=int, default=SUPERSAMPLE)
    ap.add_argument('--tol-pct', type=float, default=0.5, help='尺度容差,%%')
    ap.add_argument('--seed', type=int, default=20260922)
    ap.add_argument('--probe-texture', action='store_true',
                    help='只实测纹理↔物点映射然后退出')
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    dist = np.zeros((5, 1))
    K1 = K_at(1)
    bw, bh = SQX * SQUARE_M, SQY * SQUARE_M

    aruco_dict = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, DICT_NAME))
    board = cv2.aruco.CharucoBoard((SQX, SQY), SQUARE_M, MARKER_M, aruco_dict)
    detector = cv2.aruco.CharucoDetector(board)
    board_img = board.generateImage((int(bw * TEX_PX_PER_M), int(bh * TEX_PX_PER_M)))
    Hp, Wp = board_img.shape
    print(f'板图 {Wp}×{Hp} px = {bw * 1000:.0f}×{bh * 1000:.0f} mm'
          f'  (OpenCV {cv2.__version__})')

    # ── 闸 ②:实测纹理↔物点映射,验证 `u/Wp*bw` 这个公式 ─────────────────
    cc0, ci0, _, _ = detector.detectBoard(cv2.cvtColor(board_img, cv2.COLOR_GRAY2BGR))
    obj_all = board.getChessboardCorners()
    pred = np.stack([obj_all[ci0.ravel(), 0] / bw * Wp,
                     obj_all[ci0.ravel(), 1] / bh * Hp], 1)
    tex_err = float(np.abs(pred - cc0.reshape(-1, 2)).max())
    print(f'纹理映射实测:公式 u=x/bw·Wp 与纹理上检出的角点最大差 {tex_err:.4f} px '
          f'(n={len(pred)})')
    if a.probe_texture:
        Ht, _ = cv2.findHomography(cc0.reshape(-1, 2).astype(np.float64),
                                   obj_all[ci0.ravel(), :2].astype(np.float64))
        q = cv2.perspectiveTransform(
            np.array([[[0., 0.]], [[Wp - 1., 0.]], [[Wp - 1., Hp - 1.]], [[0., Hp - 1.]]]),
            Ht).reshape(-1, 2)
        print('实测单应把纹理像素 (0,0)/(Wp-1,Hp-1) 映到(米):',
              np.round(q, 6).tolist())
        print(f'  对比 (Wp-1)/Wp·bw = {(Wp - 1) / Wp * bw:.6f},  bw = {bw:.6f}'
              '  ⇒ 分母是 Wp,不是 Wp−1')
        return 0

    poses = make_trajectory()
    ts_ns = [T0_NS + int(round(i / FPS * 1e9)) for i in range(len(poses))]

    work = a.work or tempfile.mkdtemp(prefix='charuco_synth_')
    rec = os.path.join(work, 'run-synthetic')
    os.makedirs(rec, exist_ok=True)

    # ── 渲染 + 逐帧落盘(不在内存里囤 80 帧)──────────────────────────────
    geom_err = 0.0
    det_res = []
    n_seen = 0
    nbytes = IMG_W * IMG_H
    with open(os.path.join(rec, 'frames.bin'), 'wb') as fb, \
         open(os.path.join(rec, 'frames.pwvi'), 'w') as fp, \
         open(os.path.join(rec, 'camera_index.csv'), 'w') as fc, \
         open(os.path.join(rec, 'intrinsics.jsonl'), 'w') as fi:
        fc.write('timestamp_ns,relative_path\n')
        for k, ((C, R_bc), t_ns) in enumerate(zip(poses, ts_ns)):
            img, rvec, tvec, M = render(board_img, (bw, bh), C, R_bc, dist,
                                        a.supersample, a.noise_sigma, rng)
            # ── 闸 ①:渲染几何 —— M∘formula(obj) 必须逐点等于 projectPoints(obj)
            tu = np.stack([obj_all[:, 0] / bw * Wp, obj_all[:, 1] / bh * Hp,
                           np.ones(len(obj_all))], 1)
            p1 = (M @ tu.T).T
            # 回到 1× 像素:像素**面积**换算,与 K_at() 里的 (c+0.5)·ss−0.5 互逆
            p1 = (p1[:, :2] / p1[:, 2:3] + 0.5) / a.supersample - 0.5
            p2, _ = cv2.projectPoints(obj_all, rvec, tvec, K1, dist)
            geom_err = max(geom_err, float(np.abs(p1 - p2.reshape(-1, 2)).max()))

            cc, ci, _, _ = detector.detectBoard(cv2.cvtColor(img, cv2.COLOR_GRAY2BGR))
            if ci is not None and len(ci) >= 6:
                n_seen += 1
                pr, _ = cv2.projectPoints(obj_all[ci.ravel()], rvec, tvec, K1, dist)
                det_res.append(pr.reshape(-1, 2) - cc.reshape(-1, 2))

            fb.write(img.tobytes())
            fp.write(json.dumps({'frame': k, 'offset': k * nbytes, 'len': nbytes,
                                 'keyframe': True, 'gop': k}) + '\n')
            fc.write(f'{t_ns},{k}\n')
            fi.write(json.dumps({'t': t_ns / 1e9,
                                 'intrinsics_fxfycxcy': [FX, FY, CX, CY],
                                 'exposure_s': 0.008}) + '\n')
            if k % 20 == 0:
                print(f'  渲染 {k}/{len(poses)}', flush=True)
    json.dump({'schema_version': 1, 'recording_id': 'synthetic-charuco',
               'camera': {'width': IMG_W, 'height': IMG_H, 'nominal_fps': int(FPS),
                          'pixel_format': 'luma8_from_420f_full_range'},
               'frame_count': len(poses)},
              open(os.path.join(rec, 'recording_manifest.json'), 'w'), indent=1)

    d = np.concatenate(det_res) if det_res else np.zeros((1, 2))
    det_bias = d.mean(0)
    det_rmse = float(np.sqrt((d ** 2).sum(1).mean()))
    print(f'\n渲染几何(闸①)  max|M∘formula − projectPoints| = {geom_err:.6f} px')
    bias_txt = f'({det_bias[0]:+.3f}, {det_bias[1]:+.3f})'
    print(f'检测诊断(⑥)      检出 {n_seen}/{len(poses)};'
          f' 角点 vs projectPoints  bias {bias_txt} px,'
          f' RMSE {det_rmse:.3f} px (n={len(d)})')

    # ── 五条被仲裁的轨迹 ────────────────────────────────────────────────
    C_true = np.array([p[0] for p in poses])
    ax = rng.normal(size=3)
    ax /= np.linalg.norm(ax)
    R_rand, _ = cv2.Rodrigues((ax * 1.1).reshape(3, 1))
    P_rigid = (R_rand @ C_true.T).T + np.array([3.7, -1.2, 0.8])
    # 姿态要与位置**同处一个世界系**,否则 --lever-mm 那条会验了个寂寞
    R_traj = [R_rand @ p[1] for p in poses]
    Q_traj = [rmat_to_quat(R) for R in R_traj]

    # 杠杆臂往返:body 位姿 = 相机位置 − R·p_bc;喂 --lever-mm 应当原样还原成 1.0000
    LEVER = np.array([0.010, -0.020, 0.03375])
    P_body = np.array([P_rigid[i] - R_traj[i] @ LEVER for i in range(len(poses))])

    cases = {
        'truth_metric': (1.0, P_rigid.copy(), None),
        'over_0413': (1.0413, P_rigid * 1.0413, None),
        'under_0800': (0.92, P_rigid * 0.92, None),
        'noisy_metric': (1.0, P_rigid + rng.normal(0.0, 0.003, P_rigid.shape), None),
        'lever_body': (1.0, P_body, LEVER),
    }
    traj_args = []
    for nm, (_k, P, lev) in cases.items():
        p = os.path.join(rec, f'{nm}.tum')
        write_tum(p, ts_ns, P, Q_traj)
        traj_args += ['--traj', f'{nm}={p}']
        if lev is not None:
            traj_args += ['--lever-mm',
                          f'{nm}={lev[0] * 1000},{lev[1] * 1000},{lev[2] * 1000}']

    out = os.path.join(work, 'arb')
    cmd = [sys.executable, ARBITER, '--recording', rec,
           '--squares-x', str(SQX), '--squares-y', str(SQY),
           '--square-mm', str(SQUARE_M * 1000), '--marker-mm', str(MARKER_M * 1000),
           '--dict', DICT_NAME, '--out', out] + traj_args
    print('\n$ ' + ' '.join(cmd) + '\n')
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        return 1

    rep = json.load(open(os.path.join(out, 'scale_report.json')))
    # 板系位置真值对照(闸④)
    rows = [json.loads(l) for l in open(os.path.join(out, 'board_poses.jsonl'))]
    by_frame = {r_['frame']: r_['cam_in_board_m'] for r_ in rows}
    idx = [i for i in range(len(poses)) if i in by_frame]
    P_rec = np.array([by_frame[i] for i in idx])
    P_gt = C_true[idx]
    pos_rmse_mm = float(np.sqrt((np.linalg.norm(P_rec - P_gt, axis=1) ** 2).mean()) * 1000)
    pos_max_mm = float(np.linalg.norm(P_rec - P_gt, axis=1).max() * 1000)
    s_board, s_res = umeyama_scale(P_gt, P_rec)

    ok = True

    def gate(cond, good, bad):
        nonlocal ok
        print(('  ✅ ' if cond else '  🔴 ') + (good if cond else bad))
        if not cond:
            ok = False

    print('══ 判据 ══════════════════════════════════════════════════════')
    gate(geom_err <= 0.01,
         f'① 渲染几何 max|M∘formula − projectPoints| = {geom_err:.6f} px ≤ 0.01',
         f'① 渲染几何 {geom_err:.6f} px > 0.01 —— 单应/内参/超采样有 bug')
    gate(tex_err <= 0.05,
         f'② 纹理映射公式与实测差 {tex_err:.4f} px ≤ 0.05',
         f'② 纹理映射差 {tex_err:.4f} px > 0.05 —— u=x/bw·Wp 这个假设不成立')
    dr = rep['frames_detected'] / max(1, rep['frames_examined'])
    gate(dr >= 0.90,
         f'③ 检出率 {dr:.1%} ≥ 90%(重投影中位 {rep["reproj_rmse_px_median"]:.3f} px)',
         f'③ 检出率 {dr:.1%} < 90%')
    gate(pos_rmse_mm <= 3.0 and abs(s_board - 1.0) <= 0.002,
         f'④ 板系相机中心 vs 真值:RMSE {pos_rmse_mm:.2f} mm(最坏 {pos_max_mm:.2f}),'
         f' 两者 Umeyama 尺度 {s_board:.6f}(残差 {s_res * 1000:.2f} mm)',
         f'④ 板系位置 RMSE {pos_rmse_mm:.2f} mm 或尺度 {s_board:.6f} 超限')
    for tr in rep['trajectories']:
        nm = tr['name']
        k_exp = cases[nm][0]
        k_got = 1.0 / tr['scale_to_metric']
        err_pct = (k_got / k_exp - 1.0) * 100.0
        gate(abs(err_pct) <= a.tol_pct,
             f'⑤ {nm:13s} 期望 k={k_exp:.6f} 恢复 k={k_got:.6f} 偏差 {err_pct:+.4f}%'
             f'  (s={tr["scale_to_metric"]:.6f}, Sim3 残差'
             f' {tr["sim3_rmse_m"] * 1000:.2f} mm, n={tr["n_paired"]})',
             f'⑤ {nm:13s} 期望 k={k_exp:.6f} 恢复 k={k_got:.6f} 偏差 {err_pct:+.4f}%'
             f' > ±{a.tol_pct}%')
    print(f'  ·  ⑥ 诊断(不设闸)ChArUco 角点亚像素残差 bias '
          f'{bias_txt} px / RMSE {det_rmse:.3f} px —— '
          f'检测器侧,非渲染(①已把渲染钉到 {geom_err:.1e} px)')

    print('\n' + ('✅ 合成验证通过' if ok else '🔴 合成验证失败'))
    if a.keep or a.work:
        print(f'   工作目录保留:{work}')
    else:
        shutil.rmtree(work, ignore_errors=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
