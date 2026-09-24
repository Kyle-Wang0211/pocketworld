#!/usr/bin/env python3
"""离线「尺度仲裁」:用一块**已知物理尺寸的 ChArUco 板**判谁的尺度对。

══ 这个工具回答的问题 ═══════════════════════════════════════════════════════
VIO 自报的绝对尺度在不同录制上对 ARKit 差 0.2%–19%。「差多少」是两条轨迹的
**相对**量,谁也不是真值(09-19 判决:`arkit_poses.tum` 不是真值)。
放一块**印出来量过边长**的 ChArUco 板进场景,就有了第三方**米制**参照:
板给出的相机中心轨迹是绝对的,拿它和每条 tum 做 Sim3 对齐,
落出来的尺度因子 s 就是「这条轨迹要乘多少才是米」。**这才是仲裁。**

🔴 这不是「真值轨迹」。板只在**检测到板的帧**上有效,且它本身带三项误差:
   ① 印刷尺寸误差(打印机缩放,见下面「打印」一节);
   ② 板不平(卷边);③ 单帧 PnP 噪声。
   所以本工具报的是 s 及其 bootstrap 标准误 + 残差,不报「谁错了多少」。

══ 抄自哪里(禁止自研)═══════════════════════════════════════════════════════
检测 + 位姿这一段**逐行抄 OpenCV 官方 Python 样例**:
  文件 : opencv/samples/python/aruco_detect_board_charuco.py  (tag 4.13.0)
  URL  : https://github.com/opencv/opencv/blob/4.13.0/samples/python/aruco_detect_board_charuco.py
  raw  : https://raw.githubusercontent.com/opencv/opencv/4.13.0/samples/python/aruco_detect_board_charuco.py
  抄的是它 main() 里这五行(本文件 `detect_and_pose()` 内逐字保留):
      aruco_dict       = cv.aruco.getPredefinedDictionary(dict)
      board            = cv.aruco.CharucoBoard(board_size, square_len, marker_len, aruco_dict)
      charuco_detector = cv.aruco.CharucoDetector(board)
      charuco_corners, charuco_ids, marker_corners, marker_ids = charuco_detector.detectBoard(image)
      obj_points, img_points = board.matchImagePoints(charuco_corners, charuco_ids)
      flag, rvec, tvec       = cv.solvePnP(obj_points, img_points, cam_matrix, dist_coefficients)
  配套教程(同一套 API 的官方说明):
      https://docs.opencv.org/4.x/df/d4a/tutorial_charuco_detection.html
      https://docs.opencv.org/4.x/da/d13/tutorial_aruco_calibration.html
  🔑 **`aruco` 从 OpenCV 4.7.0 起并入主仓 `objdetect` 模块**,不再需要
     opencv-contrib(本机 `opencv-python-headless 4.13.0.92` 就自带 `cv2.aruco`,
     `getBuildInformation()` 里 contrib 为空也照样有)。旧的
     `estimatePoseCharucoBoard` / `interpolateCornersCharuco` 已弃用,
     官方样例现在走的就是上面 `matchImagePoints` + `solvePnP` 这条路,本文件跟着走。
     ⚠️ solvePnP 默认 ITERATIVE 对共面点**至少要 6 个点**才不会被当成非共面
     (样例自己在 except 里打印了这句),所以 `--min-corners` 默认 6 而不是 4。

Sim3 对齐**不自研**,搬我们自己已逐位复刻过的 rpg 端口:
  文件 : /Users/kaidongwang/Developer/pocketworld/vendor/xrslam/ate_posyaw_reference.py
  上游 : https://github.com/uzh-rpg/rpg_trajectory_evaluation
         commit 8c8ceec55c5c5094a6494208cfc5f54afe0bbc4d
         src/rpg_trajectory_evaluation/align_trajectory.py:28-79 (align_umeyama)
  这里用 `known_scale=False, yaw_only=False` 分支 = 标准 Umeyama(1991) 相似变换。
  🔑 板系是 z-**前**(板法线)、ARKit 是 y-up、XRSLAM 是 z-up —— 三个都不一样,
     但 Sim3 里的 R 是任意旋转,**不用手工换基**,这也是本工具不碰坐标约定的原因。

录制读取**不自研**,直接复用台架转换器的读法:
  文件 : ~/Developer/arloopbench/tools/pwvi_to_euroc.py
  复用 : `load_index()`(兼容 `len`/`length` 两种键名)、camera_index.csv 读法、
         frames.bin 的 seek/read、intrinsics.jsonl 的**按时间戳最近邻**配对
         (🔴 不能按下标:ARKit 臂每个 ARFrame 都写内参而帧流有背压丢帧,
          run-4ad6e500 是内参 1768 行 vs 帧 1671 行,按下标从第一次丢帧起就错位)。

══ 输入 ═════════════════════════════════════════════════════════════════════
录制目录(`run-*`)里要有:
  recording_manifest.json : camera.width/height/pixel_format(只吃 luma8)
  frames.bin              : 裸 luma8,W×H
  frames.pwvi             : JSONL,每行 {"frame":N,"offset":X,"len":W*H}
  camera_index.csv        : `timestamp_ns,relative_path`(relative_path 就是帧号)
  intrinsics.jsonl        : 每行 {"t":<秒>, "intrinsics_fxfycxcy":[fx,fy,cx,cy], ...}
轨迹:`--traj 名字=路径.tum`,可重复。TUM = `t x y z qx qy qz qw`,t 单位**秒**。
标定板:`--squares-x/-y`(方格数)、`--square-mm`、`--marker-mm`、`--dict`。

══ 输出 ═════════════════════════════════════════════════════════════════════
`--out` 目录下:
  board_poses.jsonl : 每个**检测到板**的帧一行 —— 时间戳、角点数、重投影 RMSE、
                      **板系下的相机中心 (x,y,z) 米** + 姿态四元数。
  board_camera.tum  : 同样的东西写成 tum,方便丢进现成的 ate 工具。
  scale_report.json : 每条轨迹的 s、1/s、过报百分比、bootstrap SE、Sim3/SE3 残差、
                      以及一条**与对齐无关**的旁证:路径长度之比。
stdout 打印人读的小结。

══ 打印这块板(用户要做的事)═════════════════════════════════════════════════
1. `--emit-board board.png --emit-board-dpi 300` 生成板图,按 300 DPI 原尺寸打印;
2. 🔴 **打完拿卡尺量一个方格的真实边长**,把量到的值填 `--square-mm`。
   打印机缩放 1% 就是尺度误差 1% —— 比我们要仲裁的 4.13% 只小 4 倍,不能靠标称值。
   量 N 个方格的总长再除以 N,误差降 N 倍。
3. 板贴在**硬平板**上(泡沫板/亚克力),卷边直接进 PnP 残差。

用法:
  python3 charuco_scale_arbiter.py --emit-board /tmp/board.png \
      --squares-x 5 --squares-y 7 --square-mm 40 --marker-mm 20 --dict DICT_6X6_250

  python3 charuco_scale_arbiter.py \
      --recording ~/Developer/viobench-recordings/run-xxxx \
      --traj arkit=<run>/arkit_poses.tum --traj xrslam=<run>/poses.tum \
      --squares-x 5 --squares-y 7 --square-mm 40.03 --marker-mm 20.01 \
      --dict DICT_6X6_250 --out /tmp/arb
"""
import argparse
import bisect
import csv
import json
import math
import os
import sys

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    raise SystemExit('🔴 需要 OpenCV ≥ 4.7(aruco 已在主仓 objdetect 里):\n'
                     '   pip3 install --user opencv-python-headless\n'
                     '   (装 opencv-contrib-python 也行,但 4.7+ 不必须)')


