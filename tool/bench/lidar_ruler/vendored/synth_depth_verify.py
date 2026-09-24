#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成验证:不拍摄、不开摄像头,证明 `depth_ruler.py` 能把尺度恢复到 ±1%。

🔴 **bench-only ruler**:LiDAR 深度只用于研发期标定本台架,永不进入产品管线,
也不作为任何产品方案的一部分(用户 2026-09-22 口径)。

══ 为什么必须合成验 ═════════════════════════════════════════════════════════
`depth_ruler.py` 的全部价值是那个 s。真机上 s 没有真值(LiDAR 自己带误差),
所以「s 对不对」**只能在合成数据上验**:合成时我们既知道相机每帧在板系里的
米制位置,也知道每像素的真实深度,于是**知道**每条轨迹该落出什么 s。

══ 怎么合成(零自研:场景生成器整个复用 agent 3 的 `synth_verify.py`)══════
图像那一半**一行不改**地 import 过来:`make_trajectory()` / `render()` /
`K_at()` / `write_tum()` 以及 ChArUco 板、相机内参、超采样等常量。
它只出图不出深度,所以这里按**同一套几何**解析补一张 256×192 的深度图:

  板是 z=0 的平面(`synth_verify` 的板物点就是 x-y 平面,z=0)。
  深度像素 (u,v) → 相机系方向 d_c = K_d⁻¹ (u,v,1)(z 分量恒 1)
  → 板系方向 d_b = R_bc d_c,射线 X = C + λ d_b
  → 交平面 X_z = 0  ⇒  λ = −C_z / d_b_z
  → 相机系 z 深度 = λ · (d_c)_z = λ。
  落在板矩形 [0,bw]×[0,bh] 内 ⇒ 置信度写 **2 = ARConfidenceLevelHigh**;
  落在外面(渲染里是平铺的背景灰,没有真几何)⇒ 深度 0、置信度 **0 = Low**,
  正是真机上「LiDAR 在这块区域没有可信读数」的形状。

  深度内参 K_d 按分辨率比例缩,像素**面积**中心对齐:
      fx_d = FX · r ,  cx_d = (CX + 0.5) · r − 0.5 ,  r = W_d / W_c
  这与 `depth_ruler.sample_depth()` 的 u_d = (u_c+0.5)·r − 0.5 **互逆**
  (代数上逐项抵消),闸①会把这一条实测出来而不是假定。

══ 判据(硬闸,不过就 exit 1)═══════════════════════════════════════════════
 ① 深度几何自证:把板上真实物点用 `cv2.projectPoints` 投到图像像素,再去我们
    生成的深度图里取值,与该点在相机系的真实 Z 比。最大差 ≤ 1 mm。
    —— 这是深度图唯一的假设(解析射线-平面求交 + 分辨率缩放),必须是精确的。
 ② 待测轨迹 = 真值轨迹 **× 1.10**,恢复的过报因子 k 必须 ≈ 1.10(±1%)。
 ③ 阴性对照 A:真值轨迹(k = 1.0)也要恢复到 ±1% —— 否则 ② 可能只是碰巧。
 ④ 阴性对照 B:没有深度的旧录制(`run-6e2d4b99-…`)必须**干净拒绝**
    (非零退出 + 说人话的原因),不能给个坏数。
 ⑤ 阴性对照 C:深度全 low 置信度必须拒绝。
 ⑥ 阴性对照 D:`--camera-axes arkit` 喂 OpenCV 约定的位姿,必须拒绝
    (cheirality 全灭)—— 证明轴系搞错时不会静悄悄给个错数。

跑法(要能 import cv2 + numpy 的解释器,本机是 /usr/bin/python3):
  /usr/bin/python3 synth_depth_verify.py
  /usr/bin/python3 synth_depth_verify.py --work /tmp/synthdepth --keep
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import synth_verify as SV                     # noqa: E402  场景生成器,零自研

RULER = os.path.join(HERE, 'depth_ruler.py')

DEPTH_W, DEPTH_H = 256, 192                   # ARFrame.sceneDepth 的实际分辨率
CONF_LOW, CONF_HIGH = 0, 2                    # ARConfidenceLevel(ARDepthData.h)


