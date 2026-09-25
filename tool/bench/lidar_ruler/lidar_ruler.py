#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""🔴 **bench-only ruler v2** —— 用同一份录制里的 LiDAR 深度,给 ARKit / XRSLAM 各自的轨迹定**绝对米制尺度**。

══ 口径(用户 2026-09-22 / 09-24 / 09-25)══════════════════════════════════════════════
LiDAR 只作研发期量尺。永不进产品代码、产品管线、产品提案。用户 09-25:「我只信任深度相机」⇒ 本尺子是台架
**唯一**的米制参照;加计双积分等只作诊断辅助,不作参照。

══ 输出口径 ═══════════════════════════════════════════════════════════════════════════
  k = 轨迹尺度 / 米          k > 1 ⇒ 轨迹比真实世界**大**;带符号报 (k−1)。
  每条结论都带 95% 区间 = 「按时间分块 bootstrap」∪「方法选择范围」(见下「误差模型」)。

══ v2 相对 v1(research @76b8d47 的 depth_ruler 编排 + 09-24 rec30 版)改了什么 —— 09-25 审计七项 + 焦距 ══
  ① 帧对间隔名实相符、不重复计数:--pair-dts 可给多档;每档报**实际**间隔(中位/最小/最大),同一帧对只算一次,
     某档选出的帧对与前一档完全相同时明写「与 X 档相同」。(v1 在 0.3 s 间隔的子集帧上把标称 0.5/0.75 s 都取成 0.6 s,
     汇总脚本当成两组求均值 ⇒ 重复计数。)
  ② 判定同时看噪声底阳性对照:verdict = G1–G4 ∧ 深度洗牌被拒 ∧ ×1.03/×1.05(无噪声)恢复 ∧(非参照轨迹)噪声底 ×1.03/×1.05 恢复。
  ③ 所有轨迹在**同一批帧对、同一批点**上比较:点掩码 = 参照轨迹(ARKit)的几何掩码(重投影 / 三角化角 / 正深度)
     ∧ 其余每条轨迹都正深度 ∧ 深度掩码 ∧ 画面中心掩码(--common-mask intersection 可改成各轨迹几何掩码的交集,
     但 XRSLAM 前端的逐帧旋转抖动会让交集只剩 6–18% 的帧对)。v1 按各自轨迹筛点筛对,ARKit 49 对 vs XRSLAM 55–58 对,headline k 不同基。
     轨迹两两之比在同一批点上逐对直接量(LiDAR 在比值里逐对精确约掉),不经任何常数。
  ④ 畸变:录制里**没有**官方畸变数据(ARKit 的 ARCamera.intrinsics 官方定义就是无畸变针孔、不给畸变系数;录制器没存
     AVCameraCalibrationData.lensDistortionLookupTable,单摄视频流也拿不到它 —— 见 PwVioCapability.swift 文件头)。
     按用户要求不自己拟合 ⇒ 只用画面中心 --max-radius-px(默认 600 px,a、b 两帧都要在圈内)。
     09-25 审计实测:半径 ≥800 px 处 LiDAR/三角化比值系统性低 1–2.5%,只用中心/只用边缘的 k 最多差 2.7 pp。
  ⑤ G4 换判法:v1 的 G4 用「相邻深度行」(±100 ms 步长)只能查粗错位。v2 的 G4 直接**估计深度相对图像的时间偏移 δ**:
     参照轨迹给相机线速度/角速度,预测每个点的深度变化率 ż = −(v + ω×X)_z(X 用 LiDAR 反投影),
     帧对内去均值后 log(d_LiDAR/z_三角化) 对 ż/d 做回归,斜率 = δ(ms 级分辨率),时间分块 bootstrap 给区间;
     闸 = 把深度按 δ 校正后参照轨迹的 k 变化 ≤ --g4-max-dk(默认 0.5%)—— 只关心时间偏移对尺度有没有影响;
     校正后的 k 同时作为一个方法变体计入区间。
     v1 的相邻行曲线保留为诊断(coarse_alignment_curve),不再作闸。
  ⑥ 用全部深度帧:--depth-dir 可让深度来自 ruler_subset/ 而图像来自整份录制(整份 896 帧灰度都在,子集只存了 99 帧灰度,
     却有 296 张深度)⇒ 可用帧 99 → ~290。
  ⑦ 链式换算不再依赖单次运行的常数:报告里直接给每条轨迹对 LiDAR 的 k 与两两同点比值(同一批帧对)。
  ⑧ 焦距敏感度:ARKit 报的焦距是否偏小尚无定论(09-25 诊断:固定 ARKit 相对位姿拟合对极误差 ⇒ 真焦距 ≈ 报的 ×1.015–1.027;
     陀螺版 ×1.006–1.017 且对外参 ±0.68° 敏感 ±1%;纯图像 F 矩阵自标定分辨不了)。尺子把 fx、fy 同乘 α 重三角化,
     报 dk/dα,并把 α ∈ [1, --focal-alpha-hi](默认 1.03)计入方法范围。只用画面中心 + 前后向基线占比越大越不敏感。
  ⑩ G1 改为「有效帧对 ≥ max(--min-pairs, 尝试数 × --g1-frac(0.25))∧ 覆盖 ≥ --g1-coverage(60%)的时间块」:
     v2 只用画面中心、且要各轨迹共同有效的点,每对点数变少 ⇒ v1 的「≥ 50% 帧对」不再合适;真正要防的是只量到一小段,
     所以加时间覆盖率。阴性对照(深度洗牌)照旧要被 G2/G3 拒。
  ⑨ 95% 区间 = 按时间分块 bootstrap(块长 --block-s,默认 3 s;写法同 vendored/scale_eval.block_bootstrap)
     ∪ 方法选择范围(估计器 × 置信度 × 中心半径 × 深度段 × 焦距 α × 深度时间校正,见 method_variants())
     ∪(非参照轨迹)噪声底带 k × [NC 2.5%, NC 97.5%]。

══ 尺子本体:逐字复用 09-22 的 depth_ruler.py(research @ 76b8d47,vendored/ 下原样)════════
  特征 + 匹配   SIFT + BFMatcher.knnMatch + Lowe 比值 0.8(IJCV 2004 §7.1;OpenCV py_matcher 教程)
  三角化       cv2.triangulatePoints(DLT,H&Z §12.2),**位姿不估**:两帧相对位姿取自被测轨迹
  深度取值      depth_ruler.sample_depth():u_d = (u_c+0.5)·W_d/W_c − 0.5 最近邻
  尺度对齐      monodepth2 evaluate_depth.py L207 `ratio = np.median(gt)/np.median(pred)`(逐帧对),
               L218 `med = np.median(ratios)`(跨帧对)
方法地图:exact_upstream = 上面四行 + block bootstrap(scale_eval.block_bootstrap 同写法)+ 噪声底(noise_floor.py 同法);
product_adapter = 编排(多档帧对、共同点掩码、中心掩码、方法范围、G4 时间偏移回归、深度来自子集目录);
not_implemented = 镜头畸变校正(没有官方数据,见 ④)。