# ═══════════════════════════════════════════════════════════════════════════
# 录制读取 —— 复用 ~/Developer/arloopbench/tools/pwvi_to_euroc.py
# ═══════════════════════════════════════════════════════════════════════════

def load_index(pwvi):
    """读 frames.pwvi(JSONL)。兼容 `len` / `length` 两种键名。

    逐字复用 pwvi_to_euroc.py:load_index —— `run-5966aec0` 用的是 `length`。
    """
    out = []
    with open(pwvi) as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            d = json.loads(ln)
            n = d.get('len', d.get('length'))
            if n is None:
                raise SystemExit(f'🔴 {pwvi} 的记录既无 len 也无 length: {d}')
            out.append((d['frame'], d['offset'], n))
    return out


def load_recording(recdir):
    """返回 (W, H, [(t_ns, frame_id)], {frame_id: offset}, bytes_per_frame)。

    相机段逐字复用 pwvi_to_euroc.py:main() 的前半部分。
    """
    man = json.load(open(os.path.join(recdir, 'recording_manifest.json')))
    W = man['camera']['width']
    H = man['camera']['height']
    pixfmt = man['camera']['pixel_format']
    if 'luma8' not in pixfmt:
        raise SystemExit(f'🔴 只支持 luma8,本录制是 {pixfmt}')
    expect = W * H

    idx = load_index(os.path.join(recdir, 'frames.pwvi'))
    bad = [(n, ln) for n, _, ln in idx if ln != expect]
    if bad:
        raise SystemExit(f'🔴 {len(bad)} 帧长度与 {W}×{H} 不符,首例 {bad[0]}')
    off_by_frame = {n: o for n, o, _ in idx}

    ts = []
    with open(os.path.join(recdir, 'camera_index.csv')) as f:
        r = csv.reader(f)
        next(r)
        for row in r:
            if row:
                ts.append((int(row[0]), int(row[1])))
    return W, H, ts, off_by_frame, expect


