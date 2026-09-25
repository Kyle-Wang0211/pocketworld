#!/usr/bin/env python3
"""把台架的 `run-*` 录制转成 `xrslam-pc-player` 吃的 EuRoC 目录。

══ 为什么要这一步 ═══════════════════════════════════════════════════════════
要扫 `p_bc` 和 `td` 对 VIO 尺度的影响,需要一个**能改 YAML 并回放**的载体:
  · 台架 `VIOReplacementBench` 能回放,但**源码已丢失**,而且它的二进制里
    **没有 `p_bc` 字符串** —— 它根本不写这个配置项,改不了。
  · `arloopbench` 有源码会写 `p_bc`,但**没有回放能力**(live 专用)。
  · ⇒ 用上游自带的 `xrslam-pc/player`:吃 YAML、吃 `euroc://` 目录、`--csv` 出轨迹。

══ 格式逐字对照(读源码,不猜)═══════════════════════════════════════════════
`xrslam-pc/player/src/IO/euroc_dataset_reader.h`:
  · `CameraCsv::load` :`fscanf(csv, "%lf,%2047[^\\r]\\r\\n", &t, filename)`,
    **一行表头**,`t *= 1e-9` ⇒ CSV 里存**纳秒**,第二列是 `cam0/data/` 下的文件名。
    🔴 **行尾必须是 CRLF。** 格式串里写死了 `\\r\\n`,而 `%2047[^\\r]` 读到 `\\r` 为止 ——
       写成 LF 的话它会一路吞到 2047 字符,把整行(含逗号和后续行)当成文件名。
       实测症状:player 报 `'<时间戳>,<文件名>.png ... ': can't open/read file`。
       真实 EuRoC 数据集就是 CRLF。本脚本因此显式写 `\\r\\n`。
  · `ImuCsv::load`    :`fscanf(csv, "%lf,%lf,%lf,%lf,%lf,%lf,%lf", &t,&w.x,&w.y,&w.z,&a.x,&a.y,&a.z)`,
    同样一行表头、纳秒。
    🔑 **字段顺序与我们的 `imu.csv`(`timestamp_ns,wx,wy,wz,ax,ay,az`)完全一致**,
       只需换表头,数值一个都不用动。
  · `ImuCsv::save` 写的表头原文:
    `#t[ns],w.x[rad/s:double],...,a.z[m/s^2:double]` —— 本脚本照抄它。

🔑 `euroc_dataset_reader.cpp:16-19` 在装载时做
   `image_data.emplace_back(item.t + config->camera_time_offset(), ...)`
   ⇒ **`cam0.time_offset` 由 reader 施加,不是引擎核心**。所以 `td` 扫描
   只改 YAML 即可,**不用改本脚本产出的 CSV**。
   (反过来说:iOS 路径上台架直接喂帧、没有 reader ⇒ **生产路径对 td 零补偿**。)

══ 输入侧 ═══════════════════════════════════════════════════════════════════
`camera_index.csv` : `timestamp_ns,relative_path`(relative_path 就是帧序号)

══ [2026-09-22] `--exposure-half`:相机时间戳换算到曝光中点 ═══════════════
iOS 的 PTS 打在**曝光起点**(Huai arXiv 2001.00470 §IV.B),VIO 要的是中点 ⇒
`t_canonical = t_pts + exposure/2`。台架直播路径已在 `PwXrslamLive.swift`(偏离 (d))
逐帧做同样的换算;回放要对得上直播,这里必须做同一件事。
  · 曝光来源:`intrinsics.jsonl` 每帧记录里的 **`exposure_s`**(秒)。写它的是
    VIOReplacementBench 的 `DeviceRecordingWriter.recordIntrinsics(exposureSeconds:)`
    (仓 pocketworld-research-benchmarks,worktree
    `~/.config/superpowers/worktrees/pocketworld_research_benchmarks/basalt-vio-phone-bench-20260829`),
    ARKit 臂给 `ARFrame.camera.exposureDuration`、原生臂给 `AVCaptureDevice.exposureDuration`。
    09-22 之前的 run-* **均无此字段**,对它们开这个开关会**拒绝运行**而不是静默按 0
    —— 旧录制只能用 `cam0.time_offset` 扫一个常量,那个常量里混着曝光/2。
  · 文件名与 csv 时间戳一起平移,保持 `<t>.png` == csv 里的 t。
  · 🔴 **配对按时间戳,不按下标**:ARKit 臂对每个 ARFrame 都写一行内参
    (`recordIntrinsics` 在 `appendFrame` 之前),而帧流有背压丢帧
    (run-4ad6e500:内参 1768 行 vs 帧 1671)。按下标配对从第一次丢帧起就错位。
    这里用 `t`(秒,float)与 `timestamp_ns` 最近邻配对,容差 1 ms;配不上的帧
    如实计数,配对率 < 99% 拒绝运行。
  · 加完之后 `cam0.time_offset` 扫出来的极小点就是每机常量 c(卷帘读出/2 + 固定延迟)。
══ [2026-09-22] `--intrinsics-csv <path>`:导出逐帧内参 `t_ns,fx,fy,cx,cy` ════════
XRSLAM 逐帧内参臂(C 臂)的输入。每帧一行,`t_ns` 与 `cam0/data.csv` 里的时间戳**同一个数**
(含 `--exposure-half` 的平移),runner 按它配对。fx/fy/cx/cy 来自 `intrinsics.jsonl` 的
`intrinsics_fxfycxcy`(ARKit `ARFrame.camera.intrinsics`,自动对焦下逐帧变)。
  · 配对规则与 `--exposure-half` **同一段代码**(`pair_intrinsics_rows`):按时间戳最近邻、
    1 ms 容差、配对率 < 99% 拒绝;配不上的帧不写行(runner 那边如实计数并回退到常量 K)。
  · `--downscale d`:fx' = fx/d、fy' = fy/d、cx' = (cx+0.5)/d − 0.5(块平均的像素中心约定)。
    d=1 时恒等。
  · 不带此参数 = 不导出 = A 臂(runner 无 CSV ⇒ 引擎走 yaml 常量 K = 第 0 帧冻结)。
`frames.pwvi`      : **JSONL**,每行 `{"frame":N,"offset":X,"len":2764800,...}`
                     🔴 `len` 这个键名不统一:`run-5966aec0` 用的是 `"length"`。
`frames.bin`       : 裸 luma8,1920×1440(`recording_manifest.json` 的
                     `pixel_format: luma8_from_420f_full_range`)
`imu.csv`          : `timestamp_ns,wx,wy,wz,ax,ay,az`

══ [2026-09-25 xr-recon-chain] 新 IMU 录制格式 `imu_events.csv` ══════════════════
录制器修复(pocketworld bench/xr-recon-chain:PwBenchLidarSession S8 / 写器 W13 / 装载器 D11)后,新录制不再有
配对的 imu.csv,而是 `imu_events.csv`:`timestamp_ns,sensor,x,y,z`,sensor ∈ {gyro, accel},陀螺与加计
**各自**一行、各带自己的 CoreMotion 时间戳(照抄 XRSLAM 官方 iOS 示例 Motion.swift @4beb1a9)。单位同旧格式。
EuRoC 的 imu0/data.csv 一行必须同一时刻带 w 与 a,所以要在转换时对齐 —— 用的是**引擎自己的同步规则**
(xrslam core/detail.cpp track_accelerometer / track_gyroscope,喂两路原始流时引擎内部就是这样合成样本的):
  · 每条加计(时刻 t_a)出一行,时刻 = t_a,加计值原样;
  · 陀螺在 t_a 处按**相邻两条陀螺**线性插值:λ = (t_a − g0.t) / (g1.t − g0.t),w = g0.w + λ·(g1.w − g0.w)
    (逐分量,与 detail.cpp 同一算式同一运算次序;时刻按 int(ns)·1e−9 换成秒,与 EuRoC reader 同);
    t_a 恰等于某条陀螺时刻 ⇒ 直接用那条陀螺(引擎 t == gyroscopes.back().t 分支);
  · 第一条陀螺之前、最后一条陀螺之后的加计不出行(引擎同样丢弃 / 永远等不到右端陀螺)。
旧格式(有 imu.csv)走原来那段代码,一个字节不变。两个文件都在时以 imu_events.csv 为准(与装载器 D11 同)。
"""
import argparse
import csv
import json
import os
import sys