def depth_intrinsics():
    """图像内参 → 深度内参,按分辨率比例缩,像素面积中心对齐。"""
    rx = DEPTH_W / SV.IMG_W
    ry = DEPTH_H / SV.IMG_H
    return (SV.FX * rx, SV.FY * ry,
            (SV.CX + 0.5) * rx - 0.5, (SV.CY + 0.5) * ry - 0.5)


def depth_at(C, R_bc, uu, vv, board_wh):
    """任意(可为小数)深度像素坐标处的射线-平面求交。返回 (深度 m, 板内掩码)。

    `uu`/`vv` 是**深度图**的像素坐标。整数网格喂进来就是一张深度图;小数坐标
    喂进来就是「没有量化的」真值,闸①用后者把几何与量化分开。
    """
    fx, fy, cx, cy = depth_intrinsics()
    bw, bh = board_wh
    d_c = np.stack([(uu - cx) / fx, (vv - cy) / fy, np.ones_like(uu)], -1)
    d_b = d_c @ R_bc.T                                   # 相机系 → 板系
    with np.errstate(divide='ignore', invalid='ignore'):
        lam = -C[2] / d_b[..., 2]
    X = C + lam[..., None] * d_b                         # 板系交点(广播)
    inside = ((lam > 0) & np.isfinite(lam)
              & (X[..., 0] >= 0) & (X[..., 0] <= bw)
              & (X[..., 1] >= 0) & (X[..., 1] <= bh))
    # 相机系 z 深度 = λ·(d_c)_z,而 (d_c)_z ≡ 1。
    return np.where(inside, lam, 0.0), inside


def analytic_depth(C, R_bc, board_wh):
    """射线-平面求交,得 256×192 的 z 深度(米)+ ARConfidenceLevel。"""
    uu, vv = np.meshgrid(np.arange(DEPTH_W, dtype=np.float64),
                         np.arange(DEPTH_H, dtype=np.float64))
    lam, inside = depth_at(C, R_bc, uu, vv, board_wh)
    return lam.astype('<f4'), np.where(inside, CONF_HIGH, CONF_LOW).astype(np.uint8)