def load_intrinsics(recdir, ts, tol_ns=1_000_000):
    """逐帧 fx fy cx cy,**按时间戳最近邻**配对(容差 1 ms)。

    配对逻辑逐字复用 pwvi_to_euroc.py 的 `--exposure-half` 那段(bisect + 1 ms),
    理由同上游注释:内参行数 ≠ 帧数,按下标会错位。
    """
    ipath = os.path.join(recdir, 'intrinsics.jsonl')
    if not os.path.exists(ipath):
        raise SystemExit('🔴 缺 intrinsics.jsonl,没有逐帧内参就无法做米制 PnP')
    recs = [json.loads(l) for l in open(ipath) if l.strip()]
    table = sorted((int(round(float(r['t']) * 1e9)), r.get('intrinsics_fxfycxcy'))
                   for r in recs if 't' in r)
    keys = [t for t, _ in table]

    out = [None] * len(ts)
    unmatched = 0
    for k, (t_ns, _fid) in enumerate(ts):
        i = bisect.bisect_left(keys, t_ns)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(keys) and abs(keys[j] - t_ns) <= tol_ns:
                if best is None or abs(keys[j] - t_ns) < abs(keys[best] - t_ns):
                    best = j
        if best is None:
            unmatched += 1
            continue
        v = table[best][1]
        if v and len(v) == 4:
            out[k] = [float(x) for x in v]
        else:
            unmatched += 1
    print(f'内参配对:内参 {len(recs)} 行 ↔ 相机 {len(ts)} 帧;'
          f'配上 {len(ts) - unmatched},配不上 {unmatched}')
    if unmatched > 0.01 * len(ts):
        raise SystemExit(f'🔴 内参配对率 {(len(ts) - unmatched) / len(ts):.2%} < 99%,拒绝')
    return out


# ═══════════════════════════════════════════════════════════════════════════
# Umeyama / Sim3 —— 搬 rpg_trajectory_evaluation@8c8ceec 的 align_umeyama
# (经由我们自己已逐位复刻过的 pocketworld/vendor/xrslam/ate_posyaw_reference.py)
# ═══════════════════════════════════════════════════════════════════════════

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
    C = 1.0 / n * np.dot(model_zerocentered.transpose(), data_zerocentered)
    sigma2 = 1.0 / n * np.multiply(data_zerocentered, data_zerocentered).sum()
    U_svd, D_svd, V_svd = np.linalg.svd(C)
    D_svd = np.diag(D_svd)
    V_svd = np.transpose(V_svd)

    S = np.eye(3)
    if (np.linalg.det(U_svd) * np.linalg.det(V_svd) < 0):
        S[2, 2] = -1

    if yaw_only:
        raise NotImplementedError('尺度仲裁不走 yaw_only 分支')
    else:
        R = np.dot(U_svd, np.dot(S, np.transpose(V_svd)))

    if known_scale:
        s = 1
    else:
        s = 1.0 / sigma2 * np.trace(np.dot(D_svd, S))

    t = mu_M - s * np.dot(R, mu_D)

    return s, R, t