══ 已知局限(照实报)═════════════════════════════════════════════════════════════════════
  · LiDAR 自己不是真值:公开逐帧 sceneDepth 实测(high 置信)系统偏差约 −2%…+0.5%(Zea & Hanebeck, JAIF 17(2) 2022
    图 8:1–4 m 恒为负、1–2%;Tondo 等 Sensors 2023 表 1:0.3/0.4/1.0 m 处 −0.3/−0.75/+0.1%)⇒ **LiDAR 的系统偏差原样进 k**,
    本尺子的区间不含它(合成 T9 自证),读结论时要再加这一项。
  · ARKit 在有 LiDAR 的机型上是否用了 LiDAR 做跟踪,Apple 没说 ⇒ ARKit 的 k 与 LiDAR 不一定独立;XRSLAM 不受影响。
  · 深度图 256×192 对 1920×1440 是 7.5× 下采样;sceneDepth 是 LiDAR(约 15 Hz)+RGB 融合上采样到 60 Hz 的稠密图。

vendored/(只读取用的原件拷贝):depth_ruler.py / charuco_scale_arbiter.py / synth_verify.py / synth_depth_verify.py
  ← 研究仓 research/basalt-vio-phone-bench-20260829 @ 76b8d47;scale_eval.py / noise_floor.py ← 09-24 真值审计;ate.py。

用法:
  /usr/bin/python3 lidar_ruler.py --recording <run-…> --depth-dir <run-…>/ruler_subset \
      --arkit --camera 名字=相机位姿TUM(OpenCV 轴,按录制帧 t_ns)… --out <dir>
  老用法(--xrslam-camera / --xrslam + --xrslam-ledger / 子集目录直接当 --recording)照旧可用。
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



import hashlib  # noqa: E402
import itertools  # noqa: E402
import math  # noqa: E402



def so3_log(R):
    """旋转矩阵 → 旋转向量(cv2.Rodrigues 的逆向,OpenCV 原函数)。"""
    v, _ = cv2.Rodrigues(np.asarray(R, dtype=np.float64))
    return v.ravel()


class Scene:
    """录制 + 深度 + 帧对 + 匹配。所有轨迹共用同一组帧对、同一批点。

    v2:深度可来自另一个目录(--depth-dir,整份录制的深度只存在 ruler_subset/ 里);帧对可多档间隔(--pair-dts)。"""

    def __init__(self, recdir, args):
        self.recdir = recdir
        self.args = args
        self.depth_dir = args.depth_dir or recdir
        self.W, self.H, self.ts, self.off_by_frame, self.bpf = load_recording(recdir)
        intr = load_intrinsics(recdir, self.ts)
        self.depth_rows, self.DW, self.DH = DR.load_depth_index(self.depth_dir)
        self.reader = DR.DepthReader(self.depth_dir, self.DW, self.DH)
        dt = sorted((r['t_ns'], i) for i, r in enumerate(self.depth_rows))
        self._dkeys = [t for t, _ in dt]
        self._didx = [i for _, i in dt]
        tol = int(args.depth_tol_ms * 1e6)
        self.frames = []                       # 有内参 + 有深度(同一 ARFrame)+ 有灰度的帧
        for k, (t_ns, fid) in enumerate(self.ts):
            if intr[k] is None or fid not in self.off_by_frame:
                continue
            j = DR_nearest(self._dkeys, t_ns, tol)
            if j is None:
                continue
            self.frames.append({'t_ns': t_ns, 'frame': fid, 'K': intr[k], 'depth_i': self._didx[j],
                                'depth_order': j})
        self.frames_fd = open(os.path.join(recdir, 'frames.bin'), 'rb')
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
        """depth_ruler.run() 的帧对规则(每帧往后找 ~dt ±25% 的那一帧,全部候选上等距取 --pairs 个),逐档做;
        ① 同一帧对只算一次;② 每档报实际间隔;③ 某档没选出任何新帧对 ⇒ 标「与前面某档相同」。"""
        idx_ts = [u['t_ns'] for u in usable]
        out, groups, seen = [], [], {}
        for dt in self.args.pair_dts:
            dt_ns = int(dt * 1e9)
            cand = []
            for a in range(len(usable)):
                b = DR_nearest(idx_ts, usable[a]['t_ns'] + dt_ns, int(0.25 * dt_ns))
                if b is not None and b > a:
                    cand.append((a, b))
            if len(cand) > self.args.pairs:
                idx = np.unique(np.round(np.linspace(0, len(cand) - 1, self.args.pairs)).astype(int))
                cand = [cand[i] for i in idx]
            new, dup = [], {}
            for a, b in cand:
                key = (usable[a]['t_ns'], usable[b]['t_ns'])
                if key in seen:
                    dup[str(seen[key])] = dup.get(str(seen[key]), 0) + 1
                    continue
                seen[key] = dt
                new.append((a, b))
            act = np.array([(usable[b]['t_ns'] - usable[a]['t_ns']) * 1e-9 for a, b in cand])
            g = {'nominal_s': dt, 'selected': len(cand), 'new_pairs': len(new), 'duplicates_of_group': dup,
                 'actual_dt_s': ({'median': float(np.median(act)), 'min': float(act.min()), 'max': float(act.max())}
                                 if len(act) else None),
                 'identical_to_earlier_group': bool(cand) and not new}
            groups.append(g)
            out += [(usable[a], usable[b], dt) for a, b in new]
        return out, groups

    def matches(self, fa, fb):
        pa, da = self.features(fa)
        pb, db = self.features(fb)
        good = DR.match_ratio_test(da, db, self.norm, self.args.ratio)
        if not good:
            return np.zeros((0, 2)), np.zeros((0, 2))
        return (np.float64([pa[m.queryIdx] for m in good]),
                np.float64([pb[m.trainIdx] for m in good]))

    def depth_of(self, fr, offset_rows=0, perm=None):
        """这一帧的深度;offset_rows ≠ 0 ⇒ 时间上相邻的第 n 张深度(粗对齐诊断);perm ⇒ 洗牌对照。"""
        j = fr['depth_order'] + offset_rows
        if perm is not None:
            j = perm[fr['depth_order']]
        if j < 0 or j >= len(self._didx):
            return None
        return self.reader.read(self.depth_rows[self._didx[j]])


def rel_pose(pa, pb):
    """depth_ruler.relative_pose 的同一式(R_rel = R_b^T R_a,t_rel = R_b^T (C_a − C_b))。"""
    Ra, Ca = pa
    Rb, Cb = pb
    return Rb.T @ Ra, Rb.T @ (np.asarray(Ca) - np.asarray(Cb))


def K_of(fr, alpha=1.0):
    fx, fy, cx, cy = fr['K']
    return np.array([[fx * alpha, 0, cx], [0, fy * alpha, cy], [0, 0, 1.0]])


