#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""合成验证 lidar_ruler.py —— 不拍摄、不开摄像头、不碰 iPhone。

🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,永不进入产品管线,也不作为任何产品方案的一部分。

场景生成器**原样 import**(零自研):vendored/synth_verify.py 的 ChArUco 板渲染与相机轨迹、
vendored/synth_depth_verify.py 的解析深度(射线-平面求交)。本文件只做三件事:
  ① 把它们落成与台架录制器**同格式**的录制:ARKit 轴的 arkit_poses.tum(前 3 行平移为 0 = 没在跟踪,
     再 2 行 arkit_tracking=limited_relocalizing)、深度每 3 帧一张(30 fps ⇒ 10 Hz,同本台架默认的 10 Hz)、
     depth.pwvi 带录制器 W5 的额外键、完整的 recording_manifest.json(Swift 子集导出器能解);
  ② 造一条 XRSLAM 式 BODY 轨迹:另一个世界系 + 尺度 k_true = 0.88(= 那场 −12%)+ 外参杠杆臂
     (米制、不随尺度缩)+ 轨迹误差(随机游走 2 mm/√s + 白噪 1 mm)+ 时间戳 = 帧时间 + td 8 ms + exposure/2,
     另附手机回放那种逐帧账;
  ③ 跑 lidar_ruler.py,逐条判。

判据(硬闸,任何一条不过 ⇒ exit 1):
  T1 ARKit 轴真值轨迹(k=1)⇒ |k−1| ≤ 1%,verdict valid —— 补 09-22 报告「arkit 轴从未端到端验过」那一格
  T2 XRSLAM BODY(td+exposure/2 映射)⇒ |k/0.88 − 1| ≤ 1%,verdict valid
  T3 同一条 XRSLAM 走逐帧账映射 ⇒ 与 T2 的 k 差 ≤ 0.1%
  T4 每条轨迹内建阳性对照 ×1.05 恢复(±0.5%);T4b XRSLAM 的噪声底 NC 带非退化、PC 恢复、95% 区间盖住真值
  T5 每条轨迹内建阴性对照(深度帧洗牌)被闸拒绝
  T6 交叉核对:尺子比值 k_xr/k_arkit 与规范 Sim3(scale_eval.sim3)差 ≤ 0.5%
  T7 跟踪过滤:平移为 0 的 3 行 + limited 的 2 行都被丢
  T8 LiDAR 噪声(逐像素 1% 高斯 + 5% 野值)⇒ 两条轨迹仍 ±1.5%、valid
  T9 LiDAR 整体偏 ×1.02 ⇒ ARKit 的 k 恰为 1/1.02(±0.5%)—— 这是**局限的自证**:LiDAR 的系统偏差原样进 k
  T10 没有深度的老录制(run-6e2d4b99)⇒ 干净拒绝
  T11(可选,有 --subset-exporter 时)Swift 子集导出器导出 ruler_subset/ ⇒ 在子集上跑出的 k 与整份差 ≤ 0.5%

