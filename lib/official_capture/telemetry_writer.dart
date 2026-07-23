// telemetry_writer.dart — 真机验收版"极致详细遥测"的 Dart 侧 JSONL 写手。
//
// 产物:App 容器 Documents/telemetry_official_dart.jsonl,每行一个 JSON 对象
//   {"t":<epoch_ms>,"type":"frame|card|guidance|colorize|…",...}
// 与 Swift 侧 Documents/telemetry_official_native.jsonl(OfficialAetherARKitPlugin.swift 的
// PwNativeTelemetry)配对,devicectl 一次拉走,时间戳都是 epoch ms 可直接对齐。
//
// 设计铁律(任务①"关键路径零阻塞"):
//   • [event] 永不阻塞、永不抛:一次同步字符串拼接 + IOSink.add(内存缓冲,
//     真正的磁盘写由 dart:io 异步完成);flush 节流(2s)只是把 OS 缓冲兜底,
//     丢失窗口 ≤2s,可接受。
//   • 单写手:只有主 isolate 持有 sink。worker isolate 的遥测经既有
//     SendPort(sfm_live_recon.dart 的 {'evt':'telem'} 消息)汇聚到主
//     isolate 再写——单 sink 顺序 add 保证行完整性(断言脚本
//     tool/telemetry_check.dart 验证)。
//   • init 之前的事件进内存 pending 队列(上限 [_maxPending]),init 后补写,
//     不丢启动早期事件。
//
// 本文件零 Flutter 依赖(纯 dart:io),tool/telemetry_check.dart 用纯 Dart VM
// 直接驱动断言。App 侧由 main.dart 解析 Documents 路径后调用 [init]。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 排序后取分位数(p ∈ [0,1],最近邻法)。空列表返回 null。
/// 供 colorize 统计(样本色方差 p50/p90、解码耗时中位)等复用;
/// tool/telemetry_check.dart 有断言。
double? percentileSorted(List<double> sorted, double p) {
  if (sorted.isEmpty) return null;
  final idx = (p * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
  return sorted[idx];
}

class TelemetryWriter {
  TelemetryWriter._();
  static final TelemetryWriter instance = TelemetryWriter._();

  IOSink? _sink;
  bool _initFailed = false;
  Timer? _flushTimer;
  bool _dirtySinceFlush = false;
  int _written = 0;
  int _dropped = 0;

  /// init 之前到达的事件行(启动早期),init 成功后按序补写。
  final List<String> _pending = <String>[];
  static const int _maxPending = 1024;

  /// 已成功写入 sink 的事件行数(断言脚本用)。
  int get writtenCount => _written;

  /// 因 init 失败 / pending 溢出而丢弃的行数。
  int get droppedCount => _dropped;

  /// 打开(追加模式)JSONL 文件。可重复调用(幂等);失败只关掉遥测,
  /// 绝不影响 App。App 侧路径 = `<Documents>/telemetry_official_dart.jsonl`。
  Future<void> init(String filePath) async {
    if (_sink != null || _initFailed) return;
    try {
      final file = File(filePath);
      await file.parent.create(recursive: true);
      final sink = file.openWrite(mode: FileMode.append);
      _sink = sink;
      // 补写 init 前排队的事件(保持到达顺序)。
      if (_pending.isNotEmpty) {
        for (final line in _pending) {
          sink.add(utf8.encode(line));
          _written++;
        }
        _pending.clear();
        _dirtySinceFlush = true;
        _scheduleFlush();
      }
    } catch (_) {
      _initFailed = true;
      _dropped += _pending.length;
      _pending.clear();
    }
  }

  /// 记一行 {"t":epoch_ms,"type":type,...fields}。同步、非阻塞、永不抛。
  /// fields 值须是 JSON 可编码类型(num/String/bool/List/Map/null);
  /// 个别不可编码值降级为 toString,绝不让一条脏数据毁掉整条链。
  void event(String type, [Map<String, Object?> fields = const {}]) {
    try {
      final map = <String, Object?>{
        't': DateTime.now().millisecondsSinceEpoch,
        'type': type,
        ...fields,
      };
      String line;
      try {
        line = '${jsonEncode(map)}\n';
      } catch (_) {
        // 含不可编码值 — 逐字段降级为字符串再试一次。
        line =
            '${jsonEncode(map.map((k, v) => MapEntry(k, v is num || v is String || v is bool || v == null ? v : '$v')))}\n';
      }
      final sink = _sink;
      if (sink == null) {
        if (_initFailed || _pending.length >= _maxPending) {
          _dropped++;
          return;
        }
        _pending.add(line);
        return;
      }
      sink.add(utf8.encode(line)); // 内存缓冲,不等磁盘
      _written++;
      _dirtySinceFlush = true;
      _scheduleFlush();
    } catch (_) {
      // 遥测绝不伤害 App。
    }
  }

  /// flush 节流:2s 一次,把 IOSink 缓冲推给 OS。
  void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      if (!_dirtySinceFlush) return;
      _dirtySinceFlush = false;
      try {
        _sink?.flush().catchError((Object _) {});
      } catch (_) {}
    });
  }

  /// 立即落盘(测试/退出用;App 正常运行不需要)。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _dirtySinceFlush = false;
    try {
      await _sink?.flush();
    } catch (_) {}
  }

  /// 关闭 sink(断言脚本用;App 侧从不调用——进程活着就一直可写)。
  Future<void> close() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } catch (_) {}
    }
  }
}
