#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""🔴 **bench-only ruler** —— 用同一份录制里的 LiDAR 深度,给 ARKit / XRSLAM 各自的轨迹定**绝对米制尺度**。

══ 口径(用户 2026-09-22 / 09-24)══════════════════════════════════════════════════════
LiDAR 只作研发期量尺。永不进产品代码、产品管线、产品提案。这里算出的 k 只用来**校准我们手里的仪器**
(XRSLAM 的尺度到底差多少、ARKit 自己偏多少),不是产品输入、不是产品兜底、不是机型要求。

══ 输出口径(与 09-24 真值审计的规范估计器 scale_eval.py 一致)════════════════════════
  k = 轨迹尺度 / 米          k > 1 ⇒ 轨迹比真实世界**大**;带符号报 (k−1)。
  (depth_ruler.py 的 s 是「轨迹 × s = 米」,k = 1/s = 它报的 traj_over_report_factor。)
规范估计器的四条约定,在这里的对应:
  ① 相机中心:XRSLAM 的 TUM 是 BODY(IMU)位姿 ⇒ 按回放 yaml 的 q_bc/p_bc 换到相机:
     R_wc = R_wb·R_bc,C = p_wb + R_wb·p_bc(= scale_eval.body_to_cam)。ARKit 本来就是相机位姿。
  ② 帧时间:XRSLAM 位姿时间 = 帧时间 + td(+ exposure/2)。手机回放有逐帧账 intrinsics_ledger.csv
     (t_effective ↔ 录制帧 t_ns)⇒ 精确反查;Mac 宿主回放没有账 ⇒ 用 scale_eval.remap_to_frames
     (td + 逐帧 exposure_s/2,容差 0.5 ms)。
     🔴 [2026-09-24 rec30] **首选** `--xrslam-camera`:手机回放直接写的
     poses_camera_by_recording_frame.csv(引擎交回的 CAMERA 位姿,按录制帧号 + 整数纳秒 t_ns 键控)⇒
     按 t_ns **整数相等**取,零容差、不插值、不经外参换算。子集帧没有引擎位姿(XRSLAM 没收那一帧,
     或收了但没在跟踪)就不用那一帧,并在 provenance 里点数。首跑 run-fb5d3a8f 的教训:60 Hz 录制按
     AR 帧号每 18 帧取子集,XRSLAM 只收 30 Hz、相位还中途翻了一次 ⇒ 前 17 s 的 59 个子集帧只有 3 个被收,
     位姿只能插值,XRSLAM 的 G4 对齐闸不过(帧对间 IQR 0.113 vs ARKit 0.019)。现在录制器按引擎同一道闸
     30 Hz 落盘、子集导出只挑引擎会收的帧(PwBenchLidarRecordingWriter W12),这里就只剩整数相等。
  ③ 丢掉 ARKit 没在跟踪的行:平移恰为 0 的行(scale_eval.valid_ref_mask);录制里有 arkit_tracking 键
     (本台架录制器 W6 写的)时,再丢掉一切 ≠ normal 的帧。
  ④ 不确定度用**循环平移噪声底**(noise_floor.py 的做法),不用 bootstrap —— 见下「噪声底」。

══ 尺子本体:逐字复用 09-22 的 depth_ruler.py(research @ 76b8d47,vendored/ 下原样)════════
  特征 + 匹配   SIFT + BFMatcher.knnMatch + Lowe 比值 0.8(IJCV 2004 §7.1;OpenCV py_matcher 教程)
  三角化       cv2.triangulatePoints(DLT,H&Z §12.2),**位姿不估**:两帧相对位姿取自被测轨迹
  深度取值      depth_ruler.sample_depth():u_d = (u_c+0.5)·W_d/W_c − 0.5 最近邻,只留 ≥ high 置信度
  尺度对齐      monodepth2 evaluate_depth.py L207 `ratio = np.median(gt)/np.median(pred)`(逐帧对),
               L218 `med = np.median(ratios)`(跨帧对)—— 单目深度评测的标准做法
               (Zhou et al. CVPR 2017;Eigen et al. NIPS 2014 §3.2)。
  本文件只换了**编排**(depth_ruler.run 一次只吃一条轨迹、按 20 ms 最近邻配位姿):
  a) 一次匹配、多条轨迹复用(同一组帧对 ⇒ 各轨迹的 k 可直接相除,也让对照组便宜);
  b) 位姿按上面①②③精确配到帧,深度与帧按**同一个 ARFrame 时间戳**配(容差 0.5 ms,不是 20 ms);
  c) 闸 + 对照 + 噪声底 + 与规范 Sim3 的交叉核对。
  方法地图:exact_upstream = 上面四行(函数直接 import 自 vendored/depth_ruler.py);
  product_adapter = a–c;not_implemented = 无。

══ 闸(不过就不给数,exit 1)═════════════════════════════════════════════════════════════
  G1 有效帧对 ≥ max(--min-pairs, 50% 尝试数)
  G2 帧对**之间**的一致性:per-pair 尺度的 IQR / 中位数 ≤ --max-between(默认 0.15)
  G3 帧对**之内**的一致性:逐点比值 IQR / 中位数 的中位数 ≤ --max-within(默认 0.25)
  🔴 阈值是**临时的**:合成数据上定的(真 0.0005–0.002、洗牌 0.31),第一份真录制要重新看。
     所以每次运行都**自带阴性对照**,闸有没有牙齿当场验:
  NC 深度帧洗牌(每帧换成另一帧的深度,错位排列)⇒ **必须**过不了 G1–G3,否则整份报告判无效。
  PC 相机中心 ×1.05(绕首帧)⇒ 恢复出的 k 必须是原来的 1.05 倍(±0.5%)。
  G4 对齐:把深度换成时间上相邻 ±1/±2 张深度帧,帧对间一致性必须在 0 偏移处最好(自证深度 ↔ 帧同步)。
  噪声底(noise_floor.py 原法):真实的 XRSLAM-vs-ARKit Sim3 残差序列循环平移随机 lag,加到 k0×ARKit 路径上,
     **重跑本尺子**;k0 = 1.00 给 95% 带,k0 = 1.05 必须恢复。报「XRSLAM 的 k 的 95% 噪声底 = k × [lo, hi]」。
     🔴 第一版我在「帧对基线」空间做循环平移,合成上带宽恒为 0 —— 中位数只看符号,每个残差除以正的基线
     不改符号 ⇒ 平移对中位数**结构性无效**。已换成上面这版(轨迹空间,与 noise_floor.py 同一空间)。
     ARKit 自己没有第二条参照给残差频谱 ⇒ 不报噪声底,只报下面的深度侧区间与分段 k。
  深度侧区间(诊断):只取时间上互不重叠的帧对,中位数的顺序统计量 95% 区间(二项,Conover §3.2)。