跑法:/usr/bin/python3 test_lidar_ruler_synth.py [--work DIR --keep] [--subset-exporter <swift 可执行>]
"""

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'vendored'))
import synth_verify as SV            # noqa: E402  场景生成器,零自研
import synth_depth_verify as SDV     # noqa: E402  解析深度,零自研

RULER = os.path.join(HERE, 'lidar_ruler.py')
DEPTH_STRIDE = 3
TD = 0.008
K_XR = 0.88
R_BC = np.array([[0.0, -1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0]])   # q_bc [-0.7071068,0.7071068,0,0]
P_BC = np.array([0.03290364, -0.00696553, -0.00286231])
D = np.diag([1.0, -1.0, -1.0])


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def rot(axis, ang):
    a = np.asarray(axis, float)
    a /= np.linalg.norm(a)
    R, _ = cv2.Rodrigues((a * ang).reshape(3, 1))
    return R


def tum_line(t_ns, p, q, fmt_p='%.9f'):
    return (f'{t_ns // 1_000_000_000}.{t_ns % 1_000_000_000:09d} '
            + ' '.join(fmt_p % v for v in p) + ' ' + ' '.join('%.9f' % v for v in q))


def write_depth(rec, frames, depths, bias=1.0, noise=0.0, outliers=0.0, seed=1):
    rng = np.random.default_rng(seed)
    dw, dh = SDV.DEPTH_W, SDV.DEPTH_H
    with open(os.path.join(rec, 'depth.bin'), 'wb') as fd, \
         open(os.path.join(rec, 'depth_conf.bin'), 'wb') as fc, \
         open(os.path.join(rec, 'depth.pwvi'), 'w') as fp:
        n = 0
        for (k, t_ns, K), (depth, conf) in zip(frames, depths):
            d = depth.astype(np.float64) * bias
            if noise > 0:
                d = d * (1.0 + rng.normal(0, noise, d.shape))
            if outliers > 0:
                m = rng.random(d.shape) < outliers
                d[m] = d[m] * rng.uniform(0.5, 1.5, m.sum())
            d = np.where(conf == SDV.CONF_HIGH, d, 0.0).astype('<f4')
            rx, ry = dw / SV.IMG_W, dh / SV.IMG_H
            row = {'frame': n, 'offset': n * dw * dh * 4, 'len': dw * dh * 4, 't_ns': t_ns,
                   'w': dw, 'h': dh, 'conf_offset': n * dw * dh, 'conf_len': dw * dh,
                   'camera_frame': k, 'ar_frame': k, 'image_w': SV.IMG_W, 'image_h': SV.IMG_H,
                   'k_image': list(K),
                   'k_depth': [K[0] * rx, K[1] * ry, (K[2] + 0.5) * rx - 0.5, (K[3] + 0.5) * ry - 0.5]}
            fd.write(d.tobytes())
            fc.write(conf.astype(np.uint8).tobytes())
            fp.write(json.dumps(row) + '\n')
            n += 1
    return n


def write_manifest(rec, n_frames, n_imu, depth_frames):
    files = []
    for role, path in [('arkit_poses', 'arkit_poses.tum'), ('camera_index', 'camera_index.csv'),
                       ('frames_stream', 'frames.bin'), ('frames_index', 'frames.pwvi'),
                       ('imu_index', 'imu.csv'), ('intrinsics_index', 'intrinsics.jsonl'),
                       ('depth_stream', 'depth.bin'), ('depth_confidence_stream', 'depth_conf.bin'),
                       ('depth_index', 'depth.pwvi')]:
        p = os.path.join(rec, path)
        files.append({'role': role, 'relative_path': path, 'byte_count': os.path.getsize(p),
                      'sha256': sha(p)})
    files.sort(key=lambda f: f['relative_path'])
    m = {'schema_version': 1, 'recording_id': 'synthetic-lidar-ruler',
         'camera': {'width': SV.IMG_W, 'height': SV.IMG_H, 'nominal_fps': SV.FPS,
                    'pixel_format': 'luma8_from_420f_full_range'},
         'intrinsics': {'fx': SV.FX, 'fy': SV.FY, 'cx': SV.CX, 'cy': SV.CY,
                        'source': 'synthetic', 'cross_check_passed': True},
         'frame_count': n_frames, 'imu_sample_count': n_imu,
         'frames_digest_sha256': sha(os.path.join(rec, 'frames.bin')),
         'frames_total_byte_count': os.path.getsize(os.path.join(rec, 'frames.bin')),
         'loss_count': 0, 'loss_format_mismatch': 0, 'loss_write_queue_full': 0, 'loss_write_error': 0,
         'peak_in_flight': 1, 'slowest_write_ms': 0.0, 'focal_length_min': SV.FX, 'focal_length_max': SV.FX,
         'late_frames_after_seal': 0, 'depth_present': True, 'depth_width': SDV.DEPTH_W,
         'depth_height': SDV.DEPTH_H, 'depth_frame_count': depth_frames,
         'depth_source': 'synthetic_ray_plane_intersection', 'depth_confidence_present': True,
         'depth_dropped': 0, 'files': files}
    json.dump(m, open(os.path.join(rec, 'recording_manifest.json'), 'w'), indent=1)


def build(work, seed):
    rec = os.path.join(work, 'run-synthetic-lidar')
    os.makedirs(rec, exist_ok=True)
    rng = np.random.default_rng(seed)
    dist = np.zeros((5, 1))
    bw, bh = SV.SQX * SV.SQUARE_M, SV.SQY * SV.SQUARE_M
    aruco_dict = cv2.aruco.getPredefinedDictionary(getattr(cv2.aruco, SV.DICT_NAME))
    board = cv2.aruco.CharucoBoard((SV.SQX, SV.SQY), SV.SQUARE_M, SV.MARKER_M, aruco_dict)
    board_img = board.generateImage((int(bw * SV.TEX_PX_PER_M), int(bh * SV.TEX_PX_PER_M)))
    poses = SV.make_trajectory()
    ts = [SV.T0_NS + int(round(i / SV.FPS * 1e9)) for i in range(len(poses))]
    K = (SV.FX, SV.FY, SV.CX, SV.CY)
    nbytes = SV.IMG_W * SV.IMG_H
    expo = [0.004 + 0.006 * (0.5 + 0.5 * np.sin(i / 7.0)) for i in range(len(poses))]
    tracking = ['limited_initializing'] * 3 + ['limited_relocalizing'] * 2 + ['normal'] * (len(poses) - 5)

    # ARKit 世界系(y 上):板系经任意刚体变换
    R_A = rot([0.3, 1.0, -0.2], 0.9)
    t_A = np.array([0.4, 1.3, -0.7])
    # XRSLAM 世界系(z 上,另一套):再一个刚体变换 + 尺度 K_XR
    R_X = rot([-0.5, 0.2, 1.0], -1.7)
    t_X = np.array([-2.0, 0.6, 0.3])

    # XRSLAM 的轨迹误差:随机游走 2 mm/√s + 白噪 1 mm(controls.py synth_body_from_arkit 的形状,量级减小)。
    rng_x = np.random.default_rng(seed + 1)
    rw = np.cumsum(rng_x.normal(0, 1, (len(poses), 3)) * 0.002 * np.sqrt(1.0 / SV.FPS), 0)
    depth_frames, depths = [], []
    with open(os.path.join(rec, 'frames.bin'), 'wb') as fb, \
         open(os.path.join(rec, 'frames.pwvi'), 'w') as fp, \
         open(os.path.join(rec, 'camera_index.csv'), 'w') as fc, \
         open(os.path.join(rec, 'intrinsics.jsonl'), 'w') as fi, \
         open(os.path.join(rec, 'arkit_poses.tum'), 'w') as fa, \
         open(os.path.join(work, 'xr_body.tum'), 'w') as fx, \
         open(os.path.join(work, 'xr_ledger.csv'), 'w') as fl:
        fc.write('timestamp_ns,relative_path\n')
        fl.write('frame,recording_frame,t_ns,t_canonical,t_effective,exposure_used_s\n')
        for k, ((C, R_bc_board), t_ns) in enumerate(zip(poses, ts)):
            img, _rvec, _tvec, _M = SV.render(board_img, (bw, bh), C, R_bc_board, dist,
                                              SV.SUPERSAMPLE, 2.0, rng)
            fb.write(img.tobytes())
            fp.write(json.dumps({'frame': k, 'offset': k * nbytes, 'len': nbytes,
                                 'keyframe': True, 'gop': k}) + '\n')
            fc.write(f'{t_ns},{k}\n')
            fi.write(json.dumps({'t': t_ns / 1e9, 'intrinsics_fxfycxcy': list(K),
                                 'exposure_s': expo[k], 'arkit_tracking': tracking[k]}) + '\n')
            # ARKit:相机位姿,ARKit 相机轴(OpenCV 轴 × D)
            R_wc_cv = R_A @ R_bc_board
            C_w = R_A @ C + t_A
            q = SV.rmat_to_quat(R_wc_cv @ D)
            p = np.zeros(3) if k < 3 else C_w
            fa.write(tum_line(t_ns, p, q) + '\n')
            # XRSLAM:BODY 位姿,尺度 K_XR,杠杆臂米制,时间 = 帧 + td + exposure/2
            R_wc_x = R_X @ R_bc_board
            C_x = K_XR * (R_X @ C + t_X) + rw[k] + rng_x.normal(0, 0.001, 3)
            R_wb = R_wc_x @ R_BC.T
            p_wb = C_x - R_wb @ P_BC
            t_eff = t_ns + int(round((TD + expo[k] / 2) * 1e9))
            fx.write(tum_line(t_eff, p_wb, SV.rmat_to_quat(R_wb), '%.7f') + '\n')
            fl.write(f'{k},{k},{t_ns},{t_ns / 1e9:.9f},{t_eff / 1e9:.9f},{expo[k]}\n')
            if k % DEPTH_STRIDE == 0:
                depth_frames.append((k, t_ns, K))
                depths.append(SDV.analytic_depth(C, R_bc_board, (bw, bh)))
            if k % 20 == 0:
                print(f'  渲染 {k}/{len(poses)}', flush=True)
    with open(os.path.join(rec, 'imu.csv'), 'w') as f:
        f.write('timestamp_ns,wx,wy,wz,ax,ay,az\n')
        for i in range(10):
            f.write(f'{ts[0] - 10_000_000 + i * 10_000_000},0,0,0,0,9.8,0\n')
    nd = write_depth(rec, depth_frames, depths)
    write_manifest(rec, len(poses), 10, nd)
    with open(os.path.join(work, 'xr.yaml'), 'w') as f:
        f.write('cam0:\n  time_offset: 0.008\n  extrinsic:\n'
                '    q_bc: [ -0.7071068, 0.7071068, 0, 0 ]\n'
                f'    p_bc: [ {P_BC[0]}, {P_BC[1]}, {P_BC[2]} ]\n')
    return rec, depth_frames, depths


def variant(work, rec, name, depth_frames, depths, **kw):
    """同一份帧,换一套深度(硬链接其余文件)。"""
    out = os.path.join(work, name)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    for f in os.listdir(rec):
        if f.startswith('depth') or f == 'recording_manifest.json' or f == 'ruler_subset':
            continue
        os.link(os.path.join(rec, f), os.path.join(out, f))
    nd = write_depth(out, depth_frames, depths, **kw)
    write_manifest(out, len(SV.make_trajectory()), 10, nd)
    return out


def ruler(rec, work, tag, extra):
    out = os.path.join(work, 'out_' + tag)
    cmd = [sys.executable, RULER, '--recording', rec, '--out', out] + extra
    r = subprocess.run(cmd, capture_output=True, text=True)
    rep = None
    p = os.path.join(out, 'lidar_ruler_report.json')
    if os.path.exists(p):
        rep = json.load(open(p))
    return r, rep


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--work')
    ap.add_argument('--keep', action='store_true')
    ap.add_argument('--seed', type=int, default=20260924)
    ap.add_argument('--subset-exporter', help='tool/bench/lidar_swift_tests 编出来的 lidar_subset_export')
    a = ap.parse_args()
    print('🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,永不进入产品管线。\n')
    work = a.work or tempfile.mkdtemp(prefix='lidar_ruler_synth_')
    os.makedirs(work, exist_ok=True)
    rec, dframes, depths = build(work, a.seed)
    xr_shift = ['--xrslam', f'xr={os.path.join(work, "xr_body.tum")}', '--xrslam-yaml',
                os.path.join(work, 'xr.yaml'), '--xrslam-td', str(TD), '--xrslam-exposure-half']
    xr_ledger = ['--xrslam', f'xr={os.path.join(work, "xr_body.tum")}', '--xrslam-ledger',
                 f'xr={os.path.join(work, "xr_ledger.csv")}', '--xrslam-yaml', os.path.join(work, 'xr.yaml')]

    ok = True
    results = {}

    def gate(cond, msg):
        nonlocal ok
        print(('  ✅ ' if cond else '  🔴 ') + msg, flush=True)
        ok = ok and bool(cond)

    def k_of(rep, n):
        return rep['trajectories'][n]['estimate']['k']

    print('\n══ A:无噪声 LiDAR,ARKit + XRSLAM(td+exposure/2 映射)══')
    r, rep = ruler(rec, work, 'A', ['--arkit'] + xr_shift)
    print(r.stdout[-3000:])
    if rep is None:
        print(r.stderr)
        return 1
    results['A'] = rep
    ka, kx = k_of(rep, 'arkit'), k_of(rep, 'xr')
    tra, trx = rep['trajectories']['arkit'], rep['trajectories']['xr']
    gate(abs(ka - 1) <= 0.01 and tra['verdict'] == 'valid',
         f'T1 ARKit 轴真值 k={ka:.5f}(期望 1.0000,±1%),verdict {tra["verdict"]}')
    gate(abs(kx / K_XR - 1) <= 0.01 and trx['verdict'] == 'valid',
         f'T2 XRSLAM BODY k={kx:.5f}(期望 {K_XR},±1%),verdict {trx["verdict"]}')
    for n, t in (('arkit', tra), ('xr', trx)):
        pc = t.get('control_pc_x1_05', {})
        gate(pc.get('recovered'), f'T4 {n}:相机中心 ×1.05 ⇒ k 比值 {pc.get("ratio", float("nan")):.5f}(±0.5%)')
    nf = trx.get('noise_floor') or {}
    band = nf.get('k_95_noise_floor') or [float('nan'), float('nan')]
    gate(nf.get('pc_recovered') and band[0] <= K_XR <= band[1] and nf.get('nc_sd', 0) > 0,
         f'T4b XRSLAM 噪声底:NC 带 {nf.get("nc_band_95")}(sd {nf.get("nc_sd", float("nan")) * 100:.3f}%,'
         f'必须 > 0 —— 第一版是 0,见 lidar_ruler 文件头),PC 恢复 {nf.get("pc_mean", float("nan")):.4f},'
         f'95% 区间 [{band[0]:.4f}, {band[1]:.4f}] 盖住真值 {K_XR}')
    for n, t in (('arkit', tra), ('xr', trx)):
        nc = t['control_nc_shuffled_depth']
        gate(nc['rejected_as_required'],
             f'T5 {n}:深度洗牌被拒(帧对间 IQR {nc.get("between_pair_rel_iqr")},'
             f'帧对内 {nc.get("within_pair_rel_iqr_median")},闸 {nc.get("gates")})')
    cc = [c for c in rep['cross_check_vs_canonical_sim3'] if c['est'] == 'xr' and c['ref'] == 'arkit']
    gate(cc and abs(cc[0]['diff_pct']) <= 0.5,
         f'T6 交叉核对 k_xr/k_arkit={cc[0]["k_ratio_from_ruler"]:.5f} vs 规范 Sim3 '
         f'{cc[0]["k_sim3_canonical"]:.5f}(差 {cc[0]["diff_pct"]:+.3f}%)' if cc else 'T6 无交叉核对')
    pa = rep['provenance']['arkit']
    gate(pa['zero_translation_dropped'] == 3 and pa['not_normal_dropped'] == 2,
         f'T7 跟踪过滤:平移为 0 丢 {pa["zero_translation_dropped"]}、非 normal 丢 {pa["not_normal_dropped"]}'
         '(期望 3 / 2)')

    print('\n══ B:同一条 XRSLAM,走逐帧账映射 ══')
    # 带上 --arkit:可用帧 = 所有轨迹都有位姿的帧 ⇒ 与 A 同一组帧对,差别只剩映射方式。
    r, repb = ruler(rec, work, 'B', ['--arkit'] + xr_ledger)
    results['B'] = repb
    kxb = k_of(repb, 'xr') if repb else float('nan')
    gate(repb and abs(kxb / kx - 1) <= 0.001, f'T3 逐帧账映射 k={kxb:.5f} vs td 映射 {kx:.5f}')

    print('\n══ C:LiDAR 逐像素 1% 噪声 + 5% 野值 ══')
    recc = variant(work, rec, 'run-noisy', dframes, depths, noise=0.01, outliers=0.05, seed=5)
    r, repc = ruler(recc, work, 'C', ['--arkit'] + xr_shift)
    results['C'] = repc
    if repc:
        kac, kxc = k_of(repc, 'arkit'), k_of(repc, 'xr')
        gate(abs(kac - 1) <= 0.015 and abs(kxc / K_XR - 1) <= 0.015
             and all(t['verdict'] == 'valid' for t in repc['trajectories'].values()),
             f'T8 噪声下 ARKit k={kac:.5f}、XRSLAM k={kxc:.5f}(±1.5%),verdict '
             f'{[t["verdict"] for t in repc["trajectories"].values()]}')
    else:
        gate(False, 'T8 噪声场景没出报告:' + r.stderr[-500:])

    print('\n══ D:LiDAR 整体偏 ×1.02(局限自证)══')
    recd = variant(work, rec, 'run-bias', dframes, depths, bias=1.02)
    r, repd = ruler(recd, work, 'D', ['--arkit'])
    results['D'] = repd
    kad = k_of(repd, 'arkit') if repd else float('nan')
    gate(abs(kad * 1.02 - 1) <= 0.005,
         f'T9 LiDAR ×1.02 ⇒ ARKit k={kad:.5f}(期望 1/1.02={1 / 1.02:.5f}):LiDAR 的系统偏差原样进 k')

    print('\n══ E:没有深度的老录制 ══')
    old = os.path.expanduser('~/Developer/viobench-recordings/run-6e2d4b99-896b-4372-ae47-ac0b4679cf18')
    if os.path.isdir(old):
        r = subprocess.run([sys.executable, RULER, '--recording', old, '--arkit'],
                           capture_output=True, text=True)
        gate(r.returncode != 0 and 'depth.pwvi' in (r.stdout + r.stderr),
             f'T10 无深度录制被拒(exit {r.returncode})')
    else:
        print('  (跳过 T10:本机没有 run-6e2d4b99)')

    if a.subset_exporter:
        print('\n══ F:Swift 子集导出器 → 在 ruler_subset/ 上跑 ══')
        e = subprocess.run([a.subset_exporter, rec, '0.25'], capture_output=True, text=True)
        print(e.stdout[-1500:], e.stderr[-1500:])
        sub = os.path.join(rec, 'ruler_subset')
        r, repf = ruler(sub, work, 'F', ['--arkit'] + xr_shift + ['--pair-dt', '0.5'])
        results['F'] = repf
        if repf:
            kaf, kxf = k_of(repf, 'arkit'), k_of(repf, 'xr')
            gate(e.returncode == 0 and abs(kaf - 1) <= 0.01 and abs(kxf / K_XR - 1) <= 0.01,
                 f'T11 子集上 ARKit k={kaf:.5f}、XRSLAM k={kxf:.5f};子集帧 '
                 f'{json.load(open(os.path.join(sub, "ruler_subset_manifest.json")))["frames"]}')
        else:
            gate(False, 'T11 子集上没出报告:' + r.stdout[-800:] + r.stderr[-800:])

    summary = {k: {n: {'k': t['estimate']['k'], 'verdict': t['verdict'],
                       'noise_floor_k95': (t.get('noise_floor') or {}).get('k_95_noise_floor'),
                       'nc_between_iqr': t['control_nc_shuffled_depth'].get('between_pair_rel_iqr'),
                       'between_iqr': t['estimate'].get('between_pair_rel_iqr'),
                       'within_iqr': t['estimate'].get('within_pair_rel_iqr_median'),
                       'pairs': [t['estimate']['pairs_with_scale'], t['estimate']['pairs_attempted']],
                       'alignment_curve': t['alignment_curve_between_rel_iqr_by_depth_row_offset']}
                   for n, t in rep_['trajectories'].items()}
               for k, rep_ in results.items() if rep_}
    json.dump(summary, open(os.path.join(work, 'synth_summary.json'), 'w'), indent=1, default=float)
    print('\n' + ('✅ lidar_ruler 合成验证通过' if ok else '🔴 lidar_ruler 合成验证失败'))
    print(f'   摘要 {os.path.join(work, "synth_summary.json")}')
    if not (a.keep or a.work):
        shutil.rmtree(work, ignore_errors=True)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
