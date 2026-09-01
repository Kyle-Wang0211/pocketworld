// proc_cpu_probe.dart — Android /proc + /sys 的 CPU 归因探针(纯 Dart)。
//
// 为什么放在 Dart 而不是 Kotlin:这些全是**读文本文件 + 解析**,dart:io 在
// Android 上直接就能读 /proc/self/stat 与 /sys/devices/system/cpu/*。
// 放 Dart 的好处是解析逻辑**可以在 Mac 上离机单测** —— 而 /proc/<pid>/stat
// 的解析恰恰有一个经典陷阱:comm 字段(第 2 个)是用户可控的、**可以包含
// 空格和右括号**,按空格 split 会把后面所有字段错位。错位之后 processor
// 字段会读到一个看着完全合理的小整数,静默错到底。
// 所以必须**从最后一个 ')' 之后**开始切分。这条由单测钉死。
//
// 字段编号依 proc(5):
//   field 14 utime, field 15 stime, field 39 processor(最后运行在哪个核)。
// 最后一个 ')' 之后的第一个 token 是 field 3,所以 field N -> tokens[N-3]。
//
// ⚠️ 可读性现实:
//   * /proc/self/stat            —— 自己的进程,一直可读。
//   * /sys/.../cpuinfo_max_freq  —— 通常可读(静态值)。
//   * /sys/.../scaling_cur_freq  —— Android 10+ 常被 SELinux 挡掉。
//     所以它**不能当主判据**;读不到就是 null,不是 0。
// 主判据永远是 cpuDuty + 单位工作耗时(见 slowdown_attribution.dart)。

/// 从 `/proc/<pid>/stat` 或 `/proc/self/task/<tid>/stat` 的内容里解析出的字段。
class ProcStat {
  const ProcStat({
    required this.utimeTicks,
    required this.stimeTicks,
    required this.processor,
  });

  final int utimeTicks;
  final int stimeTicks;

  /// 最后一次运行在哪个核。
  final int processor;

  int get totalTicks => utimeTicks + stimeTicks;
}

/// 解析 /proc/.../stat。格式不符返回 null(绝不猜)。
ProcStat? parseProcStat(String content) {
  final close = content.lastIndexOf(')');
  if (close < 0 || close + 1 >= content.length) return null;
  final rest = content.substring(close + 1).trim();
  if (rest.isEmpty) return null;
  final tokens = rest.split(RegExp(r'\s+'));
  // 需要至少到 field 39 ⇒ tokens[36] ⇒ 长度 >= 37。
  if (tokens.length < 37) return null;

  int? at(int fieldNumber) {
    final idx = fieldNumber - 3;
    if (idx < 0 || idx >= tokens.length) return null;
    return int.tryParse(tokens[idx]);
  }

  final utime = at(14);
  final stime = at(15);
  final processor = at(39);
  if (utime == null || stime == null || processor == null) return null;
  return ProcStat(
    utimeTicks: utime,
    stimeTicks: stime,
    processor: processor,
  );
}

/// 解析 /sys/devices/system/cpu/{online,present} 的区间表示,如
/// "0-7"、"0-3,6-7"、"0"。解析失败返回空集。
Set<int> parseCpuRangeList(String content) {
  final out = <int>{};
  final trimmed = content.trim();
  if (trimmed.isEmpty) return out;
  for (final part in trimmed.split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final dash = p.indexOf('-');
    if (dash < 0) {
      final v = int.tryParse(p);
      if (v == null) return <int>{};
      out.add(v);
    } else {
      final lo = int.tryParse(p.substring(0, dash));
      final hi = int.tryParse(p.substring(dash + 1));
      if (lo == null || hi == null || hi < lo) return <int>{};
      for (var i = lo; i <= hi; i++) {
        out.add(i);
      }
    }
  }
  return out;
}

/// 解析单个频率文件(kHz)。空/非法返回 null —— null 表示**读不到**。
int? parseFreqKhz(String? content) {
  if (content == null) return null;
  final t = content.trim();
  if (t.isEmpty) return null;
  return int.tryParse(t);
}

/// utime+stime 的 tick 差分转毫秒。`ticksPerSecond` 在 Android 上恒为 100
/// (USER_HZ),但仍作参数传入,避免把假设写死。
double ticksToMillis(int deltaTicks, {int ticksPerSecond = 100}) {
  if (ticksPerSecond <= 0) return 0;
  return deltaTicks * 1000.0 / ticksPerSecond;
}

/// 从 `/proc/self/task/<tid>/stat` 的全量快照里挑出**最忙的线程**。
///
/// 为什么需要它:归因关心的是"跑 VIO 的那个线程在哪个核上",但 Dart 侧
/// 拿不到 native 线程的 tid。绕开办法是把 /proc/self/task/ 下所有线程都读一遍,
/// 取 CPU 时间增量最大的那个 —— 在采集期间,那就是 VIO 工作线程。
/// 这样整条探针都留在 Dart 里,不需要为了拿一个 tid 去写 Kotlin/JNI。
///
/// [previous] 是上一拍的快照(tid -> ProcStat);首拍传空 map,
/// 此时按累计 CPU 时间取最大值。返回 null 表示没有可用样本。
MapEntry<int, ProcStat>? busiestThread(
  Map<int, ProcStat> current, {
  Map<int, ProcStat> previous = const <int, ProcStat>{},
}) {
  MapEntry<int, ProcStat>? best;
  var bestDelta = -1;
  for (final e in current.entries) {
    final prev = previous[e.key];
    final delta =
        prev == null ? e.value.totalTicks : e.value.totalTicks - prev.totalTicks;
    if (delta > bestDelta) {
      bestDelta = delta;
      best = e;
    }
  }
  return best;
}