══ 已知局限(照实报,不替它圆)══════════════════════════════════════════════════════════
  · LiDAR 自己不是真值。公开独立测试:iPhone 13 Pro 后置 LiDAR 在 1/2/3 m 处测门距 MAE
    1.37/0.48/1.40 cm(画面中心,边缘更差;IEEE OJEMB 5:54-58, 2024);整场扫描的尺度修正系数
    97.72%–104.60%(J.S. Held 白皮书,即 −2.3%…+4.6%,那是扫描拼接后的量,含 ARKit 位姿)。
    本尺子用的是**逐帧**深度 ⇒ 更接近前者,但没有针对我们用法的独立数 ⇒ **LiDAR 的系统偏差原样进 k**
    (合成里 LiDAR ×1.02 ⇒ k 恰好偏 1/1.02,见 test_lidar_ruler_synth.py)。
    ⇒ 读法:|k−1| 远大于 ~2–5%(如 −12%)是**确定**的;−1.6% / −3% 这一档要再对一块印出来的
    ChArUco 板(vendored/charuco_scale_arbiter.py,同一份录制)才能分清是 VIO 还是 LiDAR。
  · sceneDepth 本身是 LiDAR + RGB 经机器学习融合出来的稠密图(WWDC20-10611),只有 high 置信度
    像素才有较多 LiDAR 支撑;iPhone LiDAR 有效距离约 5 m 内,近距 0.3–3 m 最好。
  · 深度图 256×192 对 1920×1440 是 7.5× 下采样:物体边缘上的特征点会取到前景/背景混合深度 ⇒ 中位数。
  · ARKit 在有 LiDAR 的机型上可能本来就用了 LiDAR ⇒ ARKit 的 k 与 LiDAR 不一定独立(量级无数据)。
  · 像素映射式是推论(Apple 没公布公式);合成上与自己的逆式互逆到 0.04 µm,那验的是自洽,不是 Apple。

vendored/(只读取用的原件拷贝,sha256 为**原件**的;本目录只做过一处改动):
  depth_ruler.py / charuco_scale_arbiter.py / synth_verify.py / synth_depth_verify.py
      ← 研究仓 research/basalt-vio-phone-bench-20260829 @ 76b8d47 tools/scale_arbiter/
        (原件 sha256 d05a125f… / ed789fc9… / 33b31109… / 79d623d1…)
        唯一改动:depth_ruler.py 文件头第 38–39 行删去与本任务无关的一句背景说明(不碰任何代码行)。
  scale_eval.py / noise_floor.py ← 09-24 真值审计 scratchpad/scaleS1/(719ebe52… / cb48630b…),未改
  ate.py ← ~/Developer/viobench-recordings/ate.py(6583a967…),未改

用法:
  /usr/bin/python3 lidar_ruler.py --recording <run-…|run-…/ruler_subset> \
      --arkit                                  # 录制里的 arkit_poses.tum
      --xrslam-camera xr=<replay_…>/poses_camera_by_recording_frame.csv \   # rec30 起的首选(精确键控)
      [--xrslam-ledger xr=<replay_…>/intrinsics_ledger.csv]   # 可选:把缺位姿的帧分成「没收 / 收了没跟踪」
      --out <dir>
  老回放(没有 poses_camera_by_recording_frame.csv)仍可走 BODY:
      --xrslam xr=<replay_…>/poses_body.tum --xrslam-ledger xr=<replay_…>/intrinsics_ledger.csv \
      --xrslam-yaml <replay_…>/<on 臂 yaml>    # 取 cam0.extrinsic.q_bc / p_bc
  (要能 import cv2 + numpy 的解释器;本机 /usr/bin/python3 = cv2 4.13.0 + numpy 2.0.2。)
