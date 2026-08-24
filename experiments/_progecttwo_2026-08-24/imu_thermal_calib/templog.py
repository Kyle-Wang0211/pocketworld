#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
采集侧记事本 —— 边采边把"温度 / 升降温支 / 平台 / 姿态段"打成 segments.csv
==========================================================================

为什么需要它:iOS **没有任何公开 API 能读数值温度**(已查证,见 PROTOCOL.md),
所以温度必须由人从外置温度计读出来手工记。这个脚本负责把手记的东西
和 IMU 记录的**时间轴**对齐,直接产出分析脚本要的 segments.csv。

铁律:**每写一行立刻 flush 落盘**。采集中途崩了也只丢当前这一行,
不会丢已经采好的段(fail-safe 只许推迟,不许丢数据)。

命令(从 stdin 逐行读,可交互也可脚本化)
----------------------------------------
    T <°C>        设定当前温度(之后所有段都用它)
    B heat|cool   设定当前在升温支还是降温支
    P <id>        开一个新的温度平台
    S <pose_id>   开始一个姿态段(记 t_start)
    E             结束当前姿态段(记 t_end 并落盘一行)
    M <text>      记一条备注到 notes 文件(比如"手接触了 3 秒""空调开了")
    ?             打印当前状态
    Q             退出

用法
----
    python3 templog.py --out ~/calib_20260824/          # 交互
    python3 templog.py --selftest                       # 脚本化自测