def geometry(P, pose_a, pose_b, args, alpha=1.0):
    """一个帧对、一条轨迹、一个焦距倍率:三角化(DLT)→ 几何掩码。depth_ruler.run() 循环体的几何部分原样搬运。"""
    pa, pb = P['pa'], P['pb']
    n = len(pa)
    R_rel, t_rel = rel_pose(pose_a, pose_b)
    base = float(np.linalg.norm(t_rel))
    if n == 0 or base < args.min_baseline:
        return {'z': np.full(n, np.nan), 'ok': np.zeros(n, bool), 'pos': np.zeros(n, bool), 'baseline': base}
    Ka, Kb = K_of(P['fa'], alpha), K_of(P['fb'], alpha)
    with np.errstate(invalid='ignore', divide='ignore'):
        X, P_a, P_b = DR.triangulate_pair(Ka, Kb, R_rel, t_rel, pa, pb)
        z = X[:, 2]
        X_b = (R_rel @ X.T).T + t_rel
        e_a = np.linalg.norm(DR.reproject(P_a, X) - pa, axis=1)
        e_b = np.linalg.norm(DR.reproject(P_b, X) - pb, axis=1)
        C_b_in_a = -R_rel.T @ t_rel
        v1, v2 = X, X - C_b_in_a
        cosang = np.sum(v1 * v2, 1) / (np.linalg.norm(v1, axis=1) * np.linalg.norm(v2, axis=1))
        ang = np.degrees(np.arccos(np.clip(cosang, -1, 1)))
        ok = (np.isfinite(z) & (z > 0) & (X_b[:, 2] > 0) & (e_a < args.max_reproj_px)
              & (e_b < args.max_reproj_px) & (ang > args.min_angle_deg))
        pos = np.isfinite(z) & (z > 0) & (X_b[:, 2] > 0)
    return {'z': z, 'ok': ok, 'pos': pos, 'baseline': base, 'tz_frac': abs(float(t_rel[2])) / base}


def geometry_all(pairs, poses, args, alpha=1.0):
    return [geometry(P, poses[P['fa']['t_ns']], poses[P['fb']['t_ns']], args, alpha) for P in pairs]


# ═════════════════════════════════════════════════════════════════════════════════════════
# 测量:所有轨迹同一批点(几何掩码交集 ∧ 深度掩码 ∧ 画面中心)
# ═════════════════════════════════════════════════════════════════════════════════════════

BASE_VARIANT = None   # main() 里按参数填
ATTEMPTED_T = None    # 全部尝试帧对的 t_a(秒),G1 的时间覆盖率用
REF_NAME = None       # 参照轨迹名(ARKit 优先)


def measure(pairs, geo, var, args, depth_key='d', mask_ref=None):
    """geo: {轨迹名: [每帧对的 geometry()]}。返回逐帧对记录(每条轨迹一个 s = LiDAR/三角化 的中位数之比)。
    点掩码(所有轨迹同一批点):--common-mask reference(默认)= 参照轨迹的几何掩码(重投影 / 三角化角 / 正深度)
    ∧ 其余每条轨迹都正深度;intersection = 每条轨迹几何掩码的交集(对有旋转误差的轨迹太苛刻:XRSLAM 前端逐帧
    0.14–0.33° 抖动让重投影 > 2 px,三场只剩 36–102 / 564 对,09-25 实测)。"""
    mask_ref = mask_ref or REF_NAME
    names = list(geo)
    recs = []
    for i, P in enumerate(pairs):
        d = P.get(depth_key)
        if d is None:
            continue
        conf = P['conf_shuf'] if depth_key == 'd_shuf' else P['conf']
        m = np.isfinite(d) & (d > 0) & (conf >= var['conf'])
        if var['radius'] > 0:
            m &= (P['ra'] < var['radius']) & (P['rb'] < var['radius'])
        if var['band'] is not None:
            m &= (d >= var['band'][0]) & (d < var['band'][1])
        for n in names:
            m &= geo[n][i]['ok'] if (args.common_mask == 'intersection' or n == mask_ref) else geo[n][i]['pos']
        if m.sum() < args.min_points:
            continue
        dd = d[m]
        rec = {'i': i, 't_a': P['fa']['t_ns'] * 1e-9, 't_b': P['fb']['t_ns'] * 1e-9, 'n_pts': int(m.sum()),
               's': {}, 'within': {}}
        for n in names:
            zz = geo[n][i]['z'][m]
            pr = dd / zz
            rec['s'][n] = float(np.median(dd) / np.median(zz)) if var['est'] == 'rom' else float(np.median(pr))
            q1, q3 = np.percentile(pr, [25, 75])
            rec['within'][n] = float((q3 - q1) / np.median(pr))
        recs.append(rec)
    return recs


def estimate(recs, name, attempted, args):
    r = np.array([x['s'][name] for x in recs]) if recs else np.zeros(0)
    out = {'pairs_attempted': attempted, 'pairs_with_scale': int(len(r))}
    if len(r) == 0:
        out.update({'k': float('nan'), 'gates': {'G1_pairs': False}, 'passed': False})
        return out
    s = float(np.median(r))                                          # monodepth2 L218
    q1, q3 = np.percentile(r, [25, 75])
    within = float(np.median([x['within'][name] for x in recs]))
    between = float((q3 - q1) / s)
    need = max(args.min_pairs, int(np.ceil(args.g1_frac * attempted)))
    cov = float('nan')
    if ATTEMPTED_T is not None and len(ATTEMPTED_T):
        eb = eff_block(ATTEMPTED_T, args.block_s)
        t0 = ATTEMPTED_T.min()
        all_b = set(np.floor((ATTEMPTED_T - t0) / eb).astype(int).tolist())
        got_b = set(np.floor((np.array([x['t_a'] for x in recs]) - t0) / eb).astype(int).tolist())
        cov = len(got_b & all_b) / len(all_b)
    gates = {'G1_pairs': len(r) >= need and not (cov < args.g1_coverage),
             'G2_between_rel_iqr': between <= args.max_between,
             'G3_within_rel_iqr': within <= args.max_within}
    out['time_block_coverage'] = cov
    out.update({'s_traj_to_metric': s, 'k': 1.0 / s, 'k_minus_1_pct': (1.0 / s - 1.0) * 100.0,
                'between_pair_rel_iqr': between, 'within_pair_rel_iqr_median': within, 'pairs_needed': need,
                'gates': gates, 'passed': all(gates.values())})
    return out


def eff_block(t, block_s):
    """块长:默认 block_s;录制太短(不足 8 块)时缩成 跨度/8,保证有得抽。"""
    span = float(np.max(t) - np.min(t)) if len(t) else 0.0
    return max(min(block_s, span / 8.0), 1e-3)


def block_groups(recs, block_s):
    """scale_eval.block_bootstrap 同写法:按时间切成 block_s 秒的块,块整体有放回重抽。"""
    t = np.array([x['t_a'] for x in recs])
    blk = np.floor((t - t.min()) / eff_block(t, block_s)).astype(int)
    return [np.nonzero(blk == b)[0] for b in np.unique(blk)]


