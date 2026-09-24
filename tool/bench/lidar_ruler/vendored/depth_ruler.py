#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""🔴 **研发期米制尺子(bench-only ruler)** —— 用 LiDAR 深度给一条轨迹定绝对尺度。

══ 口径先说死(用户 2026-09-22 拍板)═══════════════════════════════════════
**LiDAR 只作研发期量尺。永远不进产品管线、不进提案。**
产品是纯单目 + IMU,这一条不变。这里录的深度、这个脚本算出来的 s,
都只用来**校准我们手里的仪器**,不是产品的输入、不是产品的兜底、
也不是对机型的要求。任何把它写进产品方案的读法都是误读。

══ 这个工具回答的问题 ═══════════════════════════════════════════════════════
`charuco_scale_arbiter.py` 要一块**印出来的板**才能给米;没板的老录制、
随手一拍的场景,它一个数都给不出。本工具换一把尺子:
**同一台手机的 LiDAR 深度**。流程是

  轨迹(尺度未知) ──┐
                     ├─→ 用轨迹给的相对位姿三角化特征点 ⇒ **轨迹尺度下的深度**
  两帧图像特征匹配 ──┘
                                   ÷
  同像素的 LiDAR 深度(只取 high 置信度) ⇒ **米**
                                   ‖
                          s:轨迹 × s = 米

🔴 这**不是真值**,和板一样带三项误差:① LiDAR 自身精度(公开独立测试对
   iPhone LiDAR 给到 ±4.6% 量级);② 深度图 256×192 对 1920×1440 是 7.5×
   下采样,一个深度像素覆盖 7.5×7.5 个图像像素,物体边缘上的匹配点会取到
   前景/背景混合的深度;③ 三角化本身在小视差下病态。
   所以本工具报的是 s 的**中位数 + IQR + 逐对明细**,不报「谁错了多少」。
   它的用处是**排序和量级**,不是标称精度。

══ 抄自哪里(禁止自研)═══════════════════════════════════════════════════════
① 特征检测 + 匹配:OpenCV 自带的 SIFT / ORB + `BFMatcher.knnMatch` + **比值检验**。
   比值检验出处:D. Lowe, "Distinctive Image Features from Scale-Invariant
   Keypoints", IJCV 60(2):91-110, 2004, §7.1(0.8 的那个阈值就是论文里的)。
   https://doi.org/10.1023/B:VISI.0000029664.99615.94
   OpenCV 官方教程(本文件的 knnMatch + ratio test 就是它那几行):
   https://docs.opencv.org/4.x/dc/dc3/tutorial_py_matcher.html
   SIFT 自 OpenCV 4.4 起在主仓 features2d,不需要 contrib:
   https://github.com/opencv/opencv/blob/4.13.0/modules/features2d/include/opencv2/features2d.hpp

② 三角化:`cv2.triangulatePoints` —— OpenCV 的 DLT,教科书是
   Hartley & Zisserman, *Multiple View Geometry*, 2nd ed., §12.2。
   https://docs.opencv.org/4.x/d9/d0c/group__calib3d.html#gad3fc9a0c82b08df034234979960b778c
   **位姿不估**:两帧的相对位姿直接来自被测轨迹,这正是我们要标定的那条尺子
   ——从匹配点估位姿会把尺度自由度重新引进来,那就白做了。

③ 尺度对齐:**单目深度评测的标准做法**,逐字照搬 monodepth2 的评测脚本:
     https://github.com/nianticlabs/monodepth2/blob/master/evaluate_depth.py
     L207  `ratio = np.median(gt_depth) / np.median(pred_depth)`
     L218  `med = np.median(ratios)`
   即**每对帧**算一个「中位数之比」,再对所有帧对取中位数。本文件的
   `ratio_of_medians`(主估计量)与 `median_across_pairs` 就是这两行。
   同一做法更早见于 Zhou et al., "Unsupervised Learning of Depth and Ego-Motion
   from Video", CVPR 2017 (SfMLearner) https://arxiv.org/abs/1704.07813 ;
   「单目深度只能定到一个未知尺度、因此评测前要对齐」这件事的源头是
   Eigen, Puhrsch & Fergus, NIPS 2014, §3.2 的 scale-invariant error
   https://arxiv.org/abs/1406.2283 。
   🔑 任务书里写的公式是 `s = median(lidar/triangulated)`(**逐点比值的中位数**),
      与 monodepth2 的「中位数之比」不是同一个统计量。两个都算、都报:
      `scale_to_metric` = 中位数之比(= 上游逐字),
      `scale_median_of_ratios` = 逐点比值中位数(= 任务书字面)。
      两者在合成数据上差 <0.05%;真机上若它们分家,说明深度分布被离群点拖了,
      本身就是一条诊断。