"""

import argparse
import bisect
import json
import os
import re
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VENDORED = os.path.join(HERE, 'vendored')
sys.path.insert(0, VENDORED)

try:
    import cv2
except ImportError:  # pragma: no cover
    raise SystemExit('🔴 需要 OpenCV ≥ 4.4:用 /usr/bin/python3(cv2 4.13.0)')

import depth_ruler as DR                                   # noqa: E402  逐字复用(research @76b8d47)
from charuco_scale_arbiter import (                        # noqa: E402
    load_recording, load_intrinsics, load_tum, quat_to_rmat)

NOTICE = ('🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,永不进入产品代码、产品管线,'
          '也不作为任何产品方案的一部分')

D_ARKIT_TO_OPENCV = DR.D_ARKIT_TO_OPENCV          # diag(1,-1,-1)

# scale_eval.py(09-24 真值审计)用的设备 yaml 外参:cfg/dev_r6e2d.yaml,q_bc [-0.7071068, 0.7071068, 0, 0]
# (x,y,z,w)⇒ R_BC 如下;p_bc 米。没给 --xrslam-yaml 时才用它,且在报告里标出来。
R_BC_DEFAULT = np.array([[0.0, -1.0, 0.0], [-1.0, 0.0, 0.0], [0.0, 0.0, -1.0]])
P_BC_DEFAULT = np.array([0.03290364, -0.00696553, -0.00286231])


# ═════════════════════════════════════════════════════════════════════════════════════════
# 规范估计器(scale_eval.py)的函数:原文件 vendored/ 下原样;它 import 时要 exec ate.py,
# 路径写死在 ~/Developer/viobench-recordings/ate.py —— 那台机器没有这份文件时换成 vendored/ate.py
# (两份逐字节相同,sha256 6583a967…)。只替换这一个路径常量,函数体不动。
# ═════════════════════════════════════════════════════════════════════════════════════════

def _load_scale_eval():
    src = open(os.path.join(VENDORED, 'scale_eval.py'), encoding='utf-8').read()
    ate = os.path.expanduser('~/Developer/viobench-recordings/ate.py')
    if not os.path.exists(ate):
        src = src.replace('ATE_PY = os.path.expanduser("~/Developer/viobench-recordings/ate.py")',
                          f'ATE_PY = {os.path.join(VENDORED, "ate.py")!r}')
    ns = {'__name__': 'scale_eval_vendored', '__file__': os.path.join(VENDORED, 'scale_eval.py')}
    exec(compile(src, os.path.join(VENDORED, 'scale_eval.py'), 'exec'), ns)
    return ns


SE = _load_scale_eval()


# ═════════════════════════════════════════════════════════════════════════════════════════
# 位姿:都变成「每个录制帧时间戳 t_ns → (R_wc 以 OpenCV 相机轴, 相机中心 C)」
# ═════════════════════════════════════════════════════════════════════════════════════════

def _tum_rows(path):
    """load_tum 的时间是秒(float);这里要逐行保留 9 位小数 ⇒ 按字符串解析成整数纳秒。"""
    out = []
    for ln in open(path):
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        f = ln.replace(',', ' ').split()
        if len(f) < 8:
            continue
        sec, _, frac = f[0].partition('.')
        t_ns = int(sec) * 1_000_000_000 + int((frac + '000000000')[:9]) if frac else int(sec) * 10**9
        out.append((t_ns, np.array([float(x) for x in f[1:4]]), [float(x) for x in f[4:8]]))
    return out


def tracking_by_t(recdir):
    """intrinsics.jsonl 的 arkit_tracking(本台架录制器 W6);老录制没有 ⇒ 空。"""
    out = {}
    p = os.path.join(recdir, 'intrinsics.jsonl')
    if not os.path.exists(p):
        return out
    for ln in open(p):
        ln = ln.strip()
        if not ln:
            continue
        d = json.loads(ln)
        if 'arkit_tracking' in d and 't' in d:
            out[int(round(float(d['t']) * 1e9))] = d['arkit_tracking']
    return out


def arkit_poses(recdir, path, frame_ts, tol_ns=500_000):
    """ARKit 相机位姿(x右/y上/z后)→ OpenCV 轴。时间戳就是 ARFrame.timestamp ⇒ 与帧精确相等。"""
    rows = _tum_rows(path)
    trk = tracking_by_t(recdir)
    keys = sorted(trk)
    stats = {'rows': len(rows), 'zero_translation_dropped': 0, 'not_normal_dropped': 0,
             'tracking_key_present': bool(trk)}
    by_t = {}
    for t_ns, p, q in rows:
        if np.abs(p).sum() == 0:                         # scale_eval.valid_ref_mask
            stats['zero_translation_dropped'] += 1
            continue
        if trk:
            i = bisect.bisect_left(keys, t_ns)
            state = None
            for j in (i - 1, i):
                if 0 <= j < len(keys) and abs(keys[j] - t_ns) <= tol_ns:
                    state = trk[keys[j]]
            if state != 'normal':
                stats['not_normal_dropped'] += 1
                continue
        R = quat_to_rmat(*q) @ D_ARKIT_TO_OPENCV
        by_t[t_ns] = (R, p)
    return _snap_to_frames(by_t, frame_ts, tol_ns), stats


def camera_poses_opencv(path, frame_ts, tol_ns=500_000):
    """通用:TUM 已是相机位姿、OpenCV 轴(合成数据 / 其它工具的输出)。"""
    by_t = {t: (quat_to_rmat(*q), p) for t, p, q in _tum_rows(path)}
    return _snap_to_frames(by_t, frame_ts, tol_ns), {'rows': len(by_t)}


def _snap_to_frames(by_t, frame_ts, tol_ns):
    keys = sorted(by_t)
    out = {}
    for t in frame_ts:
        i = bisect.bisect_left(keys, t)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(keys) and abs(keys[j] - t) <= tol_ns:
                if best is None or abs(keys[j] - t) < abs(keys[best] - t):
                    best = j
        if best is not None:
            out[t] = by_t[keys[best]]
    return out


def parse_extrinsic_yaml(path):
    """XRSLAM 配置 yaml(lib/vio/ffi/xrslam_config.dart 生成)里 cam0.extrinsic 的 q_bc(x,y,z,w)/ p_bc。"""
    txt = open(path).read()
    q = re.search(r'q_bc:\s*\[([^\]]+)\]', txt)
    p = re.search(r'p_bc:\s*\[([^\]]+)\]', txt)
    if not (q and p):
        raise SystemExit(f'🔴 {path} 里找不到 q_bc / p_bc')
    qv = [float(x) for x in q.group(1).split(',')]
    pv = np.array([float(x) for x in p.group(1).split(',')])
    return quat_to_rmat(*qv), pv


def xrslam_body_poses(path, frame_ts, R_bc, p_bc, ledger=None, shift_s=None, tol_ns=500_000):
    """XRSLAM BODY 位姿 → 录制帧时间 → 相机位姿(OpenCV 轴,scale_eval.body_to_cam 同式)。

    ledger:手机回放的 intrinsics_ledger.csv(列 t_ns = 录制帧时间,t_effective = 喂进引擎的时间,
            即 BODY 位姿的时间戳)⇒ 精确反查。
    shift_s:{frame_t_ns: td + exposure/2}(Mac 宿主回放)⇒ scale_eval.remap_to_frames 的做法。
    """
    rows = _tum_rows(path)
    stats = {'rows': len(rows), 'mapping': 'ledger' if ledger else 'shift'}
    eff_to_frame = {}
    if ledger:
        import csv
        with open(ledger) as f:
            for r in csv.DictReader(f):
                if r.get('t_effective') and r.get('t_ns') and int(r['t_ns']) >= 0:
                    eff_to_frame[int(round(float(r['t_effective']) * 1e9))] = int(r['t_ns'])
    else:
        for t_frame, sh in shift_s.items():
            eff_to_frame[t_frame + int(round(sh * 1e9))] = t_frame
    keys = sorted(eff_to_frame)
    by_t = {}
    unmapped = 0
    for t_ns, p_wb, q in rows:
        i = bisect.bisect_left(keys, t_ns)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(keys) and abs(keys[j] - t_ns) <= tol_ns:
                if best is None or abs(keys[j] - t_ns) < abs(keys[best] - t_ns):
                    best = j
        if best is None:
            unmapped += 1
            continue
        R_wb = quat_to_rmat(*q)
        by_t[eff_to_frame[keys[best]]] = (R_wb @ R_bc, p_wb + R_wb @ p_bc)
    stats['unmapped_rows'] = unmapped
    return _snap_to_frames(by_t, frame_ts, 1), stats


def xrslam_camera_by_frame(path, frame_ts, ledger=None):
    """[rec30] 手机回放的 poses_camera_by_recording_frame.csv → {录制帧 t_ns: (R_wc, C)}。

    键 = 整数纳秒 t_ns,与子集 camera_index.csv 的 t_ns **整数相等**才算配上(零容差、不插值)。
    位姿本来就是引擎交回的 CAMERA 位姿(world_from_camera、OpenCV 相机轴;与 BODY·T_bc 逐帧相等,
    run-fb5d3a8f 回放实测中心差 ≤ 1.5e-7 m、旋转 ≤ 1.5e-5°)⇒ 不经外参换算。
    ledger(可选,intrinsics_ledger.csv):引擎**收下**的录制帧 t_ns 集合,用来把缺位姿的子集帧分成
    「XRSLAM 没收」与「收了但不是 TRACKING_SUCCESS」。
    """
    import csv
    by_t, dup, offs = {}, 0, []
    with open(path) as f:
        for r in csv.DictReader(f):
            t = int(r['t_ns'])
            if t in by_t:
                dup += 1
            q = [float(r[k]) for k in ('qx', 'qy', 'qz', 'qw')]
            by_t[t] = (quat_to_rmat(*q), np.array([float(r['tx']), float(r['ty']), float(r['tz'])]))
            if r.get('engine_t'):
                offs.append(float(r['engine_t']) - t * 1e-9)
    matched = {t: by_t[t] for t in frame_ts if t in by_t}
    missing = [t for t in frame_ts if t not in by_t]
    stats = {'rows': len(by_t), 'mapping': 'exact_recording_t_ns (integer equality, no interpolation)',
             'duplicate_t_ns': dup, 'recording_frames': len(frame_ts),
             'recording_frames_with_pose': len(matched), 'recording_frames_without_pose': len(missing),
             'engine_t_minus_t_ns_s': [min(offs), max(offs)] if offs else None}
    if ledger:
        with open(ledger) as f:
            admitted = {int(r['t_ns']) for r in csv.DictReader(f) if r.get('t_ns') and int(r['t_ns']) >= 0}
        stats['missing_not_admitted_by_xrslam'] = sum(1 for t in missing if t not in admitted)
        stats['missing_admitted_but_not_tracking'] = sum(1 for t in missing if t in admitted)
        stats['ledger'] = os.path.abspath(ledger)
    return matched, stats


# ═════════════════════════════════════════════════════════════════════════════════════════
# 帧对 + 匹配(只算一次)
# ═════════════════════════════════════════════════════════════════════════════════════════

def DR_nearest(keys, key, tol):
    """depth_ruler.run() 里的 nearest(),原样(它是 run 的内部函数,没法 import)。"""
    i = bisect.bisect_left(keys, key)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(keys) and abs(keys[j] - key) <= tol:
            if best is None or abs(keys[j] - key) < abs(keys[best] - key):
                best = j
    return best


class Scene:
    """录制 + 深度 + 帧对 + 匹配。所有轨迹共用同一组帧对。"""

    def __init__(self, recdir, args):
        self.recdir = recdir
        self.args = args
        self.W, self.H, self.ts, self.off_by_frame, self.bpf = load_recording(recdir)
        intr = load_intrinsics(recdir, self.ts)
        self.depth_rows, self.DW, self.DH = DR.load_depth_index(recdir)
        self.reader = DR.DepthReader(recdir, self.DW, self.DH)
        dt = sorted((r['t_ns'], i) for i, r in enumerate(self.depth_rows))
        self._dkeys = [t for t, _ in dt]
        self._didx = [i for _, i in dt]
        tol = int(args.depth_tol_ms * 1e6)
        self.frames = []                       # 有内参 + 有深度(同一 ARFrame)的帧
        for k, (t_ns, fid) in enumerate(self.ts):
            if intr[k] is None:
                continue
            j = DR_nearest(self._dkeys, t_ns, tol)
            if j is None:
                continue
            self.frames.append({'t_ns': t_ns, 'frame': fid, 'K': intr[k], 'depth_i': self._didx[j],
                                'depth_order': j})
        self.frames_fd = open(os.path.join(recdir, 'frames.bin'), 'rb')
        self._img_cache = {}
        self.detector, self.norm = DR.make_detector(args.detector, args.features)
        self._feat_cache = {}

    def image(self, fr):
        self.frames_fd.seek(self.off_by_frame[fr['frame']])
        raw = self.frames_fd.read(self.bpf)
        return np.frombuffer(raw, dtype=np.uint8).reshape(self.H, self.W)

    def features(self, fr):
        key = fr['frame']
        if key not in self._feat_cache:
            kp, de = self.detector.detectAndCompute(self.image(fr), None)
            self._feat_cache[key] = (np.float64([k.pt for k in kp]) if kp else np.zeros((0, 2)), de)
        return self._feat_cache[key]

    def select_pairs(self, usable):
        """depth_ruler.run() 的帧对规则原样:每帧往后找 ~pair_dt(±25%)的那一帧,均匀抽 --pairs 对。"""
        dt_ns = int(self.args.pair_dt * 1e9)
        idx_ts = [u['t_ns'] for u in usable]
        cand = []
        for a in range(len(usable)):
            b = DR_nearest(idx_ts, usable[a]['t_ns'] + dt_ns, int(0.25 * dt_ns))
            if b is not None and b > a:
                cand.append((a, b))
        if not cand:
            return []
        # 🔴 2026-09-24 修:depth_ruler.run() 原式 `cand[::step][:pairs]`(step = len//pairs)在
        #    pairs < len(cand) < 2·pairs 时 step=1 ⇒ 只取前 pairs 个候选 ⇒ 录制**后半段整段不测**
        #    (run-fb5d3a8f:79 个候选取前 40 ⇒ 帧对只落在 1.9–13 s,30 s 录制的后 17 s 没进 k、分段 k 也是假的)。
        #    改成在全部候选上等距取 pairs 个(覆盖整段);len(cand) ≤ pairs 时全取,与原式相同。
        if len(cand) <= self.args.pairs:
            sel = cand
        else:
            idx = np.unique(np.round(np.linspace(0, len(cand) - 1, self.args.pairs)).astype(int))
            sel = [cand[i] for i in idx]
        return [(usable[a], usable[b]) for a, b in sel]

    def matches(self, fa, fb):
        pa, da = self.features(fa)
        pb, db = self.features(fb)
        good = DR.match_ratio_test(da, db, self.norm, self.args.ratio)
        if not good:
            return np.zeros((0, 2)), np.zeros((0, 2))
        return (np.float64([pa[m.queryIdx] for m in good]),
                np.float64([pb[m.trainIdx] for m in good]))

    def depth_of(self, fr, offset_rows=0, perm=None):
        """这一帧的深度;offset_rows ≠ 0 ⇒ 时间上相邻的第 n 张深度(对齐曲线);perm ⇒ 洗牌对照。"""
        j = fr['depth_order'] + offset_rows
        if perm is not None:
            j = perm[fr['depth_order']]
        if j < 0 or j >= len(self._didx):
            return None
        return self.reader.read(self.depth_rows[self._didx[j]])


def rel_pose(pa, pb):
    """depth_ruler.relative_pose 的同一式(R_rel = R_b^T R_a,t_rel = R_b^T (C_a − C_b)),
    输入已是 OpenCV 轴的旋转矩阵 + 相机中心。"""
    Ra, Ca = pa
    Rb, Cb = pb
    return Rb.T @ Ra, Rb.T @ (np.asarray(Ca) - np.asarray(Cb))


def pair_measure(scene, fa, fb, pts_a, pts_b, pose_a, pose_b, depth, args):
    """一对帧、一条轨迹:三角化 → 闸 → monodepth2 的中位数之比。depth_ruler.run() 循环体的原样搬运。"""
    rec = {'t_a': fa['t_ns'] / 1e9, 't_b': fb['t_ns'] / 1e9, 'matches': int(len(pts_a))}
    if len(pts_a) < args.min_points:
        rec['skipped'] = 'too_few_matches'
        return rec
    if depth is None:
        rec['skipped'] = 'no_depth'
        return rec
    fa_k, fb_k = fa['K'], fb['K']
    K_a = np.array([[fa_k[0], 0, fa_k[2]], [0, fa_k[1], fa_k[3]], [0, 0, 1.0]])
    K_b = np.array([[fb_k[0], 0, fb_k[2]], [0, fb_k[1], fb_k[3]], [0, 0, 1.0]])
    R_rel, t_rel = rel_pose(pose_a, pose_b)
    baseline = float(np.linalg.norm(t_rel))
    rec['baseline_traj_units'] = baseline
    if baseline < args.min_baseline:
        rec['skipped'] = 'small_baseline'
        return rec
    X, P_a, P_b = DR.triangulate_pair(K_a, K_b, R_rel, t_rel, pts_a, pts_b)
    z_a = X[:, 2]
    X_b = (R_rel @ X.T).T + t_rel
    e_a = np.linalg.norm(DR.reproject(P_a, X) - pts_a, axis=1)
    e_b = np.linalg.norm(DR.reproject(P_b, X) - pts_b, axis=1)
    C_b_in_a = -R_rel.T @ t_rel
    v1, v2 = X, X - C_b_in_a
    with np.errstate(invalid='ignore', divide='ignore'):
        cosang = np.sum(v1 * v2, 1) / (np.linalg.norm(v1, axis=1) * np.linalg.norm(v2, axis=1))
    ang = np.degrees(np.arccos(np.clip(cosang, -1, 1)))
    depth_map, conf_map = depth
    d_lidar, conf, depth_ok = DR.sample_depth(depth_map, conf_map, pts_a, (scene.W, scene.H),
                                              args.min_confidence)
    keep = (np.isfinite(z_a) & (z_a > 0) & (X_b[:, 2] > 0)
            & (e_a < args.max_reproj_px) & (e_b < args.max_reproj_px)
            & (ang > args.min_angle_deg) & depth_ok)
    rec['cheirality_ok'] = int(((z_a > 0) & (X_b[:, 2] > 0)).sum())
    rec['depth_high_conf_ok'] = int(depth_ok.sum())
    rec['valid_points'] = int(keep.sum())
    rec['conf_hist'] = [int((conf[np.isfinite(d_lidar)] == lv).sum()) for lv in (0, 1, 2)]
    if keep.sum() < args.min_points:
        rec['skipped'] = 'too_few_valid_points'
        return rec
    tri, lid = z_a[keep], d_lidar[keep]
    ratio_of_medians = float(np.median(lid) / np.median(tri))        # monodepth2 L207
    pr = lid / tri
    q1, q3 = np.percentile(pr, [25, 75])
    rec.update({
        'scale_to_metric': ratio_of_medians,
        'scale_median_of_ratios': float(np.median(pr)),
        'within_rel_iqr': float((q3 - q1) / np.median(pr)),
        'median_lidar_m': float(np.median(lid)),
        'median_triangulated': float(np.median(tri)),
        'triangulation_angle_deg_median': float(np.median(ang[keep])),
    })
    return rec


# ═════════════════════════════════════════════════════════════════════════════════════════
# 估计 + 闸 + 噪声底
# ═════════════════════════════════════════════════════════════════════════════════════════

def estimate(per_pair, attempted, args):
    ok = [p for p in per_pair if 'scale_to_metric' in p]
    r = np.array([p['scale_to_metric'] for p in ok])
    out = {'pairs_attempted': attempted, 'pairs_with_scale': len(ok)}
    if len(ok) == 0:
        out.update({'k': float('nan'), 'gates': {'G1_pairs': False}, 'passed': False})
        return out
    s = float(np.median(r))                                          # monodepth2 L218
    q1, q3 = np.percentile(r, [25, 75])
    within = float(np.median([p['within_rel_iqr'] for p in ok]))
    between = float((q3 - q1) / s)
    need = max(args.min_pairs, int(np.ceil(0.5 * attempted)))
    gates = {
        'G1_pairs': len(ok) >= need,
        'G2_between_rel_iqr': between <= args.max_between,
        'G3_within_rel_iqr': within <= args.max_within,
    }
    out.update({
        's_traj_to_metric': s,
        'k': 1.0 / s,
        'k_minus_1_pct': (1.0 / s - 1.0) * 100.0,
        'k_median_of_ratios': 1.0 / float(np.median([p['scale_median_of_ratios'] for p in ok])),
        'between_pair_rel_iqr': between,
        'within_pair_rel_iqr_median': within,
        'pairs_needed': need,
        'gates': gates,
        'passed': all(gates.values()),
    })
    return out


def median_ci_nonoverlapping(per_pair, level=0.95):
    """深度侧抽样区间(诊断):只取时间上互不重叠的帧对(近似独立),用中位数的**顺序统计量**区间
    (二项分布,无分布假设;Conover, Practical Nonparametric Statistics, 3rd ed., §3.2)。不是 bootstrap。"""
    import math
    ok = sorted((p for p in per_pair if 'scale_to_metric' in p), key=lambda p: p['t_a'])
    picked, last_end = [], -1e18
    for p in ok:
        if p['t_a'] >= last_end:
            picked.append(p)
            last_end = p['t_b']
    n = len(picked)
    if n < 6:
        return {'n_nonoverlapping': n}
    r = np.sort([p['scale_to_metric'] for p in picked])
    alpha = (1 - level) / 2
    cdf, lo = 0.0, 0
    for j in range(n + 1):
        cdf += math.comb(n, j) / 2 ** n
        if cdf > alpha:
            lo = j
            break
    hi = n - 1 - lo
    return {'n_nonoverlapping': n, 'k_ci': [1.0 / float(r[hi]), 1.0 / float(r[lo])],
            'order_stat_ranks_1based': [int(lo) + 1, int(hi) + 1]}


def noise_floor_traj(measure, depth_true, n_pairs, ref_poses, est_poses, k_ref, args, n=100, seed=7):
    """noise_floor.py 的做法原样,只是「重估 k」走的是本尺子(三角化 vs LiDAR)而不是 Sim3:

      取**真实的** (est 相机中心 vs ref 相机中心) Sim3 残差时间序列(ref 系),循环平移一个随机 lag
      (保留它的频谱与慢漂移,打断它与运动的相关),加到 k0 × ref 路径上(旋转用 ref 的),重跑尺子。
      k0 = 1.00 ⇒ 阴性对照(尺子不许凭空造尺度),给 95% 带;k0 = 1.05 ⇒ 阳性对照,必须恢复。
      比值 k_syn / k_ref 里 LiDAR 那一侧是同一组帧对、同一组深度 ⇒ 约掉,剩下的就是「这种频谱的
      轨迹误差经尺子传到 k 上有多大」。lag 范围、次数的写法照抄 noise_floor.py(它是 300 次;这里每次
      要重做全部帧对的三角化,取 100 次)。
    """
    common = sorted(set(ref_poses) & set(est_poses))
    if len(common) < 30:
        return None
    X = np.array([est_poses[t][1] for t in common]).T
    Y = np.array([ref_poses[t][1] for t in common]).T
    s, Rm, tt, ate = SE['sim3'](X, Y)
    res = Y - (s * Rm @ X + tt)
    Yc = Y - Y.mean(1, keepdims=True)
    rng = np.random.default_rng(seed)
    out = {}
    for k0 in (1.00, 1.05):
        ks = []
        for _ in range(n):
            lag = int(rng.integers(len(common) // 10, len(common) - len(common) // 10))
            Cs = k0 * Yc + np.roll(res, lag, axis=1)
            syn = {t: (ref_poses[t][0], Cs[:, i]) for i, t in enumerate(common)}
            e = estimate(measure(syn, depth_true), n_pairs, args)
            if np.isfinite(e['k']):
                ks.append(e['k'] / k_ref)
        out[k0] = np.array(ks)
    if len(out[1.00]) < 10 or len(out[1.05]) < 10:
        return {'error': 'too_few_valid_resamples'}
    lo, hi = np.percentile(out[1.00], [2.5, 97.5])
    pc = float(out[1.05].mean())
    return {'method': 'noise_floor.py circular shift of the real Sim3 residual, re-estimated through the ruler',
            'sim3_ate_cm': float(ate * 100), 'nc_mean': float(out[1.00].mean()),
            'nc_sd': float(out[1.00].std()), 'nc_band_95': [float(lo), float(hi)],
            'pc_mean': pc, 'pc_sd': float(out[1.05].std()), 'pc_recovered': abs(pc - 1.05) < 0.005,
            'n_shifts': n, 'valid_resamples': [len(out[1.00]), len(out[1.05])]}


def segments(per_pair, nseg=4):
    ok = sorted((p for p in per_pair if 'scale_to_metric' in p), key=lambda p: p['t_a'])
    if len(ok) < 2 * nseg:
        return None
    parts = np.array_split(np.arange(len(ok)), nseg)
    return [1.0 / float(np.median([ok[i]['scale_to_metric'] for i in idx])) for idx in parts]


def derangement(n, seed):
    rng = np.random.default_rng(seed)
    while True:
        p = rng.permutation(n)
        if n < 2 or np.all(p != np.arange(n)):
            return p


def scaled(poses, factor):
    """相机中心绕首帧缩放(阳性对照);旋转不动。"""
    if not poses:
        return poses
    t0 = min(poses)
    C0 = np.asarray(poses[t0][1])
    return {t: (R, C0 + factor * (np.asarray(C) - C0)) for t, (R, C) in poses.items()}


def run_all(scene, trajs, args):
    """trajs: {name: {t_ns: (R_wc_cv, C)}}。所有轨迹用同一组帧对。"""
    usable = [f for f in scene.frames if all(f['t_ns'] in tj for tj in trajs.values())]
    print(f'可用帧(内参 + 同 ARFrame 深度 + 所有轨迹都有位姿):{len(usable)} / 录制帧 {len(scene.ts)}'
          f' / 深度 {len(scene.depth_rows)} 张')
    if len(usable) < 2:
        raise SystemExit('🔴 可用帧 < 2')
    pairs = scene.select_pairs(usable)
    if not pairs:
        raise SystemExit(f'🔴 找不到间隔 ~{args.pair_dt}s 的帧对')
    print(f'帧对 {len(pairs)}(间隔 ~{args.pair_dt}s),特征 {args.detector}×{args.features},匹配中…',
          flush=True)
    matched = [(fa, fb) + scene.matches(fa, fb) for fa, fb in pairs]
    perm = derangement(len(scene._didx), args.seed)
    depth_true = [scene.depth_of(fa) for fa, _, _, _ in matched]
    depth_shuf = [scene.depth_of(fa, perm=perm) for fa, _, _, _ in matched]

    reports = {}
    for name, poses in trajs.items():
        def measure(pz, depths):
            return [pair_measure(scene, fa, fb, pa, pb, pz[fa['t_ns']], pz[fb['t_ns']], d, args)
                    for (fa, fb, pa, pb), d in zip(matched, depths)]
        main = measure(poses, depth_true)
        est = estimate(main, len(matched), args)
        rep = {'name': name, 'estimate': est, 'pairs': main}
        if np.isfinite(est['k']):
            rep['depth_side_median_ci'] = median_ci_nonoverlapping(main)
            rep['segments_k'] = segments(main)
            pc = estimate(measure(scaled(poses, 1.05), depth_true), len(matched), args)
            rep['control_pc_x1_05'] = {'k': pc['k'], 'ratio': pc['k'] / est['k'],
                                       'recovered': abs(pc['k'] / est['k'] - 1.05) <= 0.005,
                                       'passed_gates': pc['passed']}
        nc = estimate(measure(poses, depth_shuf), len(matched), args)
        rep['control_nc_shuffled_depth'] = {
            'k': nc['k'], 'gates': nc.get('gates'), 'passed_gates': nc['passed'],
            'between_pair_rel_iqr': nc.get('between_pair_rel_iqr'),
            'within_pair_rel_iqr_median': nc.get('within_pair_rel_iqr_median'),
            'rejected_as_required': not nc['passed']}
        curve = {}
        for off in (-2, -1, 1, 2):
            dd = [scene.depth_of(fa, offset_rows=off) for fa, _, _, _ in matched]
            e = estimate(measure(poses, dd), len(matched), args)
            curve[str(off)] = e.get('between_pair_rel_iqr')
        curve['0'] = est.get('between_pair_rel_iqr')
        rep['alignment_curve_between_rel_iqr_by_depth_row_offset'] = curve
        finite = {k: v for k, v in curve.items() if v is not None and np.isfinite(v)}
        g4 = bool(finite) and '0' in finite and min(finite, key=finite.get) == '0'
        est.setdefault('gates', {})['G4_alignment_minimum_at_0'] = g4
        est['passed'] = bool(est.get('passed')) and g4
        valid = (est['passed'] and rep['control_nc_shuffled_depth']['rejected_as_required']
                 and rep.get('control_pc_x1_05', {}).get('recovered', False))
        rep['verdict'] = 'valid' if valid else 'invalid'
        rep['_measure'] = measure
        reports[name] = rep
    # 噪声底:需要一条参照(ARKit)提供真实残差频谱 ⇒ 只对非 ARKit 轨迹算。
    if 'arkit' in trajs and np.isfinite(reports['arkit']['estimate']['k']):
        k_ref = reports['arkit']['estimate']['k']
        for name, rep in reports.items():
            if name == 'arkit' or not np.isfinite(rep['estimate']['k']):
                continue
            nf = noise_floor_traj(reports['arkit']['_measure'], depth_true, len(matched),
                                  trajs['arkit'], trajs[name], k_ref, args)
            if nf and 'nc_band_95' in nf:
                k = rep['estimate']['k']
                nf['k_95_noise_floor'] = [k * nf['nc_band_95'][0], k * nf['nc_band_95'][1]]
            rep['noise_floor'] = nf
    for rep in reports.values():
        rep.pop('_measure', None)
    return reports, len(matched)


def main():
    ap = argparse.ArgumentParser(description='🔴 bench-only ruler:LiDAR 深度给轨迹定米制尺度')
    ap.add_argument('--recording', required=True, help='run-* 录制目录或其 ruler_subset/')
    ap.add_argument('--arkit', nargs='?', const='', default=None,
                    help='ARKit 位姿 TUM(省略路径 = 录制里的 arkit_poses.tum)')
    ap.add_argument('--xrslam-camera', action='append', default=[],
                    help='名字=poses_camera_by_recording_frame.csv(手机回放 rec30 起:CAMERA 位姿按录制帧 t_ns '
                         '精确键控;零容差、不插值)。可配同名 --xrslam-ledger 给缺位姿的帧分类')
    ap.add_argument('--xrslam', action='append', default=[], help='名字=poses_body.tum(XRSLAM BODY 位姿)')
    ap.add_argument('--xrslam-ledger', action='append', default=[],
                    help='名字=intrinsics_ledger.csv(手机回放逐帧账,精确反查帧时间)')
    ap.add_argument('--xrslam-yaml', help='回放用的 XRSLAM yaml(取 q_bc / p_bc);缺省 = scale_eval 的设备外参')
    ap.add_argument('--xrslam-td', type=float, default=0.008,
                    help='无账时:位姿时间 = 帧时间 + td(秒)[+ exposure/2]')
    ap.add_argument('--xrslam-exposure-half', action='store_true', help='无账时再加逐帧 exposure_s/2')
    ap.add_argument('--camera', action='append', default=[], help='名字=TUM(已是相机位姿、OpenCV 轴)')
    ap.add_argument('--out')
    ap.add_argument('--detector', choices=['sift', 'orb'], default='sift')
    ap.add_argument('--features', type=int, default=4000)
    ap.add_argument('--ratio', type=float, default=0.8)
    ap.add_argument('--pairs', type=int, default=40)
    ap.add_argument('--pair-dt', type=float, default=0.5)
    ap.add_argument('--depth-tol-ms', type=float, default=0.5,
                    help='深度行 ↔ 相机帧的时间戳容差(同一 ARFrame ⇒ 应精确相等)')
    ap.add_argument('--min-points', type=int, default=20)
    ap.add_argument('--min-pairs', type=int, default=8)
    ap.add_argument('--min-baseline', type=float, default=0.02)
    ap.add_argument('--max-reproj-px', type=float, default=2.0)
    ap.add_argument('--min-angle-deg', type=float, default=1.0)
    ap.add_argument('--min-confidence', type=int, default=DR.CONF_HIGH, choices=[0, 1, 2])
    ap.add_argument('--max-between', type=float, default=0.15)
    ap.add_argument('--max-within', type=float, default=0.25)
    ap.add_argument('--seed', type=int, default=20260924)
    a = ap.parse_args()

    print(NOTICE + '\n')
    scene = Scene(a.recording, a)
    frame_ts = [t for t, _ in scene.ts]
    trajs, provenance = {}, {}
    if a.arkit is not None:
        p = a.arkit or os.path.join(a.recording, 'arkit_poses.tum')
        trajs['arkit'], provenance['arkit'] = arkit_poses(a.recording, p, frame_ts)
        provenance['arkit']['path'] = os.path.abspath(p)
    ledgers = dict(s.split('=', 1) for s in a.xrslam_ledger)
    for spec in a.xrslam_camera:
        name, path = spec.split('=', 1)
        trajs[name], provenance[name] = xrslam_camera_by_frame(path, frame_ts, ledgers.get(name))
        provenance[name]['path'] = os.path.abspath(path)
    if a.xrslam:
        if a.xrslam_yaml:
            R_bc, p_bc = parse_extrinsic_yaml(a.xrslam_yaml)
            ext_src = os.path.abspath(a.xrslam_yaml)
        else:
            R_bc, p_bc, ext_src = R_BC_DEFAULT, P_BC_DEFAULT, 'scale_eval.py P_BC / R_BC(cfg/dev_r6e2d.yaml)'
        expo = {}
        if len([n for n in (s.split('=', 1)[0] for s in a.xrslam) if n not in ledgers]) > 0:
            for ln in open(os.path.join(a.recording, 'intrinsics.jsonl')):
                if ln.strip():
                    d = json.loads(ln)
                    expo[int(round(float(d['t']) * 1e9))] = float(d.get('exposure_s', 0.0))
        for spec in a.xrslam:
            name, path = spec.split('=', 1)
            if name in ledgers:
                poses, st = xrslam_body_poses(path, frame_ts, R_bc, p_bc, ledger=ledgers[name])
            else:
                shift = {}
                ek = sorted(expo)
                for t in frame_ts:
                    e = DR_nearest(ek, t, 1_000_000) if a.xrslam_exposure_half else None
                    if a.xrslam_exposure_half and e is None:
                        raise SystemExit(f'🔴 帧 {t} 配不上 exposure_s(--xrslam-exposure-half 拒绝静默按 0 算)')
                    shift[t] = a.xrslam_td + (expo[ek[e]] / 2 if e is not None else 0.0)
                poses, st = xrslam_body_poses(path, frame_ts, R_bc, p_bc, shift_s=shift)
            st.update({'path': os.path.abspath(path), 'extrinsic_source': ext_src,
                       'td_s': None if name in ledgers else a.xrslam_td,
                       'exposure_half': None if name in ledgers else a.xrslam_exposure_half})
            trajs[name], provenance[name] = poses, st
    for spec in a.camera:
        name, path = spec.split('=', 1)
        trajs[name], provenance[name] = camera_poses_opencv(path, frame_ts)
        provenance[name]['path'] = os.path.abspath(path)
    if not trajs:
        raise SystemExit('🔴 至少给一条轨迹(--arkit / --xrslam-camera / --xrslam / --camera)')
    for n, tj in trajs.items():
        print(f'  轨迹 {n}: {len(tj)} 帧配上  {json.dumps(provenance[n], ensure_ascii=False)}')
        pv = provenance[n]
        if pv.get('mapping', '').startswith('exact_recording_t_ns'):
            extra = ''
            if 'missing_not_admitted_by_xrslam' in pv:
                extra = (f'(XRSLAM 没收 {pv["missing_not_admitted_by_xrslam"]} / '
                         f'收了没在跟踪 {pv["missing_admitted_but_not_tracking"]})')
            print(f'  XRSLAM 精确键控 {n}:子集帧 {pv["recording_frames"]},有引擎位姿 '
                  f'{pv["recording_frames_with_pose"]},缺 {pv["recording_frames_without_pose"]}{extra};不插值')

    reports, n_pairs = run_all(scene, trajs, a)

    # 与规范 Sim3(scale_eval.sim3,相机中心)的交叉核对:k_i / k_j 应 ≈ Sim3 的 k(i 对 j)。
    cross = []
    names = list(trajs)
    for i in range(len(names)):
        for j in range(len(names)):
            if i == j:
                continue
            ni, nj = names[i], names[j]
            common = sorted(set(trajs[ni]) & set(trajs[nj]))
            if len(common) < 30:
                continue
            X = np.array([trajs[ni][t][1] for t in common]).T
            Y = np.array([trajs[nj][t][1] for t in common]).T
            s, _, _, ate = SE['sim3'](X, Y)
            ki, kj = reports[ni]['estimate']['k'], reports[nj]['estimate']['k']
            cross.append({'est': ni, 'ref': nj, 'k_sim3_canonical': 1.0 / s, 'sim3_ate_cm': ate * 100,
                          'k_ratio_from_ruler': ki / kj,
                          'diff_pct': (ki / kj / (1.0 / s) - 1.0) * 100})

    for n, rep in reports.items():
        e = rep['estimate']
        print(f'\n── {n} ── verdict: {rep["verdict"]}')
        if np.isfinite(e['k']):
            print(f'  k(轨迹/米) = {e["k"]:.4f}  ⇒ 轨迹比米制 {e["k_minus_1_pct"]:+.2f}%'
                  f'   有效帧对 {e["pairs_with_scale"]}/{e["pairs_attempted"]}')
            nf = rep.get('noise_floor')
            if nf and 'k_95_noise_floor' in nf:
                print(f'  噪声底 95%(轨迹残差循环平移,经尺子重估): k ∈ [{nf["k_95_noise_floor"][0]:.4f},'
                      f' {nf["k_95_noise_floor"][1]:.4f}]   NC sd {nf["nc_sd"] * 100:.2f}%'
                      f'   PC k0=1.05 恢复 {nf["pc_mean"]:.4f} {"✅" if nf["pc_recovered"] else "🔴"}')
            ci = rep.get('depth_side_median_ci') or {}
            if 'k_ci' in ci:
                print(f'  深度侧 95%(不重叠帧对 {ci["n_nonoverlapping"]} 个,顺序统计量): '
                      f'k ∈ [{ci["k_ci"][0]:.4f}, {ci["k_ci"][1]:.4f}]')
            print(f'  闸 {e["gates"]}  帧对间 IQR/中位 {e["between_pair_rel_iqr"]:.4f}'
                  f'  帧对内 {e["within_pair_rel_iqr_median"]:.4f}')
            print(f'  分段 k {rep.get("segments_k")}')
            pc = rep.get('control_pc_x1_05', {})
            print(f'  PC ×1.05:比值 {pc.get("ratio", float("nan")):.5f} '
                  f'{"✅" if pc.get("recovered") else "🔴"}')
        nc = rep['control_nc_shuffled_depth']
        print(f'  NC 深度洗牌:k={nc["k"]:.4f} 过闸={nc["passed_gates"]} '
              f'{"✅ 被拒(应当)" if nc["rejected_as_required"] else "🔴 没被拒 ⇒ 闸在这份录制上没有牙齿"}')
        print(f'  对齐曲线(深度行偏移 → 帧对间 IQR):{rep["alignment_curve_between_rel_iqr_by_depth_row_offset"]}')
    for c in cross:
        print(f'\n交叉核对 {c["est"]}/{c["ref"]}:尺子比值 {c["k_ratio_from_ruler"]:.4f} vs 规范 Sim3 '
              f'{c["k_sim3_canonical"]:.4f}(差 {c["diff_pct"]:+.2f}%,Sim3 ATE {c["sim3_ate_cm"]:.2f} cm)')

    out = {'schema': 'pw.bench.lidar-ruler/1', 'bench_only_notice': NOTICE,
           'recording': os.path.abspath(a.recording), 'opencv_version': cv2.__version__,
           'depth_resolution': [scene.DW, scene.DH], 'image_resolution': [scene.W, scene.H],
           'k_definition': 'k = trajectory scale / metres (k>1 ⇒ trajectory bigger than the world)',
           'args': vars(a), 'provenance': provenance, 'pairs': n_pairs,
           'trajectories': reports, 'cross_check_vs_canonical_sim3': cross}
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        p = os.path.join(a.out, 'lidar_ruler_report.json')
        json.dump(out, open(p, 'w'), indent=1, ensure_ascii=False, default=float)
        print(f'\n写出 {p}')
    return 0 if all(r['verdict'] == 'valid' for r in reports.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