def load_index(pwvi):
    """读 frames.pwvi(JSONL)。兼容 `len` / `length` 两种键名。"""
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('recording', help='run-* 录制目录')
    ap.add_argument('out', help='输出的 EuRoC 目录')
    ap.add_argument('--exposure-half', action='store_true',
                    help='相机时间戳 += intrinsics.jsonl 里 exposure_s/2(曝光中点);'
                         '录制无该字段则拒绝运行')
    ap.add_argument('--downscale', type=int, default=1,
                    help='整数因子块平均降采样(3 ⇒ 1920×1440→640×480,复现论文输入分辨率;'
                         '内参不在 EuRoC 里,device yaml 自行用 640 档)')
    ap.add_argument('--intrinsics-csv', default='',
                    help='导出逐帧内参 CSV(t_ns,fx,fy,cx,cy),t 与 cam0/data.csv 同一个数;'
                         '配对规则同 --exposure-half')
    ap.add_argument('--limit', type=int, default=0,
                    help='只转前 N 帧(调试用;0 = 全部)')
    a = ap.parse_args()

    man = json.load(open(os.path.join(a.recording, 'recording_manifest.json')))
    W = man['camera']['width']
    H = man['camera']['height']
    pixfmt = man['camera']['pixel_format']
    if 'luma8' not in pixfmt:
        raise SystemExit(f'🔴 只支持 luma8,本录制是 {pixfmt}')
    expect = W * H
    print(f'录制 {W}×{H} {pixfmt}  每帧应为 {expect} B')

    idx = load_index(os.path.join(a.recording, 'frames.pwvi'))
    bad = [(n, ln) for n, _, ln in idx if ln != expect]
    if bad:
        raise SystemExit(f'🔴 {len(bad)} 帧长度与 {W}×{H} 不符,首例 {bad[0]}')
    off_by_frame = {n: o for n, o, _ in idx}

    ts = []
    with open(os.path.join(a.recording, 'camera_index.csv')) as f:
        r = csv.reader(f)
        next(r)
        for row in r:
            if row:
                ts.append((int(row[0]), int(row[1])))
    print(f'camera_index {len(ts)} 帧   frames.pwvi {len(idx)} 帧')
    if a.limit:
        ts = ts[:a.limit]

    # ── intrinsics.jsonl ↔ camera_index 的时间戳配对(--exposure-half 与 --intrinsics-csv 共用)──
    def pair_intrinsics_rows(what):
        """返回与 ts 等长的列表:每帧配上的 intrinsics.jsonl 记录(dict)或 None。
        规则:按 t(秒)与 timestamp_ns 最近邻配对,容差 1 ms;配对率 < 99% 拒绝运行。"""
        ipath = os.path.join(a.recording, 'intrinsics.jsonl')
        if not os.path.exists(ipath):
            raise SystemExit(f'🔴 {what} 需要 intrinsics.jsonl,录制里没有')
        recs = [json.loads(l) for l in open(ipath) if l.strip()]
        import bisect
        table = sorted(((int(round(float(r['t']) * 1e9)), r) for r in recs if 't' in r),
                       key=lambda x: x[0])
        keys = [t for t, _ in table]
        out = [None] * len(ts); unmatched = 0
        for k, (t_ns, _fid) in enumerate(ts):
            i = bisect.bisect_left(keys, t_ns)
            best = None
            for j in (i - 1, i):
                if 0 <= j < len(keys) and abs(keys[j] - t_ns) <= 1_000_000:  # 1 ms
                    if best is None or abs(keys[j] - t_ns) < abs(keys[best] - t_ns):
                        best = j
            if best is None:
                unmatched += 1; continue
            out[k] = table[best][1]
        print(f'时间戳配对({what}):内参 {len(recs)} 行 ↔ 相机 {len(ts)} 帧;'
              f'配上 {len(ts)-unmatched},配不上 {unmatched}')
        if unmatched > 0.01 * len(ts):
            raise SystemExit(f'🔴 配对率 {(len(ts)-unmatched)/len(ts):.2%} < 99%,拒绝')
        return out

    # ── 曝光(可选)──
    expo = [None] * len(ts)
    if a.exposure_half:
        paired = pair_intrinsics_rows('--exposure-half')
        have = 0
        for k, r in enumerate(paired):
            if r is None:
                continue
            e = r.get('exposure_s')
            if isinstance(e, (int, float)) and e >= 0:
                expo[k] = float(e); have += 1
        if have == 0:
            raise SystemExit(
                '🔴 --exposure-half:intrinsics.jsonl 没有任何一帧带 exposure_s。\n'
                '   这份录制来自不写曝光的录制器,无法换算到曝光中点;'
                '不静默按 0 —— 去掉开关只扫 cam0.time_offset 常量即可。')
        shift_ms = [0.5 * e * 1e3 for e in expo if e is not None]
        print(f'曝光:{have}/{len(ts)} 帧有 exposure_s;'
              f'平移 exposure/2 均值 {sum(shift_ms)/len(shift_ms):.3f} ms '
              f'[{min(shift_ms):.3f}, {max(shift_ms):.3f}]')

    try:
        import numpy as np
        from PIL import Image
    except ImportError as e:
        raise SystemExit(f'🔴 需要 numpy + Pillow: {e}')

    # ── 逐帧内参(可选)──
    kpaired = pair_intrinsics_rows('--intrinsics-csv') if a.intrinsics_csv else None

    cam_dir = os.path.join(a.out, 'cam0', 'data')
    imu_dir = os.path.join(a.out, 'imu0')
    os.makedirs(cam_dir, exist_ok=True)
    os.makedirs(imu_dir, exist_ok=True)

    # ── 相机 ───────────────────────────────────────────────────────────
    binp = os.path.join(a.recording, 'frames.bin')
    missing = 0
    fk = open(a.intrinsics_csv, 'w', newline='') if a.intrinsics_csv else None
    if fk:
        fk.write('#t_ns(== cam0/data.csv),fx,fy,cx,cy\n')
    n_k = 0; fx_list = []
    with open(binp, 'rb') as fb, \
         open(os.path.join(a.out, 'cam0', 'data.csv'), 'w', newline='') as fc:
        fc.write('#timestamp [ns],filename\r\n')   # 一行表头,reader 会跳过
        for k, (t_ns, fid) in enumerate(ts):
            if fid not in off_by_frame:
                missing += 1
                continue
            fb.seek(off_by_frame[fid])
            buf = fb.read(expect)
            if len(buf) != expect:
                missing += 1
                continue
            # 曝光中点:文件名与 csv 用同一个平移后的 t(见文件头 --exposure-half)
            t_out = t_ns + (int(round(0.5 * expo[k] * 1e9))
                            if (a.exposure_half and expo[k] is not None) else 0)
            name = f'{t_out}.png'
            if fk is not None and kpaired[k] is not None:
                K = kpaired[k].get('intrinsics_fxfycxcy')
                if isinstance(K, list) and len(K) == 4:
                    d = a.downscale
                    fx, fy, cx, cy = (float(K[0]) / d, float(K[1]) / d,
                                      (float(K[2]) + 0.5) / d - 0.5, (float(K[3]) + 0.5) / d - 0.5)
                    fk.write(f'{t_out},{fx!r},{fy!r},{cx!r},{cy!r}\n')
                    n_k += 1; fx_list.append(fx)
            img = np.frombuffer(buf, dtype=np.uint8).reshape(H, W)
            if a.downscale > 1:
                d = a.downscale
                # 块平均 = OpenCV INTER_AREA 的整数因子情形;不是抽样,避免混叠
                img = img[:H - H % d, :W - W % d].reshape(H // d, d, W // d, d) \
                         .mean(axis=(1, 3)).round().astype(np.uint8)
            Image.fromarray(img, mode='L').save(
                os.path.join(cam_dir, name), compress_level=1)
            fc.write(f'{t_out},{name}\r\n')
            if k % 200 == 0:
                print(f'  帧 {k}/{len(ts)}', flush=True)
    print(f'相机写出 {len(ts)-missing} 帧  缺 {missing}')
    if fk is not None:
        fk.close()
        print(f'逐帧内参写出 {n_k} 行 -> {a.intrinsics_csv};'
              f'fx 极差 {max(fx_list)-min(fx_list):.3f} px [{min(fx_list):.3f}, {max(fx_list):.3f}] '
              f'均值 {sum(fx_list)/len(fx_list):.3f}' if fx_list else
              f'🔴 逐帧内参一行都没写出(intrinsics.jsonl 缺 intrinsics_fxfycxcy?)')

    # ── IMU ────────────────────────────────────────────────────────────
    ev_path = os.path.join(a.recording, 'imu_events.csv')
    if os.path.exists(ev_path):
        n, dropped, exact = convert_imu_events(ev_path, os.path.join(imu_dir, 'data.csv'))
        print(f'IMU(imu_events.csv,两路各自时间戳 → 引擎同步规则)写出 {n} 行;'
              f'其中恰与陀螺同刻 {exact} 行;首条陀螺前 / 末条陀螺后的加计不出行 {dropped} 条')
        print(f'\n✅ {a.out}')
        print(f'   跑法: xrslam-pc-player -c <yaml> --csv <out.csv> euroc://{a.out}')
        return 0
    n = 0
    with open(os.path.join(a.recording, 'imu.csv')) as fi, \
         open(os.path.join(imu_dir, 'data.csv'), 'w', newline='') as fo:
        r = csv.reader(fi)
        head = next(r)
        assert head == ['timestamp_ns', 'wx', 'wy', 'wz', 'ax', 'ay', 'az'], \
            f'🔴 imu.csv 表头不是预期的: {head}'
        # 表头逐字抄 ImuCsv::save
        fo.write('#t[ns],w.x[rad/s:double],w.y[rad/s:double],w.z[rad/s:double],'
                 'a.x[m/s^2:double],a.y[m/s^2:double],a.z[m/s^2:double]\r\n')
        for row in r:
            if row:
                fo.write(','.join(row) + '\r\n')
                n += 1
    print(f'IMU 写出 {n} 条')
    print(f'\n✅ {a.out}')
    print(f'   跑法: xrslam-pc-player -c <yaml> --csv <out.csv> euroc://{a.out}')
    return 0


def convert_imu_events(src, dst):
    """imu_events.csv → EuRoC imu0/data.csv(见文件头 [2026-09-25] 段)。返回 (行数, 丢弃的加计, 恰同刻行数)。"""
    import bisect
    gyro, accel = [], []
    with open(src) as f:
        head = f.readline().strip()
        if head != 'timestamp_ns,sensor,x,y,z':
            raise SystemExit(f'🔴 imu_events.csv 表头不是预期的: {head}')
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            t, s, x, y, z = ln.split(',')
            if s == 'gyro':
                gyro.append((int(t), (float(x), float(y), float(z))))
            elif s == 'accel':
                accel.append((int(t), (x, y, z)))      # 加计值原样(字符串)
            else:
                raise SystemExit(f'🔴 imu_events.csv 未知传感器: {s}')
    for name, seq in (('gyro', gyro), ('accel', accel)):
        for (t0, _), (t1, _) in zip(seq, seq[1:]):
            if t1 <= t0:
                raise SystemExit(f'🔴 imu_events.csv {name} 时间戳不递增: {t0} -> {t1}')
    gk = [t for t, _ in gyro]
    n = dropped = exact = 0
    with open(dst, 'w', newline='') as fo:
        fo.write('#t[ns],w.x[rad/s:double],w.y[rad/s:double],w.z[rad/s:double],'
                 'a.x[m/s^2:double],a.y[m/s^2:double],a.z[m/s^2:double]\r\n')
        for ta_ns, av in accel:
            k = bisect.bisect_right(gk, ta_ns) - 1
            if k < 0:
                dropped += 1; continue
            if gk[k] == ta_ns:
                w = gyro[k][1]; exact += 1
            elif k + 1 < len(gk):
                g0t, g0w = gyro[k][0] * 1e-9, gyro[k][1]
                g1t, g1w = gyro[k + 1][0] * 1e-9, gyro[k + 1][1]
                lam = (ta_ns * 1e-9 - g0t) / (g1t - g0t)
                w = tuple(g0w[i] + lam * (g1w[i] - g0w[i]) for i in range(3))
            else:
                dropped += 1; continue
            fo.write(f'{ta_ns},{w[0]!r},{w[1]!r},{w[2]!r},{av[0]},{av[1]},{av[2]}\r\n')
            n += 1
    return n, dropped, exact


if __name__ == '__main__':
    sys.exit(main())