④ 录制读取:复用同目录 `charuco_scale_arbiter.py` 的 `load_recording()` /
   `load_intrinsics()`(它们又是复用 `pwvi_to_euroc.py` 的)。
   🔴 内参**按时间戳最近邻**配对,不能按下标 —— ARKit 臂每个 ARFrame 都写内参
   而帧流有背压丢帧。同理深度帧也按 `t_ns` 与相机帧配对,不按帧号。

══ 深度图 ↔ 图像的像素映射 ═══════════════════════════════════════════════
Apple 原话(https://developer.apple.com/documentation/arkit/ardepthdata,
Overview):

  "Every pixel in the depthMap maps to a region of the visible scene
   (capturedImage), where the pixel value defines that region's distance from
   the plane of the camera in meters."

两条推论,都用上了:
  ① 深度值是**相机平面的 z 距离**(distance from the *plane* of the camera),
     不是到光心的径向距离 ⇒ 可以直接和三角化点的 Z 相除,不需要先换算。
  ② 深度图的每个像素覆盖 `capturedImage` 的一个区域、整张图覆盖同一个可见场景
     ⇒ 两张图同 FOV、只是分辨率不同,像素映射就是按分辨率比例缩:
         u_d = (u_c + 0.5) * W_d / W_c − 0.5      (像素**面积**中心对齐)
     🔴 这个公式是我们从上面那句话 + 分辨率比推出来的,**不是** Apple 公布的
        公式原文;我没有找到一句 Apple 文档明写「同 FOV」或明写这个缩放式。
        如实标明,不要把推论当引文。
SDK 头文件的原话(iPhoneOS26.2.sdk `ARKit.framework/Headers/ARDepthData.h`):
  `depthMap` : "A pixel buffer that contains per-pixel depth data (in meters)."
  `ARConfidenceLevel` : Low = 0, Medium = 1, High = 2。

══ 输入 ═════════════════════════════════════════════════════════════════════
录制目录(`run-*`),除 `charuco_scale_arbiter.py` 要的那些以外还要有:
  depth.bin      : float32 米,行优先 w×h
  depth_conf.bin : uint8 ARConfidenceLevel
  depth.pwvi     : JSONL,每行 {"frame","offset","len","t_ns","w","h",
                                "conf_offset","conf_len"}
轨迹:`--traj 名字=路径.tum`,可重复。

`--ref-y-up` 的语义与 `ate.py` 一致:声明这条轨迹的**世界系是 ARKit 的 y-up**
(而不是 XRSLAM 的 z-up)。
🔑 但对本工具它**不改变任何数值**:三角化只用**相对位姿**
`R_rel = R_i^T R_j`、`t_rel = R_i^T (p_j − p_i)`,世界系整体换基在相对量里
约掉。收下这个旗标只是为了把它写进报告的 provenance,让读的人知道这条轨迹
是哪一支。真正会改数值的是**相机本体轴系**,见 `--camera-axes`。

`--camera-axes {opencv,arkit}`:位姿里的相机本体系用哪套轴。
  opencv : x 右 / y 下 / z **前**(`cv2.projectPoints` 的约定,默认)
  arkit  : x 右 / y **上** / z **后**(`ARCamera.transform` 的约定)
  转换是常量 `D = diag(1,−1,−1)`:`R_cv = D R D`、`t_cv = D t`。
  🔴 搞错这个不会报错,只会让三角化全部落到相机背后(z<0)被过滤光 ⇒
     有效点数掉到 0。本工具把「有效点为 0」当成硬失败而不是空结果,
     就是为了让它显形。