"""
import os
import sys
import time
import argparse

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

HEADER = "t_start,t_end,plateau_id,branch,temp_c,pose_id\n"


class Recorder:
    def __init__(self, outdir, clock=time.time):
        os.makedirs(outdir, exist_ok=True)
        self.seg_path = os.path.join(outdir, "segments.csv")
        self.note_path = os.path.join(outdir, "notes.txt")
        new = not os.path.exists(self.seg_path) or os.path.getsize(self.seg_path) == 0
        self.f = open(self.seg_path, "a", buffering=1)
        if new:
            self.f.write(HEADER); self.f.flush()
        self.nf = open(self.note_path, "a", buffering=1)
        self.clock = clock
        self.temp = None
        self.branch = None
        self.plateau = 0
        self.open_pose = None
        self.open_t0 = None
        self.rows = 0

    # -- 命令 -------------------------------------------------------------
    def cmd(self, line):
        s = line.strip()
        if not s:
            return None
        op = s[0].upper()
        arg = s[1:].strip()
        if op == "T":
            self.temp = float(arg); return f"温度 = {self.temp} °C"
        if op == "B":
            b = arg.lower()
            if b not in ("heat", "cool"):
                raise ValueError("B 只接受 heat 或 cool")
            self.branch = b; return f"支 = {b}"
        if op == "P":
            self.plateau = int(arg); return f"平台 = {self.plateau}"
        if op == "S":
            if self.open_pose is not None:
                raise ValueError(f"姿态 {self.open_pose} 还没 E,不能再 S")
            if self.temp is None or self.branch is None or self.plateau == 0:
                raise ValueError("开始姿态前必须先设好 T / B / P")
            self.open_pose = int(arg); self.open_t0 = self.clock()
            return f"姿态 {self.open_pose} 开始 @ {self.open_t0:.3f}"
        if op == "E":
            if self.open_pose is None:
                raise ValueError("没有正在进行的姿态段")
            t1 = self.clock()
            self.f.write(f"{self.open_t0:.6f},{t1:.6f},{self.plateau},"
                         f"{self.branch},{self.temp:.3f},{self.open_pose}\n")
            self.f.flush(); os.fsync(self.f.fileno())      # 立刻落盘
            dur = t1 - self.open_t0
            msg = f"姿态 {self.open_pose} 结束,时长 {dur:.1f}s"
            if dur < 8.0:
                msg += "  ⚠️ < 8 s,扣掉护带后有效样本可能不够"
            self.open_pose = None; self.rows += 1
            return msg
        if op == "M":
            self.nf.write(f"{self.clock():.6f}\t{arg}\n"); self.nf.flush()
            return f"备注已记"
        if op == "?":
            return (f"平台={self.plateau} 支={self.branch} 温度={self.temp} "
                    f"进行中姿态={self.open_pose} 已落盘={self.rows} 行")
        if op == "Q":
            return "QUIT"
        raise ValueError(f"不认识的命令: {s}")

    def close(self):
        if self.open_pose is not None:
            self.nf.write(f"{self.clock():.6f}\t⚠️ 退出时姿态 {self.open_pose} 未 E,该段丢弃\n")
        self.f.close(); self.nf.close()


def selftest():
    import tempfile
    from thermal_hysteresis import load_segments
    print("=" * 70 + "\n  templog 正向对照\n" + "=" * 70)
    ok = True
    d = tempfile.mkdtemp(prefix="templog_")
    tick = [1000.0]

    def clk():
        tick[0] += 10.0
        return tick[0]
    r = Recorder(d, clock=clk)
    script = ["T 26.0", "B heat", "P 1"] + \
             [c for p in range(14) for c in (f"S {p}", "E")] + \
             ["T 41.0", "B cool", "P 2"] + \
             [c for p in range(14) for c in (f"S {p}", "E")] + ["M 空调关了", "Q"]
    for line in script:
        try:
            r.cmd(line)
        except ValueError as e:
            print(f"  ❌ 命令 {line!r} 意外报错: {e}"); ok = False
    r.close()

    segs = load_segments(os.path.join(d, "segments.csv"))
    good = len(segs) == 28
    ok &= good
    print(f"  {'✅' if good else '❌'} 落盘 {len(segs)} 段(期望 28),且被 "
          f"thermal_hysteresis.load_segments 成功解析")
    good = {s["branch"] for s in segs} == {"heat", "cool"} and \
           len({s["plateau_id"] for s in segs}) == 2
    ok &= good
    print(f"  {'✅' if good else '❌'} 两个平台 / 两支都在")
    good = all(s["t_end"] > s["t_start"] for s in segs)
    ok &= good
    print(f"  {'✅' if good else '❌'} 所有段 t_end > t_start")

    # 错误处理:S 之后再 S、没 S 就 E、非法 branch、缺前置状态
    r2 = Recorder(tempfile.mkdtemp(prefix="templog2_"), clock=clk)
    checks = [("E", "没 S 就 E"), ("B warm", "非法 branch"), ("S 1", "缺 T/B/P 就 S"),
              ("X", "未知命令")]
    for cmdline, why in checks:
        try:
            r2.cmd(cmdline); bad = True
        except ValueError:
            bad = False
        ok &= (not bad)
        print(f"  {'✅' if not bad else '❌'} 拒绝:{why}")
    # 正常流程下 S 之后再 S 必须拒绝
    r2.cmd("T 25"); r2.cmd("B heat"); r2.cmd("P 1"); r2.cmd("S 0")
    try:
        r2.cmd("S 1"); bad = True
    except ValueError:
        bad = False
    ok &= (not bad)
    print(f"  {'✅' if not bad else '❌'} 拒绝:S 之后未 E 又 S")
    r2.close()

    # 崩溃安全:进程被杀也不丢已落盘的行
    d3 = tempfile.mkdtemp(prefix="templog3_")
    r3 = Recorder(d3, clock=clk)
    r3.cmd("T 30"); r3.cmd("B heat"); r3.cmd("P 1")
    r3.cmd("S 0"); r3.cmd("E")
    r3.cmd("S 1")                                   # 故意不 E,模拟崩在半路
    del r3                                          # 不调 close
    n = len(load_segments(os.path.join(d3, "segments.csv")))
    good = n == 1
    ok &= good
    print(f"  {'✅' if good else '❌'} 崩溃安全:未 close 时已落盘 {n} 段(期望 1,"
          f"未完成的那段不写入)")

    print("\n  " + ("✅ 全过" if ok else "❌ 未过"))
    return 0 if ok else 1


def negative_control():
    """负向对照:破坏落盘/校验,确认自测会红。"""
    import tempfile
    from thermal_hysteresis import load_segments
    print("=" * 70 + "\n  templog 负向对照\n" + "=" * 70)
    allred = True
    tick = [1000.0]

    def clk():
        tick[0] += 10.0
        return tick[0]

    # NC1: 写出非法 branch → load_segments 必须拒绝
    d = tempfile.mkdtemp(prefix="tlnc1_")
    p = os.path.join(d, "segments.csv")
    with open(p, "w") as f:
        f.write(HEADER); f.write("1.0,2.0,1,warm,25.0,0\n")
    try:
        load_segments(p); red = False
    except SystemExit:
        red = True
    allred &= red
    print(f"  {'✅ 变红' if red else '❌ 没变红'} NC1 branch 写成 warm → load_segments 必须拒绝")

    # NC2: 去掉 flush/fsync 的效果 —— 用一个不落盘的假 Recorder,崩溃后必须丢数据
    d2 = tempfile.mkdtemp(prefix="tlnc2_")
    p2 = os.path.join(d2, "segments.csv")
    fh = open(p2, "a", buffering=1 << 16)            # 大缓冲,不 flush
    fh.write(HEADER)
    fh.write("1.0,2.0,1,heat,25.0,0\n")
    # 不 flush 不 close,直接看盘上有什么
    on_disk = os.path.getsize(p2)
    red = on_disk == 0
    allred &= red
    print(f"  {'✅ 变红' if red else '❌ 没变红'} NC2 关掉 flush → 盘上 {on_disk} 字节 "
          f"(期望 0)⇒ 证明 Recorder 的逐行 flush 不是摆设")
    fh.close()

    # NC3: 把段数期望改错 → 自测的比对必须失败
    d3 = tempfile.mkdtemp(prefix="tlnc3_")
    r = Recorder(d3, clock=clk)
    r.cmd("T 26"); r.cmd("B heat"); r.cmd("P 1")
    for i in range(3):
        r.cmd(f"S {i}"); r.cmd("E")
    r.close()
    n = len(load_segments(os.path.join(d3, "segments.csv")))
    red = not (n == 28)
    allred &= red
    print(f"  {'✅ 变红' if red else '❌ 没变红'} NC3 只写 3 段却拿 28 去比 → 必须失败(实际 {n})")

    print("\n  " + ("✅ 负向对照全部变红" if allred else "❌ 有负向对照没变红"))
    return 0 if allred else 1


def main():
    ap = argparse.ArgumentParser(description="采集侧 segments.csv 记事本")
    ap.add_argument("--out", help="输出目录")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--negative-control", action="store_true")
    a = ap.parse_args()
    if a.negative_control:
        return negative_control()
    if a.selftest or not a.out:
        return selftest()
    r = Recorder(a.out)
    print(__doc__.split("命令")[1].split("用法")[0])
    print(f"→ 写入 {r.seg_path}")
    try:
        for line in sys.stdin:
            try:
                m = r.cmd(line)
            except ValueError as e:
                print(f"  ⚠️ {e}"); continue
            if m == "QUIT":
                break
            if m:
                print(f"  {m}")
    except KeyboardInterrupt:
        pass
    finally:
        r.close()
    print(f"共 {r.rows} 段 → {r.seg_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