def build_recording(work, args):
    """渲染 + 落盘成与台架 run-* 同格式的录制(含 depth.*)。"""
    rec = os.path.join(work, 'run-synthetic-depth')
    os.makedirs(rec, exist_ok=True)

    dist = np.zeros((5, 1))
    K1 = SV.K_at(1)
    bw, bh = SV.SQX * SV.SQUARE_M, SV.SQY * SV.SQUARE_M
    aruco_dict = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, SV.DICT_NAME))
    board = cv2.aruco.CharucoBoard((SV.SQX, SV.SQY), SV.SQUARE_M, SV.MARKER_M, aruco_dict)
    board_img = board.generateImage((int(bw * SV.TEX_PX_PER_M), int(bh * SV.TEX_PX_PER_M)))
    obj_all = board.getChessboardCorners()

    poses = SV.make_trajectory()
    ts_ns = [SV.T0_NS + int(round(i / SV.FPS * 1e9)) for i in range(len(poses))]
    rng = np.random.default_rng(args.seed)

    nbytes = SV.IMG_W * SV.IMG_H
    dbytes = DEPTH_W * DEPTH_H * 4
    cbytes = DEPTH_W * DEPTH_H
    gate1_exact_m = 0.0        # 闸①a:几何本身(无量化)
    gate1_nn_m = 0.0           # 闸①b:最近邻取值(= 尺子真实走的路)带的量化
    high_frac = []

    with open(os.path.join(rec, 'frames.bin'), 'wb') as fb, \
         open(os.path.join(rec, 'frames.pwvi'), 'w') as fp, \
         open(os.path.join(rec, 'camera_index.csv'), 'w') as fc, \
         open(os.path.join(rec, 'intrinsics.jsonl'), 'w') as fi, \
         open(os.path.join(rec, 'depth.bin'), 'wb') as fd, \
         open(os.path.join(rec, 'depth_conf.bin'), 'wb') as fdc, \
         open(os.path.join(rec, 'depth.pwvi'), 'w') as fdp:
        fc.write('timestamp_ns,relative_path\n')
        for k, ((C, R_bc), t_ns) in enumerate(zip(poses, ts_ns)):
            img, rvec, tvec, _M = SV.render(board_img, (bw, bh), C, R_bc, dist,
                                            args.supersample, args.noise_sigma, rng)
            depth, conf = analytic_depth(C, R_bc, (bw, bh))
            high_frac.append(float((conf == CONF_HIGH).mean()))

            # ── 闸①:把板上的真实物点用 projectPoints 投到**图像**像素,再按
            #    depth_ruler.sample_depth() 的公式换到深度像素,和该点在相机系
            #    的真实 Z 比。两种读法分开,因为它们验的是两件不同的事:
            #      a) 小数坐标(不量化)⇒ 验的是**几何与内参缩放**本身;
            #      b) 最近邻取整   ⇒ 验的是尺子真实走的那条路,误差里必然含
            #         256×192 的量化(一个深度像素横跨 7.5 个图像像素,斜看
            #         平面时这段距离内深度本来就在变),真机上同样存在。
            proj, _ = cv2.projectPoints(obj_all, rvec, tvec, K1, dist)
            uvc = proj.reshape(-1, 2)
            X_cam = (R_bc.T @ (obj_all - C).T).T          # 相机系坐标,真值
            rx, ry = DEPTH_W / SV.IMG_W, DEPTH_H / SV.IMG_H
            ud = (uvc[:, 0] + 0.5) * rx - 0.5
            vd = (uvc[:, 1] + 0.5) * ry - 0.5
            lam_exact, inside_exact = depth_at(C, R_bc, ud, vd, (bw, bh))
            if inside_exact.any():
                gate1_exact_m = max(gate1_exact_m, float(np.abs(
                    lam_exact[inside_exact] - X_cam[inside_exact, 2]).max()))
            iu = np.rint(ud).astype(int)
            iv = np.rint(vd).astype(int)
            ok = ((iu >= 0) & (iu < DEPTH_W) & (iv >= 0) & (iv < DEPTH_H))
            if ok.any():
                got = depth[iv[ok], iu[ok]]
                want = X_cam[ok, 2]
                valid = conf[iv[ok], iu[ok]] == CONF_HIGH
                if valid.any():
                    gate1_nn_m = max(gate1_nn_m,
                                     float(np.abs(got[valid] - want[valid]).max()))

            fb.write(img.tobytes())
            fp.write(json.dumps({'frame': k, 'offset': k * nbytes, 'len': nbytes,
                                 'keyframe': True, 'gop': k}) + '\n')
            fc.write(f'{t_ns},{k}\n')
            fi.write(json.dumps({'t': t_ns / 1e9,
                                 'intrinsics_fxfycxcy': [SV.FX, SV.FY, SV.CX, SV.CY],
                                 'exposure_s': 0.008}) + '\n')
            fd.write(depth.tobytes())
            fdc.write(conf.tobytes())
            fdp.write(json.dumps({'frame': k, 'offset': k * dbytes, 'len': dbytes,
                                  't_ns': t_ns, 'w': DEPTH_W, 'h': DEPTH_H,
                                  'conf_offset': k * cbytes, 'conf_len': cbytes}) + '\n')
            if k % 20 == 0:
                print(f'  渲染 {k}/{len(poses)}', flush=True)

    json.dump({'schema_version': 1, 'recording_id': 'synthetic-charuco-depth',
               'camera': {'width': SV.IMG_W, 'height': SV.IMG_H,
                          'nominal_fps': int(SV.FPS),
                          'pixel_format': 'luma8_from_420f_full_range'},
               'frame_count': len(poses),
               'depth_present': True, 'depth_width': DEPTH_W, 'depth_height': DEPTH_H,
               'depth_frame_count': len(poses),
               'depth_source': 'synthetic_ray_plane_intersection',
               'depth_confidence_present': True, 'depth_dropped': 0},
              open(os.path.join(rec, 'recording_manifest.json'), 'w'), indent=1)

    # ── 轨迹:真值相机中心施一个任意刚体变换,证明世界系整体换基与结果无关 ──
    C_true = np.array([p[0] for p in poses])
    ax = rng.normal(size=3)
    ax /= np.linalg.norm(ax)
    R_rand, _ = cv2.Rodrigues((ax * 1.1).reshape(3, 1))
    P_rigid = (R_rand @ C_true.T).T + np.array([3.7, -1.2, 0.8])
    Q_traj = [SV.rmat_to_quat(R_rand @ p[1]) for p in poses]

    cases = {
        'truth_metric': (1.0, P_rigid.copy()),
        'over_1100': (1.10, P_rigid * 1.10),
    }
    traj_args = []
    for nm, (_k, P) in cases.items():
        p = os.path.join(rec, f'depth_{nm}.tum')
        SV.write_tum(p, ts_ns, P, Q_traj)
        traj_args += ['--traj', f'{nm}={p}']
    return rec, traj_args, cases, gate1_exact_m, gate1_nn_m, float(np.mean(high_frac))