# ═══════════════════════════════════════════════════════════════════════════
# 检测 + 位姿 —— 逐行抄 opencv/samples/python/aruco_detect_board_charuco.py
# ═══════════════════════════════════════════════════════════════════════════

def make_board(squares_x, squares_y, square_m, marker_m, dict_name, legacy=False):
    """样例 main() 里的三行(getPredefinedDictionary / CharucoBoard / CharucoDetector)。"""
    if dict_name.isdigit():
        did = int(dict_name)
    else:
        did = getattr(cv2.aruco, dict_name, None)
        if did is None:
            raise SystemExit(f'🔴 未知字典 {dict_name};可用的形如 DICT_4X4_50 / DICT_6X6_250')
    aruco_dict = cv2.aruco.getPredefinedDictionary(did)
    board_size = (squares_x, squares_y)
    board = cv2.aruco.CharucoBoard(board_size, square_m, marker_m, aruco_dict)
    if legacy:
        # OpenCV 4.6 及更早生成的板图,棋盘格奇偶相反;官方给的兼容开关。
        board.setLegacyPattern(True)
    charuco_detector = cv2.aruco.CharucoDetector(board)
    return board, charuco_detector


def detect_and_pose(image, board, charuco_detector, cam_matrix, dist_coefficients,
                    min_corners):
    """样例 while 循环里的检测 + PnP 段,原样保留调用顺序与参数。

    返回 (ok, rvec, tvec, n_corners, reproj_rmse_px)。
    """
    charuco_corners, charuco_ids, marker_corners, marker_ids = \
        charuco_detector.detectBoard(image)
    if charuco_ids is None or len(charuco_ids) < min_corners:
        return False, None, None, (0 if charuco_ids is None else len(charuco_ids)), None
    try:
        obj_points, img_points = board.matchImagePoints(charuco_corners, charuco_ids)
        flag, rvec, tvec = cv2.solvePnP(obj_points, img_points,
                                        cam_matrix, dist_coefficients)
    except cv2.error:
        # 样例原注释:共面点被当成非共面 —— 至少要 6 个点。
        return False, None, None, len(charuco_ids), None
    if not flag:
        return False, None, None, len(charuco_ids), None
    proj, _ = cv2.projectPoints(obj_points, rvec, tvec, cam_matrix, dist_coefficients)
    err = np.linalg.norm(proj.reshape(-1, 2) - img_points.reshape(-1, 2), axis=1)
    return True, rvec, tvec, len(charuco_ids), float(np.sqrt((err ** 2).mean()))


def rmat_to_quat(R):
    """R -> (qx,qy,qz,qw)。Shepperd/Eigen 的四分支法,数值稳定。"""
    tr = R[0, 0] + R[1, 1] + R[2, 2]
    if tr > 0:
        S = math.sqrt(tr + 1.0) * 2
        qw = 0.25 * S
        qx = (R[2, 1] - R[1, 2]) / S
        qy = (R[0, 2] - R[2, 0]) / S
        qz = (R[1, 0] - R[0, 1]) / S
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        S = math.sqrt(1.0 + R[0, 0] - R[1, 1] - R[2, 2]) * 2
        qw = (R[2, 1] - R[1, 2]) / S
        qx = 0.25 * S
        qy = (R[0, 1] + R[1, 0]) / S
        qz = (R[0, 2] + R[2, 0]) / S
    elif R[1, 1] > R[2, 2]:
        S = math.sqrt(1.0 + R[1, 1] - R[0, 0] - R[2, 2]) * 2
        qw = (R[0, 2] - R[2, 0]) / S
        qx = (R[0, 1] + R[1, 0]) / S
        qy = 0.25 * S
        qz = (R[1, 2] + R[2, 1]) / S
    else:
        S = math.sqrt(1.0 + R[2, 2] - R[0, 0] - R[1, 1]) * 2
        qw = (R[1, 0] - R[0, 1]) / S
        qx = (R[0, 2] + R[2, 0]) / S
        qy = (R[1, 2] + R[2, 1]) / S
        qz = 0.25 * S
    return qx, qy, qz, qw