══ 输出 ═════════════════════════════════════════════════════════════════════
`--out` 目录下 `depth_ruler_report.json`;stdout 打印人读的小结。
怎么接 `tools/scale_accept/accept_scale.py`:accept_scale 吃的是两条 `.tum`,
判的是「我们的轨迹 vs ARKit 参照」的相对尺度,它不知道米。本工具给的是
**每条轨迹各自对米的 s**,所以两者的接法是:
    把本工具对 EST 与对 REF 各算一次,`s_est / s_ref` 就是 accept_scale 报的
    那个相对尺度的**米制核对**;而 `|1 − s_est|` 才是「对真实尺寸的偏差」,
    也就是 ±5% 容差真正要管的量。报告里两个数都打。
"""

import argparse
import bisect
import json
import os
import sys

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    raise SystemExit('🔴 需要 OpenCV ≥ 4.4:pip3 install --user opencv-python-headless')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from charuco_scale_arbiter import (          # noqa: E402  (复用,禁止自研)
    load_recording,
    load_intrinsics,
    load_tum,
    quat_to_rmat,
)

# ARConfidenceLevel,ARDepthData.h。
CONF_LOW, CONF_MEDIUM, CONF_HIGH = 0, 1, 2

# OpenCV 相机系 ← ARKit 相机系。ARKit 的 ARCamera.transform 是 x 右 / y 上 /
# z 后,OpenCV 是 x 右 / y 下 / z 前 ⇒ 后两轴取反,D 自逆。
D_ARKIT_TO_OPENCV = np.diag([1.0, -1.0, -1.0])


# ═══════════════════════════════════════════════════════════════════════════
# 深度流读取(与 frames.bin / frames.pwvi 同一种布局)
# ═══════════════════════════════════════════════════════════════════════════

def load_depth_index(recdir):
    """读 depth.pwvi。缺文件 = 干净拒绝,不是空结果。"""
    path = os.path.join(recdir, 'depth.pwvi')
    if not os.path.exists(path):
        raise SystemExit(
            f'🔴 {recdir} 没有 depth.pwvi ⇒ 这份录制不含 LiDAR 深度,深度尺子用不了。\n'
            '   (录制器加深度是 2026-09-22 之后的事;更早的 run-* 全都没有。\n'
            '    要么换一份带深度的录制,要么改用 charuco_scale_arbiter.py + 印出来的板。)')
    rows = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            d = json.loads(ln)
            n = d.get('len', d.get('length'))
            if n is None:
                raise SystemExit(f'🔴 {path} 的记录既无 len 也无 length: {d}')
            rows.append({
                'frame': int(d['frame']),
                'offset': int(d['offset']),
                'len': int(n),
                't_ns': int(d['t_ns']),
                'w': int(d['w']),
                'h': int(d['h']),
                'conf_offset': int(d.get('conf_offset', -1)),
                'conf_len': int(d.get('conf_len', 0)),
            })
    if not rows:
        raise SystemExit(f'🔴 {path} 是空的')
    w, h = rows[0]['w'], rows[0]['h']
    bad = [r for r in rows if r['w'] != w or r['h'] != h or r['len'] != w * h * 4]
    if bad:
        raise SystemExit(f'🔴 深度帧几何不一致,首例 {bad[0]}')
    have_conf = all(r['conf_len'] == w * h for r in rows)
    if not have_conf:
        raise SystemExit(
            '🔴 depth.pwvi 里有帧没有置信度(conf_len ≠ w*h)。\n'
            '   ARDepthData.confidenceMap 在 SDK 头里是 nullable ⇒ 真的可能没有。\n'
            '   没有置信度就**没法只留 high**,而 low 置信度的 LiDAR 值是不能当尺子的 ⇒ 拒绝。')
    return rows, w, h


class DepthReader:
    """按 offset/len 定位读一帧,不把整条流读进内存(30 s 能到 422 MiB)。"""

    def __init__(self, recdir, w, h):
        self.w, self.h = w, h
        self.fd = open(os.path.join(recdir, 'depth.bin'), 'rb')
        cpath = os.path.join(recdir, 'depth_conf.bin')
        if not os.path.exists(cpath):
            raise SystemExit('🔴 有 depth.bin 却没有 depth_conf.bin ⇒ 无法过滤置信度,拒绝')
        self.cfd = open(cpath, 'rb')

    def read(self, row):
        self.fd.seek(row['offset'])
        raw = self.fd.read(row['len'])
        if len(raw) != row['len']:
            raise SystemExit(f'🔴 depth.bin 在帧 {row["frame"]} 处短读')
        depth = np.frombuffer(raw, dtype='<f4').reshape(self.h, self.w)
        self.cfd.seek(row['conf_offset'])
        craw = self.cfd.read(row['conf_len'])
        if len(craw) != row['conf_len']:
            raise SystemExit(f'🔴 depth_conf.bin 在帧 {row["frame"]} 处短读')
        conf = np.frombuffer(craw, dtype=np.uint8).reshape(self.h, self.w)
        return depth, conf


# ═══════════════════════════════════════════════════════════════════════════
# 特征 + 三角化
# ═══════════════════════════════════════════════════════════════════════════

def make_detector(name, n_features):
    if name == 'sift':
        return cv2.SIFT_create(nfeatures=n_features), cv2.NORM_L2
    if name == 'orb':
        return cv2.ORB_create(nfeatures=n_features), cv2.NORM_HAMMING
    raise SystemExit(f'🔴 未知的 --detector {name}')


def match_ratio_test(desc_a, desc_b, norm, ratio):
    """OpenCV 官方 py_matcher 教程那几行:knnMatch(k=2) + Lowe 比值检验。

    https://docs.opencv.org/4.x/dc/dc3/tutorial_py_matcher.html
    比值阈值 0.8 出自 Lowe IJCV2004 §7.1(论文原话是这个阈值丢掉 90% 的错匹配、
    只丢 5% 的正确匹配)。
    """
    if desc_a is None or desc_b is None or len(desc_a) < 2 or len(desc_b) < 2:
        return []
    bf = cv2.BFMatcher(norm)
    knn = bf.knnMatch(desc_a, desc_b, k=2)
    good = []
    for pair in knn:
        if len(pair) < 2:
            continue
        m, n = pair
        if m.distance < ratio * n.distance:
            good.append(m)
    return good


def relative_pose(p_a, q_a, p_b, q_b, camera_axes):
    """X_b = R t X_a。位姿是 world_from_camera(TUM 的常规)。

    R_rel = R_b^T R_a ,  t_rel = R_b^T (p_a − p_b) —— 世界系整体换基在这里约掉,
    所以 --ref-y-up 对数值没有影响。
    """
    R_a = quat_to_rmat(*q_a)
    R_b = quat_to_rmat(*q_b)
    R_rel = R_b.T @ R_a
    t_rel = R_b.T @ (np.asarray(p_a) - np.asarray(p_b))
    if camera_axes == 'arkit':
        D = D_ARKIT_TO_OPENCV
        R_rel = D @ R_rel @ D
        t_rel = D @ t_rel
    return R_rel, t_rel


def triangulate_pair(K_a, K_b, R_rel, t_rel, pts_a, pts_b):
    """cv2.triangulatePoints(DLT)。返回相机 a 系下的 3D 点(轨迹尺度)。"""
    P_a = K_a @ np.hstack([np.eye(3), np.zeros((3, 1))])
    P_b = K_b @ np.hstack([R_rel, t_rel.reshape(3, 1)])
    X_h = cv2.triangulatePoints(P_a, P_b, pts_a.T, pts_b.T)
    w = X_h[3]
    ok = np.abs(w) > 1e-12
    X = np.full((len(pts_a), 3), np.nan)
    X[ok] = (X_h[:3, ok] / w[ok]).T
    return X, P_a, P_b


def reproject(P, X):
    Xh = np.hstack([X, np.ones((len(X), 1))])
    uvw = (P @ Xh.T).T
    z = uvw[:, 2]
    out = np.full((len(X), 2), np.nan)
    ok = np.abs(z) > 1e-12
    out[ok] = uvw[ok, :2] / z[ok, None]
    return out


def sample_depth(depth, conf, uv, img_wh, min_conf):
    """图像像素 → 深度像素(按分辨率比例,像素面积中心对齐)。

    见文件头:这是 Apple 那句「每个深度像素映射到 capturedImage 的一个区域」
    加分辨率比推出来的,不是 Apple 公布的公式。
    """
    W_c, H_c = img_wh
    H_d, W_d = depth.shape
    u = (uv[:, 0] + 0.5) * W_d / W_c - 0.5
    v = (uv[:, 1] + 0.5) * H_d / H_c - 0.5
    iu = np.rint(u).astype(int)
    iv = np.rint(v).astype(int)
    inside = (iu >= 0) & (iu < W_d) & (iv >= 0) & (iv < H_d)
    d = np.full(len(uv), np.nan)
    c = np.zeros(len(uv), dtype=np.uint8)
    d[inside] = depth[iv[inside], iu[inside]]
    c[inside] = conf[iv[inside], iu[inside]]
    good = inside & np.isfinite(d) & (d > 0) & (c >= min_conf)
    return d, c, good


# ═══════════════════════════════════════════════════════════════════════════

def run(recdir, traj_path, name, args):
    W, H, ts, off_by_frame, bytes_per_frame = load_recording(recdir)
    intr = load_intrinsics(recdir, ts)
    depth_rows, DW, DH = load_depth_index(recdir)
    reader = DepthReader(recdir, DW, DH)
    print(f'深度流:{len(depth_rows)} 帧 {DW}×{DH};图像 {W}×{H} '
          f'(缩放比 {W / DW:.3f}×{H / DH:.3f})')

    T_traj, P_traj, Q_traj = load_tum(traj_path)
    if len(T_traj) == 0:
        raise SystemExit(f'🔴 {traj_path} 是空轨迹')
    order = np.argsort(T_traj)
    T_traj, P_traj, Q_traj = T_traj[order], P_traj[order], Q_traj[order]

    # 相机帧 → 深度帧(按 t_ns)、相机帧 → 轨迹(按秒),都用最近邻 + 容差。
    dkeys = [r['t_ns'] for r in depth_rows]
    dorder = np.argsort(dkeys)
    dkeys_sorted = [dkeys[i] for i in dorder]

    def nearest(keys, key, tol):
        i = bisect.bisect_left(keys, key)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(keys) and abs(keys[j] - key) <= tol:
                if best is None or abs(keys[j] - key) < abs(keys[best] - key):
                    best = j
        return best

    tol_ns = int(args.pair_tol_ms * 1e6)
    usable = []
    for k, (t_ns, fid) in enumerate(ts):
        if intr[k] is None:
            continue
        di = nearest(dkeys_sorted, t_ns, tol_ns)
        if di is None:
            continue
        tj = nearest(list(T_traj), t_ns / 1e9, args.pair_tol_ms / 1e3)
        if tj is None:
            continue
        usable.append({'k': k, 't_ns': t_ns, 'frame': fid,
                       'depth_row': depth_rows[dorder[di]], 'traj': tj,
                       'K': intr[k]})
    print(f'可用帧(有内参 + 有深度 + 有位姿):{len(usable)}/{len(ts)}')
    if len(usable) < 2:
        raise SystemExit('🔴 可用帧 < 2,无法取帧对')

    # 帧对:沿轨迹每隔 --pair-dt 取一对,均匀铺满全程,取够 --pairs 对。
    dt_ns = int(args.pair_dt * 1e9)
    candidates = []
    idx_ts = [u['t_ns'] for u in usable]
    for a in range(len(usable)):
        b = nearest(idx_ts, usable[a]['t_ns'] + dt_ns, int(0.25 * dt_ns))
        if b is not None and b > a:
            candidates.append((a, b))
    if not candidates:
        raise SystemExit(f'🔴 找不到间隔 ~{args.pair_dt}s 的帧对')
    step = max(1, len(candidates) // args.pairs)
    pairs = candidates[::step][:args.pairs]

    frames_fd = open(os.path.join(recdir, 'frames.bin'), 'rb')

    def image(u):
        frames_fd.seek(off_by_frame[u['frame']])
        raw = frames_fd.read(bytes_per_frame)
        return np.frombuffer(raw, dtype=np.uint8).reshape(H, W)

    detector, norm = make_detector(args.detector, args.features)

    per_pair = []
    all_ratios = []
    conf_hist_total = np.zeros(3, dtype=np.int64)
    for (ia, ib) in pairs:
        ua, ub = usable[ia], usable[ib]
        img_a, img_b = image(ua), image(ub)
        kp_a, de_a = detector.detectAndCompute(img_a, None)
        kp_b, de_b = detector.detectAndCompute(img_b, None)
        good = match_ratio_test(de_a, de_b, norm, args.ratio)
        rec = {'frame_a': ua['frame'], 'frame_b': ub['frame'],
               't_a': ua['t_ns'] / 1e9, 't_b': ub['t_ns'] / 1e9,
               'dt_s': (ub['t_ns'] - ua['t_ns']) / 1e9,
               'keypoints_a': len(kp_a), 'keypoints_b': len(kp_b),
               'matches': len(good)}
        if len(good) < args.min_points:
            rec['skipped'] = f'匹配只有 {len(good)} 个 < --min-points {args.min_points}'
            per_pair.append(rec)
            continue

        pts_a = np.float64([kp_a[m.queryIdx].pt for m in good])
        pts_b = np.float64([kp_b[m.trainIdx].pt for m in good])
        fa = ua['K']
        fb = ub['K']
        K_a = np.array([[fa[0], 0, fa[2]], [0, fa[1], fa[3]], [0, 0, 1.0]])
        K_b = np.array([[fb[0], 0, fb[2]], [0, fb[1], fb[3]], [0, 0, 1.0]])
        R_rel, t_rel = relative_pose(
            P_traj[ua['traj']], Q_traj[ua['traj']],
            P_traj[ub['traj']], Q_traj[ub['traj']], args.camera_axes)
        baseline = float(np.linalg.norm(t_rel))
        rec['baseline_traj_units'] = baseline
        if baseline < args.min_baseline:
            rec['skipped'] = (f'基线 {baseline:.4f} 轨迹单位 < --min-baseline '
                              f'{args.min_baseline} ⇒ 视差不足,三角化病态')
            per_pair.append(rec)
            continue

        X, P_a, P_b = triangulate_pair(K_a, K_b, R_rel, t_rel, pts_a, pts_b)
        z_a = X[:, 2]
        X_b = (R_rel @ X.T).T + t_rel
        # 双视重投影残差(用**已知**位姿,不估位姿)
        e_a = np.linalg.norm(reproject(P_a, X) - pts_a, axis=1)
        e_b = np.linalg.norm(reproject(P_b, X) - pts_b, axis=1)
        # 三角化夹角:两条视线在 3D 点处的夹角,小角度下深度极不稳
        C_b_in_a = -R_rel.T @ t_rel
        v1 = X
        v2 = X - C_b_in_a
        with np.errstate(invalid='ignore', divide='ignore'):
            cosang = np.sum(v1 * v2, 1) / (np.linalg.norm(v1, axis=1)
                                           * np.linalg.norm(v2, axis=1))
        ang_deg = np.degrees(np.arccos(np.clip(cosang, -1, 1)))

        depth_map, conf_map = reader.read(ua['depth_row'])
        d_lidar, conf, depth_ok = sample_depth(
            depth_map, conf_map, pts_a, (W, H), args.min_confidence)
        for level in (0, 1, 2):
            conf_hist_total[level] += int((conf[np.isfinite(d_lidar)] == level).sum())

        keep = (np.isfinite(z_a) & (z_a > 0) & (X_b[:, 2] > 0)
                & (e_a < args.max_reproj_px) & (e_b < args.max_reproj_px)
                & (ang_deg > args.min_angle_deg) & depth_ok)
        rec['cheirality_ok'] = int(((z_a > 0) & (X_b[:, 2] > 0)).sum())
        rec['reproj_ok'] = int(((e_a < args.max_reproj_px)
                                & (e_b < args.max_reproj_px)).sum())
        rec['angle_ok'] = int((ang_deg > args.min_angle_deg).sum())
        rec['depth_high_conf_ok'] = int(depth_ok.sum())
        rec['valid_points'] = int(keep.sum())
        if keep.sum() < args.min_points:
            rec['skipped'] = (f'过完闸只剩 {int(keep.sum())} 点 < --min-points '
                              f'{args.min_points}')
            per_pair.append(rec)
            continue

        tri = z_a[keep]
        lid = d_lidar[keep]
        # ── monodepth2 evaluate_depth.py:207 逐字 ──────────────────────────
        ratio_of_medians = float(np.median(lid) / np.median(tri))
        # ── 任务书字面:逐点比值的中位数 ───────────────────────────────────
        point_ratios = lid / tri
        median_of_ratios = float(np.median(point_ratios))
        rec.update({
            'scale_to_metric': ratio_of_medians,
            'scale_median_of_ratios': median_of_ratios,
            'median_triangulated_traj_units': float(np.median(tri)),
            'median_lidar_m': float(np.median(lid)),
            'point_ratio_iqr': float(np.percentile(point_ratios, 75)
                                     - np.percentile(point_ratios, 25)),
            'reproj_rmse_px_a': float(np.sqrt((e_a[keep] ** 2).mean())),
            'triangulation_angle_deg_median': float(np.median(ang_deg[keep])),
        })
        all_ratios.append(ratio_of_medians)
        per_pair.append(rec)

    frames_fd.close()
    if not all_ratios:
        raise SystemExit(
            '🔴 没有一对帧给出有效尺度。逐对明细里的 skipped 说明了原因;'
            '若 depth_high_conf_ok 恒为 0,先查 --min-confidence(LiDAR 全是 low'
            '置信度的场景,例如远景/强光/无纹理,本工具拒绝给数而不是给个坏数);'
            '若 cheirality_ok 恒为 0,几乎一定是 --camera-axes 选错了。')

    r = np.array(all_ratios)
    # ── monodepth2 evaluate_depth.py:218 逐字 ─────────────────────────────
    med = float(np.median(r))
    q1, q3 = float(np.percentile(r, 25)), float(np.percentile(r, 75))
    return {
        'name': name,
        'trajectory': os.path.abspath(traj_path),
        'recording': os.path.abspath(recdir),
        'ruler': 'lidar_depth_bench_only',
        'bench_only_notice': ('🔴 研发期量尺:LiDAR 深度只用于标定本台架,'
                              '永不进入产品管线、不作为产品方案的一部分'),
        'camera_axes': args.camera_axes,
        'ref_y_up_declared': bool(args.ref_y_up),
        'ref_y_up_effect': ('声明用,数值无影响 —— 三角化只用相对位姿,'
                            '世界系整体换基在 R_b^T R_a / R_b^T(p_a−p_b) 里约掉'),
        'detector': args.detector,
        'depth_resolution': [DW, DH],
        'image_resolution': [W, H],
        'min_confidence': args.min_confidence,
        'pairs_attempted': len(pairs),
        'pairs_with_scale': len(all_ratios),
        'scale_to_metric': med,                       # 轨迹 × s = 米
        'traj_over_report_factor': 1.0 / med,         # = charuco 工具的 k
        'traj_over_report_pct': (1.0 / med - 1.0) * 100.0,
        'scale_iqr': q3 - q1,
        'scale_q1': q1,
        'scale_q3': q3,
        'scale_min': float(r.min()),
        'scale_max': float(r.max()),
        'scale_median_of_ratios_across_pairs': float(np.median(
            [p['scale_median_of_ratios'] for p in per_pair
             if 'scale_median_of_ratios' in p])),
        'lidar_confidence_histogram_low_med_high': conf_hist_total.tolist(),
        'pairs': per_pair,
    }


def main():
    ap = argparse.ArgumentParser(
        description='🔴 研发期米制尺子:用 LiDAR 深度给轨迹定绝对尺度(bench-only)',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--recording', required=True, help='run-* 录制目录(要含 depth.*)')
    ap.add_argument('--traj', action='append', default=[], required=True,
                    help='名字=路径.tum,可重复')
    ap.add_argument('--out', help='输出目录(写 depth_ruler_report.json)')
    ap.add_argument('--ref-y-up', action='store_true',
                    help='语义同 ate.py:声明世界系是 ARKit 的 y-up。'
                         '对本工具数值无影响(只用相对位姿),写进报告备查')
    ap.add_argument('--camera-axes', choices=['opencv', 'arkit'], default='opencv',
                    help='位姿里的相机本体轴系。arkit = x右/y上/z后,会施加 diag(1,-1,-1)')
    ap.add_argument('--detector', choices=['sift', 'orb'], default='sift')
    ap.add_argument('--features', type=int, default=4000)
    ap.add_argument('--ratio', type=float, default=0.8,
                    help='Lowe 比值检验阈值(IJCV2004 §7.1 原文就是 0.8)')
    ap.add_argument('--pairs', type=int, default=20, help='取多少对帧')
    ap.add_argument('--pair-dt', type=float, default=0.5, help='帧对间隔,秒')
    ap.add_argument('--pair-tol-ms', type=float, default=20.0,
                    help='相机帧 ↔ 深度帧 / ↔ 轨迹的时间戳配对容差')
    ap.add_argument('--min-points', type=int, default=20)
    ap.add_argument('--min-baseline', type=float, default=0.02,
                    help='帧对最小基线(轨迹单位)')
    ap.add_argument('--max-reproj-px', type=float, default=2.0)
    ap.add_argument('--min-angle-deg', type=float, default=1.0)
    ap.add_argument('--min-confidence', type=int, default=CONF_HIGH,
                    choices=[CONF_LOW, CONF_MEDIUM, CONF_HIGH],
                    help='只留 ≥ 这个 ARConfidenceLevel 的深度(默认 2 = high)')
    a = ap.parse_args()

    print('🔴 bench-only ruler:LiDAR 深度只用于研发期标定本台架,'
          '永不进入产品管线,也不作为任何产品方案的一部分。\n')

    reports = []
    for spec in a.traj:
        if '=' not in spec:
            raise SystemExit(f'🔴 --traj 要写成 名字=路径:{spec}')
        name, path = spec.split('=', 1)
        print(f'── {name} ──────────────────────────────────────────────')
        rep = run(a.recording, path, name, a)
        reports.append(rep)
        print(f'  s(轨迹×s=米)   = {rep["scale_to_metric"]:.6f}'
              f'   [IQR {rep["scale_iqr"]:.6f}, '
              f'{rep["scale_min"]:.6f}–{rep["scale_max"]:.6f}]')
        print(f'  k = 1/s(过报因子) = {rep["traj_over_report_factor"]:.6f}'
              f'   ⇒ 轨迹比米制大 {rep["traj_over_report_pct"]:+.3f}%')
        print(f'  有效帧对 {rep["pairs_with_scale"]}/{rep["pairs_attempted"]};'
              f' LiDAR 置信度 low/med/high = '
              f'{rep["lidar_confidence_histogram_low_med_high"]}')

    if len(reports) == 2:
        s0, s1 = reports[0]['scale_to_metric'], reports[1]['scale_to_metric']
        print(f'\n两条轨迹的相对尺度 s_{reports[0]["name"]}/s_{reports[1]["name"]}'
              f' = {s0 / s1:.6f}(这才是 accept_scale.py 报的那个相对量的米制核对)')

    out = {'schema_version': 1,
           'ruler': 'lidar_depth_bench_only',
           'bench_only_notice': reports[0]['bench_only_notice'],
           'opencv_version': cv2.__version__,
           'trajectories': reports}
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        p = os.path.join(a.out, 'depth_ruler_report.json')
        json.dump(out, open(p, 'w'), indent=1, ensure_ascii=False)
        print(f'\n写出 {p}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