def boot_ci(values, groups, n_boot, seed, fn=np.median):
    """values: 每帧对一个数;返回 fn 的 95% 区间(块 bootstrap)。"""
    if len(values) == 0 or len(groups) < 2:
        return [float('nan'), float('nan')], float('nan')
    rng = np.random.default_rng(seed)
    out = []
    for _ in range(n_boot):
        pick = rng.integers(0, len(groups), len(groups))
        out.append(fn(values[np.concatenate([groups[p] for p in pick])]))
    out = np.array(out)
    return [float(np.percentile(out, 2.5)), float(np.percentile(out, 97.5))], float(out.std())


def k_ci(recs, name, args, seed=1):
    """k = 1/median(s) 的块 bootstrap 95% 区间。"""
    if not recs:
        return [float('nan'), float('nan')], float('nan')
    v = np.array([x['s'][name] for x in recs])
    (lo, hi), sd = boot_ci(v, block_groups(recs, args.block_s), args.n_boot, seed)
    return [1.0 / hi, 1.0 / lo], sd / np.median(v)


def ratio_ci(recs, a, b, args, seed=2):
    """同一批点上 k_a / k_b = 逐帧对 s_b / s_a 的中位数(LiDAR 在比值里逐对精确约掉)。"""
    if not recs:
        return float('nan'), [float('nan'), float('nan')]
    v = np.array([x['s'][b] / x['s'][a] for x in recs])
    ci, _ = boot_ci(v, block_groups(recs, args.block_s), args.n_boot, seed)
    return float(np.median(v)), ci


def segments(recs, name, nseg=4):
    ok = sorted(recs, key=lambda p: p['t_a'])
    if len(ok) < 2 * nseg:
        return None
    parts = np.array_split(np.arange(len(ok)), nseg)
    return [1.0 / float(np.median([ok[i]['s'][name] for i in idx])) for idx in parts]


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


# ═════════════════════════════════════════════════════════════════════════════════════════
# G4 v2:深度相对图像的时间偏移 δ(毫秒级)
# ═════════════════════════════════════════════════════════════════════════════════════════

def motion_at(poses, t_ns, keys=None, max_gap_ns=150_000_000):
    """参照轨迹在 t 处的相机系线速度 v_c(轨迹单位/秒)与角速度 ω_c(rad/s):取 t 前后最近的位姿中心差分。"""
    keys = keys if keys is not None else sorted(poses)
    i = bisect.bisect_left(keys, t_ns)
    lo_i = i - 1
    hi_i = i + 1 if (i < len(keys) and keys[i] == t_ns) else i
    if lo_i < 0 or hi_i >= len(keys):
        return None
    lo, hi = keys[lo_i], keys[hi_i]
    if t_ns - lo > max_gap_ns or hi - t_ns > max_gap_ns:
        return None
    (R0, C0), (R1, C1) = poses[lo], poses[hi]
    dt = (hi - lo) * 1e-9
    R = poses[t_ns][0] if t_ns in poses else R0
    v_c = R.T @ ((np.asarray(C1) - np.asarray(C0)) / dt)
    w_c = so3_log(R0.T @ R1) / dt
    return v_c, w_c


def zdot_for_pair(P, ref_poses, keys=None):
    """深度图在**固定像素**上的时间变化率 ∂z/∂t(欧拉式):深度若取自 t+δ,则 d(u) ≈ z(u,t) + ∂z/∂t·δ。
    ∂z/∂t = Ż − ∇z·u̇:Ż = −(v_c + ω_c×X)_z 是同一个空间点的深度变化,u̇ 是它的像点运动(针孔运动场),
    ∇z 取自这张深度图本身(中心差分,换到图像像素)。X = d·K⁻¹[u,v,1](LiDAR 反投影)。"""
    mo = motion_at(ref_poses, P['fa']['t_ns'], keys)
    if mo is None or P.get('d') is None:
        return None
    v_c, w_c = mo
    fx, fy, cx, cy = P['fa']['K']
    d = P['d']
    X = np.stack([(P['pa'][:, 0] - cx) / fx * d, (P['pa'][:, 1] - cy) / fy * d, d], 1)
    Xd = -v_c[None, :] - np.cross(w_c[None, :], X)
    with np.errstate(invalid='ignore', divide='ignore'):
        ud = fx * (Xd[:, 0] * X[:, 2] - X[:, 0] * Xd[:, 2]) / X[:, 2] ** 2
        vd = fy * (Xd[:, 1] * X[:, 2] - X[:, 1] * Xd[:, 2]) / X[:, 2] ** 2
    return Xd[:, 2] - (P['gx'] * ud + P['gy'] * vd)


def depth_grad(dm, pa, W, H):
    """深度图在匹配点处的梯度(米/图像像素,中心差分)与 3×3 相对极差(边缘判据)。"""
    dm = dm.astype(np.float64)
    H_d, W_d = dm.shape
    u = (pa[:, 0] + 0.5) * W_d / W - 0.5
    v = (pa[:, 1] + 0.5) * H_d / H - 0.5
    iu = np.clip(np.rint(u).astype(int), 1, W_d - 2)
    iv = np.clip(np.rint(v).astype(int), 1, H_d - 2)
    gx = (dm[iv, iu + 1] - dm[iv, iu - 1]) / 2 * W_d / W
    gy = (dm[iv + 1, iu] - dm[iv - 1, iu]) / 2 * H_d / H
    nb = np.stack([dm[iv + a, iu + b] for a in (-1, 0, 1) for b in (-1, 0, 1)], 1)
    with np.errstate(invalid='ignore', divide='ignore'):
        rng = (nb.max(1) - nb.min(1)) / dm[iv, iu]
    return gx, gy, rng