def quat_to_rmat(qx, qy, qz, qw):
    n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
    if n == 0:
        return np.eye(3)
    qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
    return np.array([
        [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw)],
        [2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw)],
        [2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy)],
    ])


# ═══════════════════════════════════════════════════════════════════════════
# 轨迹
# ═══════════════════════════════════════════════════════════════════════════

def load_tum(path):
    """`t x y z qx qy qz qw`,t 单位秒。返回 (T[n], P[n,3], Q[n,4])。

    load() 的解析与 ate_posyaw_reference.py:6-14 一致(跳空行/#,要求 ≥8 列)。
    """
    T, P, Q = [], [], []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        f = ln.split()
        if len(f) < 8:
            continue
        T.append(float(f[0]))
        P.append([float(f[1]), float(f[2]), float(f[3])])
        Q.append([float(f[4]), float(f[5]), float(f[6]), float(f[7])])
    return np.array(T), np.array(P), np.array(Q)


def pair_by_time(t_board, t_traj, tol_s):
    """板帧时间戳 -> 轨迹最近邻下标,超过 tol 丢弃。返回 (idx_board, idx_traj)。"""
    order = np.argsort(t_traj)
    ts = t_traj[order]
    ib, it = [], []
    for k, t in enumerate(t_board):
        j = bisect.bisect_left(ts, t)
        best = None
        for c in (j - 1, j):
            if 0 <= c < len(ts) and abs(ts[c] - t) <= tol_s:
                if best is None or abs(ts[c] - t) < abs(ts[best] - t):
                    best = c
        if best is not None:
            ib.append(k)
            it.append(int(order[best]))
    return np.array(ib, dtype=int), np.array(it, dtype=int)


def path_length(P):
    if len(P) < 2:
        return 0.0
    return float(np.linalg.norm(np.diff(P, axis=0), axis=1).sum())


def arbitrate(name, P_board, t_board, tum_path, tol_s, lever_m, nboot, seed):
    T, P, Q = load_tum(tum_path)
    if len(T) == 0:
        return {'name': name, 'tum': tum_path, 'error': '轨迹为空'}
    if lever_m is not None:
        # body 位姿 -> 相机中心:p_cam = p_body + R(q) @ p_bc
        P = np.array([P[i] + quat_to_rmat(*Q[i]) @ lever_m for i in range(len(P))])
    ib, it = pair_by_time(t_board, T, tol_s)
    if len(ib) < 8:
        return {'name': name, 'tum': tum_path,
                'error': f'时间戳配对只有 {len(ib)} 对(< 8),无法定尺度',
                'n_paired': int(len(ib))}
    M = P_board[ib]      # model: 板系,米制
    D = P[it]            # data : 轨迹系,尺度未知
    s, R, t = align_umeyama_upstream(M, D, known_scale=False, yaw_only=False)
    res = np.linalg.norm((s * (R @ D.T).T + t) - M, axis=1)
    s1, R1, t1 = align_umeyama_upstream(M, D, known_scale=True, yaw_only=False)
    res1 = np.linalg.norm(((R1 @ D.T).T + t1) - M, axis=1)

    # bootstrap SE(按配对帧重采样)。SE 只管随机噪声,**对系统偏置(印刷缩放、
    # 板不平)完全无感** —— 09-20 的教训,别再拿 SE 当精度。
    rng = np.random.default_rng(seed)
    boots = []
    n = len(ib)
    for _ in range(nboot):
        k = rng.integers(0, n, n)
        try:
            sb, _, _ = align_umeyama_upstream(M[k], D[k], known_scale=False)
            boots.append(sb)
        except np.linalg.LinAlgError:
            pass
    boot_se = float(np.std(boots, ddof=1)) if len(boots) > 2 else None

    # 与对齐无关的旁证:路径长度之比(只在配对帧的子轨迹上算)
    L_board = path_length(M)
    L_traj = path_length(D)
    ratio_len = (L_board / L_traj) if L_traj > 0 else None

    return {
        'name': name,
        'tum': tum_path,
        'n_paired': int(n),
        'lever_arm_m': None if lever_m is None else [float(x) for x in lever_m],
        'scale_to_metric': float(s),                    # 轨迹 × s = 米
        'traj_over_report_pct': float((1.0 / s - 1.0) * 100.0),  # 轨迹比板大多少 %
        'scale_bootstrap_se': boot_se,
        'sim3_rmse_m': float(np.sqrt((res ** 2).mean())),
        'sim3_max_m': float(res.max()),
        'se3_rmse_m': float(np.sqrt((res1 ** 2).mean())),
        'path_len_board_m': L_board,
        'path_len_traj_raw': L_traj,
        'path_len_ratio_board_over_traj': ratio_len,
    }