def run_ruler(rec, traj_args, extra=()):
    cmd = [sys.executable, RULER, '--recording', rec] + list(traj_args) + list(extra)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return cmd, r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work', help='工作目录(默认系统临时目录,跑完删)')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--noise-sigma', type=float, default=2.0)
    ap.add_argument('--supersample', type=int, default=SV.SUPERSAMPLE)
    ap.add_argument('--tol-pct', type=float, default=1.0, help='尺度容差,%%')
    ap.add_argument('--seed', type=int, default=20260922)
    ap.add_argument('--no-depth-recording',
                    default=os.path.expanduser(
                        '~/Developer/viobench-recordings/'
                        'run-6e2d4b99-896b-4372-ae47-ac0b4679cf18'),
                    help='阴性对照 B:一份不含深度的旧录制')
    a = ap.parse_args()

    print('🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,'
          '永不进入产品管线,也不作为任何产品方案的一部分。\n')
    print(f'OpenCV {cv2.__version__}  ·  深度 {DEPTH_W}×{DEPTH_H} vs 图像 '
          f'{SV.IMG_W}×{SV.IMG_H}(比 {SV.IMG_W / DEPTH_W:.1f}×)')

    work = a.work or tempfile.mkdtemp(prefix='depth_synth_')
    os.makedirs(work, exist_ok=True)
    rec, traj_args, cases, gate1a, gate1b, high_frac = build_recording(work, a)
    print(f'\n合成录制:{rec}   high 置信度像素占比均值 {high_frac:.1%}')

    out = os.path.join(work, 'ruler')
    cmd, r = run_ruler(rec, traj_args, ['--out', out])
    print('\n$ ' + ' '.join(cmd) + '\n')
    print(r.stdout)
    if r.returncode != 0:
        print(r.stderr, file=sys.stderr)
        return 1
    rep = json.load(open(os.path.join(out, 'depth_ruler_report.json')))

    ok = True

    def gate(cond, good, bad):
        nonlocal ok
        print(('  ✅ ' if cond else '  🔴 ') + (good if cond else bad))
        if not cond:
            ok = False

    print('══ 判据 ══════════════════════════════════════════════════════')
    gate(gate1a <= 1e-6,
         f'①a 深度几何(不量化):解析深度 vs projectPoints 的真实相机系 Z,'
         f'最大差 {gate1a * 1e6:.4f} µm ≤ 1 µm'
         f'  ⇒ 射线-平面求交与「按分辨率比缩内参」是精确的,'
         f'且与 depth_ruler.sample_depth() 的公式互逆',
         f'①a 深度几何最大差 {gate1a * 1e6:.4f} µm > 1 µm —— '
         f'射线-平面求交或内参缩放有 bug')
    gate(gate1b <= 0.005,
         f'①b 最近邻取值(尺子真实走的路)最大差 {gate1b * 1000:.4f} mm ≤ 5 mm'
         f'  —— 这一项**不是 bug**,是 256×192 的量化:一个深度像素横跨 7.5 个'
         f'图像像素,斜看平面时这段距离内深度本来就在变('
         f'{gate1a * 1e6:.4f} µm 的 ①a 已把几何钉死)。真机上同样存在,'
         f'所以尺子的输出是中位数而不是单点值',
         f'①b 最近邻最大差 {gate1b * 1000:.4f} mm > 5 mm —— 超出纯量化能解释的范围')

    for tr in rep['trajectories']:
        nm = tr['name']
        k_exp = cases[nm][0]
        k_got = tr['traj_over_report_factor']
        err = (k_got / k_exp - 1.0) * 100.0
        tag = '②' if nm == 'over_1100' else '③'
        gate(abs(err) <= a.tol_pct,
             f'{tag} {nm:13s} 期望 k={k_exp:.4f} 恢复 k={k_got:.6f} 偏差 {err:+.4f}%'
             f'  (s={tr["scale_to_metric"]:.6f}, IQR {tr["scale_iqr"]:.6f},'
             f' 有效帧对 {tr["pairs_with_scale"]}/{tr["pairs_attempted"]})',
             f'{tag} {nm:13s} 期望 k={k_exp:.4f} 恢复 k={k_got:.6f} 偏差 {err:+.4f}%'
             f' > ±{a.tol_pct}%')
        # 任务书字面公式(逐点比值中位数)与 monodepth2 的中位数之比必须同一量级
        alt = 1.0 / tr['scale_median_of_ratios_across_pairs']
        print(f'     ·  逐点比值中位数口径 k={alt:.6f}'
              f'(与中位数之比差 {(alt / k_got - 1) * 100:+.4f}%)')

    # ── 阴性对照 B:没有深度的旧录制 ─────────────────────────────────────
    nod = a.no_depth_recording
    if os.path.isdir(nod):
        _c, rn = run_ruler(nod, ['--traj', f'x={os.path.join(nod, "arkit_poses.tum")}'])
        msg = (rn.stdout + rn.stderr).strip().splitlines()
        tail = msg[-1] if msg else ''
        gate(rn.returncode != 0 and 'depth.pwvi' in (rn.stdout + rn.stderr),
             f'④ 无深度的旧录制被干净拒绝(exit {rn.returncode}):{tail[:80]}',
             f'④ 无深度的旧录制没有被拒绝(exit {rn.returncode})')
    else:
        gate(False, '', f'④ 找不到阴性对照录制 {nod}')

    # ── 阴性对照 C:深度全 low 置信度 ────────────────────────────────────
    low = os.path.join(work, 'run-all-low-conf')
    if os.path.isdir(low):
        shutil.rmtree(low)
    os.makedirs(low)
    for f in os.listdir(rec):
        src, dst = os.path.join(rec, f), os.path.join(low, f)
        if f == 'depth_conf.bin':
            n = os.path.getsize(src)
            with open(dst, 'wb') as g:
                g.write(b'\x00' * n)
        else:
            os.link(src, dst)
    _c, rl = run_ruler(low, ['--traj',
                             f'truth_metric={os.path.join(low, "depth_truth_metric.tum")}'])
    both = rl.stdout + rl.stderr
    gate(rl.returncode != 0 and 'min-confidence' in both,
         f'⑤ 深度全 low 置信度被拒绝(exit {rl.returncode}),'
         f'且拒绝理由点名 --min-confidence',
         f'⑤ 全 low 置信度没有被拒绝(exit {rl.returncode})')

    # ── 阴性对照 D:相机轴系喂错 ─────────────────────────────────────────
    _c, rw = run_ruler(rec, ['--traj',
                             f'truth_metric={os.path.join(rec, "depth_truth_metric.tum")}',
                             '--camera-axes', 'arkit'])
    gate(rw.returncode != 0,
         f'⑥ --camera-axes 喂错时拒绝而不是给坏数(exit {rw.returncode})',
         f'⑥ --camera-axes 喂错仍给出了一个数(exit {rw.returncode}) —— '
         f'这正是「不会报错只会偷偷偏」的那类 bug')

    print('\n' + ('✅ 深度尺子合成验证通过' if ok else '🔴 深度尺子合成验证失败'))
    if a.keep or a.work:
        print(f'   工作目录保留:{work}')
    else:
        shutil.rmtree(work, ignore_errors=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