def g4_time_offset(pairs, geo_ref, ref, args):
    """回归 log(d/z_ref)(帧对内去中位数)对 ż/d(帧对内去中位数)⇒ 斜率 δ(秒)。深度若取自 t+δ:d ≈ z + ż·δ。"""
    xs, ys, ts = [], [], []
    for i, P in enumerate(pairs):
        zd = P.get('zdot')
        if zd is None:
            continue
        d = P['d']
        m = (np.isfinite(d) & (d > 0) & (P['conf'] >= BASE_VARIANT['conf']) & geo_ref[i]['ok']
             & np.isfinite(zd) & (P['rng3'] < 0.05))
        if BASE_VARIANT['radius'] > 0:
            m &= (P['ra'] < BASE_VARIANT['radius']) & (P['rb'] < BASE_VARIANT['radius'])
        if m.sum() < args.min_points:
            continue
        y = np.log(d[m]) - np.log(geo_ref[i]['z'][m])
        x = zd[m] / d[m]
        y = y - np.median(y)
        x = x - np.median(x)
        mad = 1.4826 * np.median(np.abs(y)) + 1e-12
        keep = np.abs(y) <= 4 * mad
        xs.append(x[keep]); ys.append(y[keep]); ts.append(np.full(keep.sum(), P['fa']['t_ns'] * 1e-9))
    if not xs:
        return {'evaluable': False, 'reason': '参照轨迹在深度帧前后没有位姿(无法求速度)'}
    x, y, t = np.concatenate(xs), np.concatenate(ys), np.concatenate(ts)
    slope = float(np.sum(x * y) / np.sum(x * x))
    blk = np.floor((t - t.min()) / eff_block(t, args.block_s)).astype(int)
    groups = [np.nonzero(blk == b)[0] for b in np.unique(blk)]
    rng = np.random.default_rng(11)
    bs = []
    for _ in range(args.n_boot):
        idx = np.concatenate([groups[p] for p in rng.integers(0, len(groups), len(groups))])
        bs.append(np.sum(x[idx] * y[idx]) / np.sum(x[idx] * x[idx]))
    lo, hi = np.percentile(bs, [2.5, 97.5])
    return {'evaluable': True, 'reference': ref, 'delta_ms': slope * 1e3, 'delta_ci95_ms': [lo * 1e3, hi * 1e3],
            'n_points': int(len(x)), 'method': 'OLS of within-pair-centred log(d_LiDAR/z_tri) on (dz/dt at fixed pixel)/d; '
            'dz/dt = -(v_c + w_c x X)_z - grad(z)·flow, motion from the reference trajectory, grad from the depth map, '
            'smooth points only (3x3 rel. range < 5%); time-block bootstrap'}


# ═════════════════════════════════════════════════════════════════════════════════════════
# 噪声底(noise_floor.py 原法;v2:k0 ∈ {1.00, 1.03, 1.05},比值在同一批点上与参照逐对相除)
# ═════════════════════════════════════════════════════════════════════════════════════════