# ═══════════════════════════════════════════════════════════════════════════

def main():
    ap = argparse.ArgumentParser(
        description='ChArUco 板做米制参照,仲裁各条轨迹的绝对尺度',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--recording', help='run-* 录制目录')
    ap.add_argument('--traj', action='append', default=[],
                    metavar='名字=路径.tum', help='待仲裁轨迹,可重复')
    ap.add_argument('--lever-mm', action='append', default=[], metavar='名字=x,y,z',
                    help='该轨迹的 body→camera 杠杆臂(毫米,body 系)。'
                         'XRSLAM 报 body/IMU 位姿而板给的是相机中心,'
                         '不修正会留下约 34 mm 的系统残差(见 09-16 判决)')
    # 板参数(与官方样例同名:-w -h -sl -ml -d)
    ap.add_argument('--squares-x', type=int, default=5, help='X 方向方格数(样例 -w)')
    ap.add_argument('--squares-y', type=int, default=7, help='Y 方向方格数(样例 -h)')
    ap.add_argument('--square-mm', type=float, default=40.0,
                    help='方格边长,毫米(样例 -sl,单位改成 mm)。🔴 填卡尺量到的值')
    ap.add_argument('--marker-mm', type=float, default=20.0, help='marker 边长,毫米(样例 -ml)')
    ap.add_argument('--dict', default='DICT_6X6_250',
                    help='字典名(DICT_4X4_50 …)或官方样例 -d 的数字')
    ap.add_argument('--legacy-board', action='store_true',
                    help='板图是 OpenCV ≤4.6 生成的 ⇒ setLegacyPattern(True)')
    # 处理
    ap.add_argument('--stride', type=int, default=1, help='每 N 帧取一帧')
    ap.add_argument('--limit', type=int, default=0, help='只看前 N 帧(0=全部)')
    ap.add_argument('--min-corners', type=int, default=6,
                    help='少于这么多 charuco 角点就丢帧(默认 6:solvePnP 对共面点的下限)')
    ap.add_argument('--max-reproj-px', type=float, default=2.0,
                    help='重投影 RMSE 超过它就丢帧')
    ap.add_argument('--pair-tol-ms', type=float, default=5.0, help='与轨迹配对的时间容差')
    ap.add_argument('--bootstrap', type=int, default=500)
    ap.add_argument('--seed', type=int, default=20260922)
    ap.add_argument('--out', help='输出目录')
    ap.add_argument('--debug-images', help='把前若干帧的检测叠加图写到这个目录')
    ap.add_argument('--debug-n', type=int, default=12)
    # 只生成板图
    ap.add_argument('--emit-board', help='生成板图 PNG 后退出(用于打印)')
    ap.add_argument('--emit-board-dpi', type=float, default=300.0)
    a = ap.parse_args()

    square_m = a.square_mm / 1000.0
    marker_m = a.marker_mm / 1000.0
    if not (0 < marker_m < square_m):
        raise SystemExit('🔴 marker 边长必须 0 < marker < square')

    board, detector = make_board(a.squares_x, a.squares_y, square_m, marker_m,
                                 a.dict, a.legacy_board)

    # ── 只出板图(官方 create_board_charuco 样例的 generateImage 路径)──────
    if a.emit_board:
        # https://github.com/opencv/opencv/blob/4.13.0/samples/cpp/tutorial_code/objectDetection/create_board_charuco.cpp
        px_per_m = a.emit_board_dpi / 0.0254
        W = int(round(a.squares_x * square_m * px_per_m))
        H = int(round(a.squares_y * square_m * px_per_m))
        img = board.generateImage((W, H))
        cv2.imwrite(a.emit_board, img)
        print(f'✅ {a.emit_board}  {W}×{H} px @ {a.emit_board_dpi} DPI'
              f'  = {a.squares_x * a.square_mm:.1f}×{a.squares_y * a.square_mm:.1f} mm')
        print('🔴 打完请用卡尺量实际方格边长,把量到的值回填 --square-mm;'
              '打印机缩放 1% 就是 1% 的尺度误差。')
        return 0

    if not a.recording:
        raise SystemExit('🔴 要么给 --emit-board,要么给 --recording')

    W, H, ts, off_by_frame, expect = load_recording(a.recording)
    print(f'录制 {W}×{H}  camera_index {len(ts)} 帧')
    intr = load_intrinsics(a.recording, ts)
    if a.limit:
        ts = ts[:a.limit]
        intr = intr[:a.limit]

    dist = np.zeros((5, 1))   # ARKit 出的是已校正内参,不给畸变系数

    rows = []
    binp = os.path.join(a.recording, 'frames.bin')
    n_try = n_det = 0
    n_dropped_reproj = 0
    dbg = 0
    if a.debug_images:
        os.makedirs(a.debug_images, exist_ok=True)
    with open(binp, 'rb') as fb:
        for k in range(0, len(ts), max(1, a.stride)):
            t_ns, fid = ts[k]
            if fid not in off_by_frame or intr[k] is None:
                continue
            fb.seek(off_by_frame[fid])
            buf = fb.read(expect)
            if len(buf) != expect:
                continue
            gray = np.frombuffer(buf, dtype=np.uint8).reshape(H, W)
            # 样例吃的是 BGR(imread 默认);detectBoard 对灰度也工作,
            # 但为了与样例逐行一致这里转成 3 通道再喂。
            image = cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)
            fx, fy, cx, cy = intr[k]
            cam_matrix = np.array([[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]])
            n_try += 1
            ok, rvec, tvec, ncorn, rms = detect_and_pose(
                image, board, detector, cam_matrix, dist, a.min_corners)
            if not ok:
                continue
            if rms is not None and rms > a.max_reproj_px:
                n_dropped_reproj += 1
                continue
            n_det += 1
            R_cb, _ = cv2.Rodrigues(rvec)          # X_cam = R_cb @ X_board + t
            C_b = (-R_cb.T @ tvec).ravel()          # 相机中心(板系,米)
            R_bc = R_cb.T                           # 相机 -> 板
            qx, qy, qz, qw = rmat_to_quat(R_bc)
            rows.append({
                't': t_ns / 1e9, 't_ns': t_ns, 'frame': fid,
                'n_corners': int(ncorn), 'reproj_rmse_px': rms,
                'cam_in_board_m': [float(C_b[0]), float(C_b[1]), float(C_b[2])],
                'q_board_cam': [qx, qy, qz, qw],
                'dist_to_board_m': float(np.linalg.norm(C_b)),
            })
            if a.debug_images and dbg < a.debug_n:
                vis = image.copy()
                cc, ci, mc, mi = detector.detectBoard(image)
                if mi is not None and len(mi) > 0:
                    cv2.aruco.drawDetectedMarkers(vis, mc)
                if ci is not None and len(ci) > 0:
                    cv2.aruco.drawDetectedCornersCharuco(vis, cc, ci)
                cv2.drawFrameAxes(vis, cam_matrix, dist, rvec, tvec, 0.1)
                cv2.imwrite(os.path.join(a.debug_images, f'{fid:06d}.png'), vis)
                dbg += 1
            if n_try % 200 == 0:
                print(f'  帧 {k}/{len(ts)}  检出 {n_det}', flush=True)

    print(f'\n看了 {n_try} 帧,检出板 {n_det} 帧 ({n_det / max(1, n_try):.1%});'
          f'重投影超限丢 {n_dropped_reproj}')
    if n_det < 8:
        raise SystemExit('🔴 检出帧 < 8,定不了尺度。检查:板参数对不对 / 板在不在画面里 / '
                         '是不是 --legacy-board')

    P_board = np.array([r['cam_in_board_m'] for r in rows])
    t_board = np.array([r['t'] for r in rows])
    d = np.linalg.norm(P_board, axis=1)
    print(f'板到相机距离 {d.min():.3f}–{d.max():.3f} m(中位 {np.median(d):.3f});'
          f'板系路径长 {path_length(P_board):.3f} m;'
          f'重投影 RMSE 中位 {np.median([r["reproj_rmse_px"] for r in rows]):.3f} px')

    levers = {}
    for spec in a.lever_mm:
        nm, _, v = spec.partition('=')
        xyz = [float(x) / 1000.0 for x in v.split(',')]
        if len(xyz) != 3:
            raise SystemExit(f'🔴 --lever-mm 要 3 个分量: {spec}')
        levers[nm] = np.array(xyz)

    results = []
    for spec in a.traj:
        nm, _, p = spec.partition('=')
        if not p:
            raise SystemExit(f'🔴 --traj 要写成 名字=路径.tum,收到 {spec}')
        results.append(arbitrate(nm, P_board, t_board, p, a.pair_tol_ms / 1000.0,
                                 levers.get(nm), a.bootstrap, a.seed))

    print('\n══ 尺度仲裁 ══════════════════════════════════════════════════')
    for r in results:
        if 'error' in r:
            print(f'  {r["name"]:12s}  🔴 {r["error"]}')
            continue
        se = '' if r['scale_bootstrap_se'] is None else f' ±{r["scale_bootstrap_se"]:.5f}'
        print(f'  {r["name"]:12s}  s(轨迹×s=米) = {r["scale_to_metric"]:.5f}{se}'
              f'   轨迹过报 {r["traj_over_report_pct"]:+.2f}%'
              f'   Sim3 残差 {r["sim3_rmse_m"] * 100:.2f} cm'
              f'   SE3 残差 {r["se3_rmse_m"] * 100:.2f} cm'
              f'   n={r["n_paired"]}'
              f'   路径长比 {r["path_len_ratio_board_over_traj"]:.5f}')
    print('🔴 bootstrap SE 只管随机噪声;印刷缩放/板不平这类系统偏置它看不见。')

    if a.out:
        os.makedirs(a.out, exist_ok=True)
        with open(os.path.join(a.out, 'board_poses.jsonl'), 'w') as f:
            for r in rows:
                f.write(json.dumps(r) + '\n')
        with open(os.path.join(a.out, 'board_camera.tum'), 'w') as f:
            f.write('# t x y z qx qy qz qw  (相机中心在板坐标系,米)\n')
            for r in rows:
                x, y, z = r['cam_in_board_m']
                qx, qy, qz, qw = r['q_board_cam']
                f.write(f'{r["t"]:.9f} {x:.9f} {y:.9f} {z:.9f} '
                        f'{qx:.9f} {qy:.9f} {qz:.9f} {qw:.9f}\n')
        with open(os.path.join(a.out, 'scale_report.json'), 'w') as f:
            json.dump({
                'recording': os.path.abspath(a.recording),
                'board': {'squares_x': a.squares_x, 'squares_y': a.squares_y,
                          'square_mm': a.square_mm, 'marker_mm': a.marker_mm,
                          'dict': a.dict, 'legacy': a.legacy_board},
                'frames_examined': n_try, 'frames_detected': n_det,
                'dropped_reproj': n_dropped_reproj,
                'reproj_rmse_px_median':
                    float(np.median([r['reproj_rmse_px'] for r in rows])),
                'board_path_len_m': path_length(P_board),
                'trajectories': results,
                'opencv_version': cv2.__version__,
                'copied_from':
                    'opencv/samples/python/aruco_detect_board_charuco.py @ 4.13.0',
                'align_from':
                    'rpg_trajectory_evaluation@8c8ceec align_trajectory.align_umeyama',
            }, f, indent=2, ensure_ascii=False)
        print(f'\n✅ {a.out}/scale_report.json')
    return 0


if __name__ == '__main__':
    sys.exit(main())