def noise_floor_traj(pairs, geo_ref, ref_poses, est_poses, args, seed=7):
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
    for k0 in (1.00, 1.03, 1.05):
        ks = []
        for _ in range(args.noise_floor_n):
            lag = int(rng.integers(len(common) // 10, len(common) - len(common) // 10))
            Cs = k0 * Yc + np.roll(res, lag, axis=1)
            syn = {t: (ref_poses[t][0], Cs[:, i]) for i, t in enumerate(common)}
            if not all(P['fa']['t_ns'] in syn and P['fb']['t_ns'] in syn for P in pairs):
                continue
            recs = measure(pairs, {'ref': geo_ref, 'syn': geometry_all(pairs, syn, args)}, BASE_VARIANT, args,
                           mask_ref='ref')
            if recs:
                ks.append(float(np.median([x['s']['ref'] / x['s']['syn'] for x in recs])))  # = k_syn / k_ref
        out[k0] = np.array(ks)
    if min(len(v) for v in out.values()) < 10:
        return {'error': 'too_few_valid_resamples'}
    nc = out[1.00]
    lo, hi = np.percentile(nc, [2.5, 97.5])
    ncm = float(nc.mean())
    rec = {}
    for k0 in (1.03, 1.05):
        m = float(out[k0].mean())
        rec[k0] = {'mean': m, 'sd': float(out[k0].std()), 'linear_recovered': abs(m / k0 - ncm) <= 0.005}
    return {'method': 'noise_floor.py circular shift of the real Sim3 residual, re-estimated through the ruler '
                      '(same points as the reference, per-pair ratio)',
            'sim3_ate_cm': float(ate * 100), 'nc_mean': ncm, 'nc_sd': float(nc.std()),
            'nc_band_95': [float(lo), float(hi)], 'pc_x1_03': rec[1.03], 'pc_x1_05': rec[1.05],
            'pc_mean': rec[1.05]['mean'], 'pc_recovered': rec[1.03]['linear_recovered'] and rec[1.05]['linear_recovered'],
            'recovery_rule': '|mean(k_syn/k_ref)/k0 − NC mean| ≤ 0.5%(线性);NC 均值偏离 1 的部分计入区间,不隐藏',
            'n_shifts': args.noise_floor_n, 'valid_resamples': [len(out[k]) for k in (1.00, 1.03, 1.05)]}


# ═════════════════════════════════════════════════════════════════════════════════════════
# 方法选择范围
# ═════════════════════════════════════════════════════════════════════════════════════════

def method_variants(args):
    radii = [args.max_radius_px] if args.max_radius_px <= 0 else sorted(
        {max(200, args.max_radius_px - 100), args.max_radius_px, args.max_radius_px + 100})
    confs = sorted({args.min_confidence, max(0, args.min_confidence - 1)}, reverse=True)
    out = []
    for est, conf, rad, band, alpha, timing in itertools.product(
            ('rom', 'mor'), confs, radii, (None, (0.5, 1.5)), (1.0, args.focal_alpha_hi), ('raw', 'g4')):
        out.append({'est': est, 'conf': conf, 'radius': rad, 'band': band, 'alpha': alpha, 'timing': timing})
    return out


def variant_id(v):
    return '%s/conf>=%d/r<%s/%s/alpha=%.3f/%s' % (v['est'], v['conf'], v['radius'] or 'off',
                                                    'all' if v['band'] is None else '%.1f-%.1fm' % v['band'],
                                                    v['alpha'], v['timing'])


def run_all(scene, trajs, args):
    """trajs: {name: {t_ns: (R_wc_cv, C)}}。所有轨迹用同一组帧对、同一批点。"""
    global BASE_VARIANT, ATTEMPTED_T, REF_NAME
    BASE_VARIANT = {'est': 'rom', 'conf': args.min_confidence, 'radius': args.max_radius_px, 'band': None,
                    'alpha': 1.0, 'timing': 'raw'}
    usable = [f for f in scene.frames if all(f['t_ns'] in tj for tj in trajs.values())]
    print(f'可用帧(内参 + 同 ARFrame 深度 + 灰度 + 所有轨迹都有位姿):{len(usable)} / 录制帧 {len(scene.ts)}'
          f' / 深度 {len(scene.depth_rows)} 张')
    if len(usable) < 2:
        raise SystemExit('🔴 可用帧 < 2')
    sel, groups = scene.select_pairs(usable)
    if not sel:
        raise SystemExit(f'🔴 找不到间隔 ~{args.pair_dts}s 的帧对')
    for g in groups:
        a = g['actual_dt_s']
        print(f'  帧对档 标称 {g["nominal_s"]}s:选 {g["selected"]},新 {g["new_pairs"]}'
              + (f',实际间隔 中位 {a["median"]:.3f}s [{a["min"]:.3f}, {a["max"]:.3f}]' if a else '')
              + (' 🔴 与前面某档完全相同(不重复计数)' if g['identical_to_earlier_group'] else ''))
    print(f'帧对 {len(sel)}(去重后),特征 {args.detector}×{args.features},匹配中…', flush=True)
    perm = derangement(len(scene._didx), args.seed)
    pairs = []
    for fa, fb, dt in sel:
        pa, pb = scene.matches(fa, fb)
        dep = scene.depth_of(fa)
        shf = scene.depth_of(fa, perm=perm)
        P = {'fa': fa, 'fb': fb, 'nominal_dt': dt, 'pa': pa, 'pb': pb}
        P['ra'] = np.hypot(pa[:, 0] - fa['K'][2], pa[:, 1] - fa['K'][3]) if len(pa) else np.zeros(0)
        P['rb'] = np.hypot(pb[:, 0] - fb['K'][2], pb[:, 1] - fb['K'][3]) if len(pb) else np.zeros(0)
        for key, dm in (('', dep), ('_shuf', shf)):
            if dm is None or len(pa) == 0:
                P['d' + key], P['conf' + key] = None, None
                continue
            d, c, _ = DR.sample_depth(dm[0], dm[1], pa, (scene.W, scene.H), 0)
            P['d' + key], P['conf' + key] = d, c
        if dep is not None and len(pa):
            P['gx'], P['gy'], P['rng3'] = depth_grad(dep[0], pa, scene.W, scene.H)
        pairs.append(P)
    attempted = len(pairs)
    ATTEMPTED_T = np.array([P['fa']['t_ns'] * 1e-9 for P in pairs])
    pair_hash = hashlib.sha256(json.dumps(sorted((P['fa']['t_ns'], P['fb']['t_ns']) for P in pairs)).encode()).hexdigest()
    names = list(trajs)
    ref = 'arkit' if 'arkit' in trajs else names[0]
    REF_NAME = ref

    geo = {1.0: {n: geometry_all(pairs, trajs[n], args, 1.0) for n in names}}
    if args.focal_alpha_hi != 1.0:
        geo[args.focal_alpha_hi] = {n: geometry_all(pairs, trajs[n], args, args.focal_alpha_hi) for n in names}

    # G4 v2
    rkeys = sorted(trajs[ref])
    for P in pairs:
        P['zdot'] = zdot_for_pair(P, trajs[ref], rkeys) if P.get('d') is not None else None
    g4 = g4_time_offset(pairs, geo[1.0][ref], ref, args)
    if g4.get('evaluable'):
        dl = g4['delta_ms'] * 1e-3
        for P in pairs:
            P['d_g4'] = (P['d'] - P['zdot'] * dl) if (P['d'] is not None and P['zdot'] is not None) else None

    base = measure(pairs, geo[1.0], BASE_VARIANT, args)
    reports = {}
    for n in names:
        est = estimate(base, n, attempted, args)
        ci, rsd = k_ci(base, n, args)
        reports[n] = {'name': n, 'estimate': est, 'ci95_block_bootstrap': ci, 'block_bootstrap_rel_sd': rsd,
                      'segments_k': segments(base, n) if base else None,
                      'pairs': [{'t_a': x['t_a'], 't_b': x['t_b'], 'n_pts': x['n_pts'], 'scale_to_metric': x['s'][n],
                                 'within_rel_iqr': x['within'][n]} for x in base]}
    # G4 闸:按 δ 校正深度后参照轨迹的 k 变化
    if g4.get('evaluable'):
        corr = measure(pairs, geo[1.0], BASE_VARIANT, args, depth_key='d_g4')
        kc = {n: estimate(corr, n, attempted, args)['k'] for n in names}
        g4['k_after_correction'] = kc
        g4['dk_ref_pct'] = (kc[ref] / reports[ref]['estimate']['k'] - 1) * 100
        g4['passed'] = abs(g4['dk_ref_pct']) <= args.g4_max_dk * 100
    else:
        g4['passed'] = False
    # 粗对齐曲线(v1 G4,只作诊断):相邻深度行 ±1/±2(±100/200 ms)
    coarse = {}
    for off in (-2, -1, 0, 1, 2):
        pp = []
        for P in pairs:
            dm = scene.depth_of(P['fa'], offset_rows=off)
            if dm is None or len(P['pa']) == 0:
                pp.append(dict(P, d=None))
                continue
            d, c, _ = DR.sample_depth(dm[0], dm[1], P['pa'], (scene.W, scene.H), 0)
            pp.append(dict(P, d=d, conf=c))
        e = estimate(measure(pp, {ref: geo[1.0][ref]}, BASE_VARIANT, args), ref, attempted, args)
        coarse[str(off)] = e.get('between_pair_rel_iqr')

    # 对照
    nc_recs = measure(pairs, geo[1.0], BASE_VARIANT, args, depth_key='d_shuf')
    for n in names:
        rep = reports[n]
        est = rep['estimate']
        est['gates']['G4_depth_time_offset'] = bool(g4['passed'])
        est['passed'] = bool(est.get('passed')) and bool(g4['passed'])
        nc = estimate(nc_recs, n, attempted, args)
        rep['control_nc_shuffled_depth'] = {
            'k': nc['k'], 'gates': nc.get('gates'), 'passed_gates': nc['passed'],
            'between_pair_rel_iqr': nc.get('between_pair_rel_iqr'),
            'within_pair_rel_iqr_median': nc.get('within_pair_rel_iqr_median'),
            'rejected_as_required': not nc['passed']}
        if np.isfinite(est['k']):
            for f in (1.03, 1.05):
                g2 = dict(geo[1.0])
                g2[n] = geometry_all(pairs, scaled(trajs[n], f), args)
                pc = estimate(measure(pairs, g2, BASE_VARIANT, args), n, attempted, args)
                rep['control_pc_x%s' % str(f).replace('.', '_')] = {
                    'k': pc['k'], 'ratio': pc['k'] / est['k'], 'recovered': abs(pc['k'] / est['k'] - f) <= 0.005 * f,
                    'passed_gates': pc['passed']}
    # 噪声底(非参照轨迹)
    for n in names:
        if n == ref or not np.isfinite(reports[n]['estimate']['k']):
            continue
        nf = noise_floor_traj(pairs, geo[1.0][ref], trajs[ref], trajs[n], args)
        if nf and 'nc_band_95' in nf:
            k = reports[n]['estimate']['k']
            nf['k_95_noise_floor'] = [k * nf['nc_band_95'][0], k * nf['nc_band_95'][1]]
        reports[n]['noise_floor'] = nf
    # 方法范围
    variants = method_variants(args)
    vres = []
    for v in variants:
        if v['alpha'] not in geo or (v['timing'] == 'g4' and not g4.get('evaluable')):
            continue
        recs = measure(pairs, geo[v['alpha']], v, args, depth_key='d_g4' if v['timing'] == 'g4' else 'd')
        row = {'variant': variant_id(v), 'pairs': len(recs), 'k': {}, 'ci': {}}
        for n in names:
            if len(recs) < args.min_pairs:
                continue
            row['k'][n] = 1.0 / float(np.median([x['s'][n] for x in recs]))
            row['ci'][n], _ = k_ci(recs, n, args, seed=3)
        row['ratios'] = {}
        for a_, b_ in itertools.permutations(names, 2):
            if len(recs) >= args.min_pairs:
                row['ratios'][f'{a_}/{b_}'] = ratio_ci(recs, a_, b_, args, seed=4)
        vres.append(row)
    for n in names:
        rep = reports[n]
        ks = [r['k'][n] for r in vres if n in r['k']]
        los = [r['ci'][n][0] for r in vres if n in r['ci']]
        his = [r['ci'][n][1] for r in vres if n in r['ci']]
        rep['method_range'] = {'k_min': min(ks), 'k_max': max(ks), 'n_variants': len(ks)} if ks else None
        tot = [min(los + rep['ci95_block_bootstrap'][:1]), max(his + rep['ci95_block_bootstrap'][1:])] if ks else \
            list(rep['ci95_block_bootstrap'])
        nf = rep.get('noise_floor') or {}
        if 'k_95_noise_floor' in nf:
            tot = [min(tot[0], nf['k_95_noise_floor'][0]), max(tot[1], nf['k_95_noise_floor'][1])]
        rep['ci95_total'] = tot
        rep['ci95_total_minus_1_pct'] = [(tot[0] - 1) * 100, (tot[1] - 1) * 100]
        if args.focal_alpha_hi != 1.0:
            fr = measure(pairs, geo[args.focal_alpha_hi], dict(BASE_VARIANT, alpha=args.focal_alpha_hi), args)
            ids = {x['i'] for x in fr} & {x['i'] for x in base}
            if ids:
                kb = 1.0 / np.median([x['s'][n] for x in base if x['i'] in ids])
                kf = 1.0 / np.median([x['s'][n] for x in fr if x['i'] in ids])
                rep['focal_sensitivity'] = {'alpha_hi': args.focal_alpha_hi, 'k_at_alpha_hi_over_k': kf / kb,
                                            'dk_over_dalpha': (kf / kb - 1) / (args.focal_alpha_hi - 1),
                                            'same_pairs': len(ids)}
        pc_ok = all(rep.get('control_pc_x1_%s' % s, {}).get('recovered', False) for s in ('03', '05'))
        nf_ok = True if n == ref else bool((rep.get('noise_floor') or {}).get('pc_recovered'))
        valid = (rep['estimate']['passed'] and rep['control_nc_shuffled_depth']['rejected_as_required']
                 and pc_ok and nf_ok)
        rep['verdict'] = 'valid' if valid else 'invalid'
        rep['verdict_parts'] = {'gates_G1_G4': rep['estimate']['passed'],
                                'nc_rejected': rep['control_nc_shuffled_depth']['rejected_as_required'],
                                'pc_x1_03_x1_05': pc_ok, 'noise_floor_pc': nf_ok}
    # 两两同点比值
    ratios = []
    for a_, b_ in itertools.permutations(names, 2):
        r0, ci0 = ratio_ci(base, a_, b_, args)
        rr = [r['ratios'][f'{a_}/{b_}'] for r in vres if f'{a_}/{b_}' in r['ratios']]
        tot = [min([ci0[0]] + [x[1][0] for x in rr]), max([ci0[1]] + [x[1][1] for x in rr])]
        ratios.append({'a': a_, 'b': b_, 'k_a_over_k_b': r0, 'ci95_block_bootstrap': ci0,
                       'method_range': [min(x[0] for x in rr), max(x[0] for x in rr)] if rr else None,
                       'ci95_total': tot, 'pairs': len(base)})
    return reports, {'pairs_attempted': attempted, 'pair_groups': groups, 'pair_set_sha256': pair_hash,
                     'reference': ref, 'g4_depth_time_offset': g4, 'coarse_alignment_curve_between_rel_iqr': coarse,
                     'same_point_ratios': ratios, 'method_variants': vres,
                     'base_variant': variant_id(BASE_VARIANT)}


def main():
    ap = argparse.ArgumentParser(description='🔴 bench-only ruler v2:LiDAR 深度给轨迹定米制尺度')
    ap.add_argument('--recording', required=True, help='run-* 录制目录(或其 ruler_subset/)')
    ap.add_argument('--depth-dir', help='深度(depth.pwvi/.bin/_conf.bin)所在目录;缺省 = --recording。'
                                        '整份录制的深度只存在 ruler_subset/ 里 ⇒ 用整份灰度 + 子集深度时给 <run>/ruler_subset')
    ap.add_argument('--arkit', nargs='?', const='', default=None,
                    help='ARKit 位姿 TUM(省略路径 = 录制里的 arkit_poses.tum)')
    ap.add_argument('--xrslam-camera', action='append', default=[],
                    help='名字=poses_camera_by_recording_frame.csv(手机回放 rec30 起;零容差、不插值)')
    ap.add_argument('--xrslam', action='append', default=[], help='名字=poses_body.tum(XRSLAM BODY 位姿)')
    ap.add_argument('--xrslam-ledger', action='append', default=[], help='名字=intrinsics_ledger.csv')
    ap.add_argument('--xrslam-yaml', help='回放用的 XRSLAM yaml(取 q_bc / p_bc)')
    ap.add_argument('--xrslam-td', type=float, default=0.008)
    ap.add_argument('--xrslam-exposure-half', action='store_true')
    ap.add_argument('--camera', action='append', default=[], help='名字=TUM(已是相机位姿、OpenCV 轴,按录制帧 t_ns)')
    ap.add_argument('--out')
    ap.add_argument('--detector', choices=['sift', 'orb'], default='sift')
    ap.add_argument('--features', type=int, default=4000)
    ap.add_argument('--ratio', type=float, default=0.8)
    ap.add_argument('--pairs', type=int, default=300, help='每档帧对上限(全部候选上等距取)')
    ap.add_argument('--pair-dts', default='0.3,0.6', help='帧对间隔档(秒,逗号分隔);每档报实际间隔,同帧对只算一次')
    ap.add_argument('--pair-dt', type=float, help='(兼容 v1)只用这一档')
    ap.add_argument('--depth-tol-ms', type=float, default=0.5)
    ap.add_argument('--min-points', type=int, default=20)
    ap.add_argument('--min-pairs', type=int, default=8)
    ap.add_argument('--min-baseline', type=float, default=0.02)
    ap.add_argument('--max-reproj-px', type=float, default=2.0)
    ap.add_argument('--min-angle-deg', type=float, default=1.0)
    ap.add_argument('--min-confidence', type=int, default=DR.CONF_HIGH, choices=[0, 1, 2])
    ap.add_argument('--max-radius-px', type=float, default=600.0,
                    help='只用离主点这么近的点(a、b 两帧都要);0 = 不限。录制里没有官方畸变数据,见文件头 ④')
    ap.add_argument('--focal-alpha-hi', type=float, default=1.03,
                    help='焦距敏感度与方法范围:fx、fy 同乘此倍率重三角化(1 = 不做)')
    ap.add_argument('--g1-frac', type=float, default=0.25,
                    help='G1:有效帧对 ≥ 尝试数 × 此比例(v1 是 0.5;v2 只用画面中心、各轨迹共同点,每对点数变少)')
    ap.add_argument('--g1-coverage', type=float, default=0.6,
                    help='G1:有效帧对覆盖的时间块(--block-s)占全部尝试帧对时间块的比例下限 —— 防止只量到一小段')
    ap.add_argument('--common-mask', choices=['reference', 'intersection'], default='reference',
                    help='所有轨迹共用的点掩码来源(见 measure() 注释)')
    ap.add_argument('--max-between', type=float, default=0.15)
    ap.add_argument('--max-within', type=float, default=0.25)
    ap.add_argument('--g4-max-dk', type=float, default=0.005,
                    help='G4:按估计的深度时间偏移校正后参照 k 的变化上限(默认 0.5% ≈ 尺子总区间的四分之一)')
    ap.add_argument('--block-s', type=float, default=3.0, help='块 bootstrap 的块长(秒)')
    ap.add_argument('--n-boot', type=int, default=400)
    ap.add_argument('--noise-floor-n', type=int, default=40)
    ap.add_argument('--seed', type=int, default=20260924)
    a = ap.parse_args()
    a.pair_dts = [a.pair_dt] if a.pair_dt else [float(x) for x in a.pair_dts.split(',') if x.strip()]

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

    reports, meta = run_all(scene, trajs, a)

    # 与规范 Sim3(scale_eval.sim3,整场相机中心)的交叉核对 —— 只作诊断:尺子量的是 0.3–0.9 s 帧对的局部尺度。
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
                          'k_ratio_from_ruler': ki / kj, 'diff_pct': (ki / kj / (1.0 / s) - 1.0) * 100})

    g4 = meta['g4_depth_time_offset']
    if g4.get('evaluable'):
        print(f'\nG4 深度相对图像时间偏移 δ = {g4["delta_ms"]:+.1f} ms(95% [{g4["delta_ci95_ms"][0]:+.1f}, '
              f'{g4["delta_ci95_ms"][1]:+.1f}],{g4["n_points"]} 点);按 δ 校正后参照 k 变 {g4["dk_ref_pct"]:+.3f}% '
              f'⇒ {"✅ 过" if g4["passed"] else "🔴 不过"}(上限 ±{a.g4_max_dk * 100:.2f}%)')
    else:
        print('\nG4 🔴 不可评估:' + g4.get('reason', ''))
    print(f'粗对齐曲线(诊断,深度行偏移 → 帧对间 IQR):{meta["coarse_alignment_curve_between_rel_iqr"]}')
    for n, rep in reports.items():
        e = rep['estimate']
        print(f'\n── {n} ── verdict: {rep["verdict"]}  {rep.get("verdict_parts")}')
        if np.isfinite(e['k']):
            ci, tot = rep['ci95_block_bootstrap'], rep['ci95_total']
            print(f'  k(轨迹/米) = {e["k"]:.4f} ⇒ {e["k_minus_1_pct"]:+.2f}%   帧对 {e["pairs_with_scale"]}/{e["pairs_attempted"]}'
                  f'  块 bootstrap 95% [{(ci[0] - 1) * 100:+.2f}, {(ci[1] - 1) * 100:+.2f}]%'
                  f'  ⇒ 总 95%(∪方法范围∪噪声底) [{(tot[0] - 1) * 100:+.2f}, {(tot[1] - 1) * 100:+.2f}]%')
            mr = rep.get('method_range')
            if mr:
                print(f'  方法范围(点估计,{mr["n_variants"]} 种):[{(mr["k_min"] - 1) * 100:+.2f}, {(mr["k_max"] - 1) * 100:+.2f}]%')
            fs = rep.get('focal_sensitivity')
            if fs:
                print(f'  焦距敏感度 dk/dα = {fs["dk_over_dalpha"]:+.3f}(α={fs["alpha_hi"]} ⇒ k ×{fs["k_at_alpha_hi_over_k"]:.4f})')
            nf = rep.get('noise_floor')
            if nf and 'k_95_noise_floor' in nf:
                print(f'  噪声底:NC 均值 {nf["nc_mean"]:.4f} sd {nf["nc_sd"] * 100:.2f}% 带 k∈[{nf["k_95_noise_floor"][0]:.4f},'
                      f' {nf["k_95_noise_floor"][1]:.4f}];PC ×1.03 → {nf["pc_x1_03"]["mean"]:.4f} ×1.05 → '
                      f'{nf["pc_x1_05"]["mean"]:.4f} {"✅" if nf["pc_recovered"] else "🔴"}')
            print(f'  闸 {e["gates"]}  帧对间 IQR/中位 {e["between_pair_rel_iqr"]:.4f}  帧对内 {e["within_pair_rel_iqr_median"]:.4f}')
            print(f'  分段 k {rep.get("segments_k")}')
            for f in ('03', '05'):
                pc = rep.get('control_pc_x1_' + f, {})
                print(f'  PC ×1.{f}:比值 {pc.get("ratio", float("nan")):.5f} {"✅" if pc.get("recovered") else "🔴"}')
        nc = rep['control_nc_shuffled_depth']
        print(f'  NC 深度洗牌:k={nc["k"]:.4f} 过闸={nc["passed_gates"]} '
              f'{"✅ 被拒(应当)" if nc["rejected_as_required"] else "🔴 没被拒 ⇒ 闸在这份录制上没有牙齿"}')
    print('\n同点比值(同一批帧对、同一批点,LiDAR 逐对约掉):')
    for r in meta['same_point_ratios']:
        print(f'  {r["a"]}/{r["b"]} = {r["k_a_over_k_b"]:.4f}  块 bootstrap 95% [{r["ci95_block_bootstrap"][0]:.4f},'
              f' {r["ci95_block_bootstrap"][1]:.4f}]  总 [{r["ci95_total"][0]:.4f}, {r["ci95_total"][1]:.4f}]')
    for c in cross:
        print(f'交叉核对(诊断){c["est"]}/{c["ref"]}:尺子比值 {c["k_ratio_from_ruler"]:.4f} vs 整场 Sim3 '
              f'{c["k_sim3_canonical"]:.4f}(差 {c["diff_pct"]:+.2f}%,Sim3 ATE {c["sim3_ate_cm"]:.2f} cm)')

    out = {'schema': 'pw.bench.lidar-ruler/2', 'bench_only_notice': NOTICE,
           'recording': os.path.abspath(a.recording), 'depth_dir': os.path.abspath(scene.depth_dir),
           'opencv_version': cv2.__version__,
           'depth_resolution': [scene.DW, scene.DH], 'image_resolution': [scene.W, scene.H],
           'k_definition': 'k = trajectory scale / metres (k>1 ⇒ trajectory bigger than the world)',
           'args': vars(a), 'provenance': provenance, 'pairs': meta['pairs_attempted'], 'meta': meta,
           'trajectories': reports, 'cross_check_vs_canonical_sim3': cross}
    if a.out:
        os.makedirs(a.out, exist_ok=True)
        p = os.path.join(a.out, 'lidar_ruler_report.json')
        json.dump(out, open(p, 'w'), indent=1, ensure_ascii=False, default=float)
        print(f'\n写出 {p}')
    return 0 if all(r['verdict'] == 'valid' for r in reports.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
