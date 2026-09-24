// bench_lidar_record_page.dart —— 台架页:**LiDAR 米尺录制**(bench-only ruler)
//
// ══ 🔴 口径(用户 2026-09-22 / 09-24)══════════════════════════════════════════════
// LiDAR 深度**只在台架里当研发期米尺**,用来量 XRSLAM(上架版 VIO)与 ARKit 在我们自己录制上的
// **绝对尺度误差**。永不进产品代码、产品管线、产品提案。本页只在
// `flutter build ios --profile --dart-define=PW_LIDAR_RULER_BENCH=true` 的台架包里存在
// (main.dart 的 const 分支;不带 define 的包里整页被树摇掉,装机前用 strings 核类名)。
//
// ══ 它做什么 ══════════════════════════════════════════════════════════════════════
// 一次录制 = 与 viobench-recordings/run-* 同格式的 pwvi 录制(1920×1440 luma @60 fps + IMU 100 Hz +
// ARKit 位姿 + 逐帧内参/曝光/跟踪状态),外加 ARFrame.sceneDepth 深度 + 置信度(默认每 6 帧一张 =
// 10 Hz,同一 ARFrame 同一时间戳)。落在 `Documents/replay_recordings/run-<uuid>/`,就是回放页
// (PW_BENCH_REPLAY / -PWBenchReplayRecording)读的目录 ⇒ 录完直接在手机上回放出 XRSLAM 位姿。
// 录完自动导出 `ruler_subset/`(只含带深度、间隔 ≥0.25 s 的帧,~400 MB/30 s),Mac 上只拉这个。
//
// 「扰动自测」按钮:手机**静置**,自动录 4×10 s(深度 关 / 开 / 开 / 关),每段封口后删掉帧流只留
// manifest 与 recorder_timing.json,比较两臂的 ARKit 少发帧、回调时延、写入背压与丢帧 ——
// 「开深度不扰动 VIO 流」由台架自己量,不要用户拍东西。结果写 `Documents/lidar_selftest/<时间>/`。
//
// 录法(给用户的协议)见交付报告;Mac 侧:tool/bench/pull_lidar_recording.sh + tool/bench/lidar_ruler/。
//
// 形状抄 `lib/vio/render/bench_replay_page.dart`(状态条 + 按钮 + `[bench-lidar]` 日志前缀 + Documents 落盘)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'bench_lidar_native.dart';

const String kBenchLidarLogTag = '[bench-lidar]';

class BenchLidarRecordPage extends StatefulWidget {
  const BenchLidarRecordPage({super.key});

  @override
  State<BenchLidarRecordPage> createState() => _BenchLidarRecordPageState();
}

class _BenchLidarRecordPageState extends State<BenchLidarRecordPage> {
  BenchLidarNative? _native;
  Directory? _docs;
  Map<String, Object?> _cap = const <String, Object?>{};
  Map<String, Object?> _status = const <String, Object?>{};
  String? _problem;
  double _seconds = 30;
  bool _depth = true;
  bool _selfTestRunning = false;
  Timer? _poll;
  final List<String> _log = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _note(String s) {
    debugPrint('$kBenchLidarLogTag $s');
    if (!mounted) return;
    setState(() {
      _log.add(s);
      if (_log.length > 200) _log.removeAt(0);
    });
  }

  Future<void> _init() async {
    final BenchLidarNative? n = BenchLidarNative.process();
    if (n == null) {
      setState(() => _problem = '找不到 pw_bench_lidar_* 符号(这个包没编 PwBenchLidarSession.swift)');
      return;
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final Map<String, Object?> cap = n.capability();
    _note('🔴 bench-only ruler · capability ${jsonEncode(cap)}');
    if (cap['scene_depth_supported'] != true) {
      _note('🔴 这台机器不支持 sceneDepth(没有 LiDAR)⇒ 录出来没有深度,尺子用不了');
    }
    if (!mounted) return;
    setState(() {
      _native = n;
      _docs = docs;
      _cap = cap;
    });
    _poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final BenchLidarNative? nn = _native;
      if (nn == null || !mounted) return;
      setState(() => _status = nn.status());
    });
  }

  String get _phase => (_status['phase'] as String?) ?? 'idle';
  bool get _busy =>
      _selfTestRunning ||
      const <String>{'starting', 'recording', 'stopping', 'exporting'}.contains(_phase);

  Future<Map<String, Object?>> _recordOnce({
    required double seconds,
    required bool depth,
    required String outRoot,
    required bool discardStreams,
    required String tag,
  }) async {
    final BenchLidarNative n = _native!;
    final int rc = n.start(<String, Object?>{
      'seconds': seconds,
      'depth': depth,
      'depth_stride': 6,
      'subset_spacing_s': 0.25,
      'export_subset': !discardStreams,
      'discard_streams': discardStreams,
      'out_root': outRoot,
      'tag': tag,
    });
    if (rc != 0) {
      final Map<String, Object?> st = n.status();
      _note('🔴 start rc=$rc ${st['error'] ?? ''}');
      return <String, Object?>{'rc': rc, 'error': st['error']};
    }
    _note('开录 $tag:${seconds.toStringAsFixed(0)} s,深度 ${depth ? '开' : '关'}');
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final Map<String, Object?> st = n.status();
      final String ph = (st['phase'] as String?) ?? '';
      if (ph == 'done' || ph == 'failed') {
        final Object? r = st['result'];
        _note('$tag → $ph ${st['error'] ?? ''} ${r is Map ? jsonEncode(r['manifest']) : ''}');
        return st;
      }
    }
  }

  Future<void> _startRecording() async {
    final Directory? docs = _docs;
    if (_native == null || docs == null || _busy) return;
    final String root = '${docs.path}/replay_recordings';
    await Directory(root).create(recursive: true);
    unawaited(_recordOnce(
        seconds: _seconds, depth: _depth, outRoot: root, discardStreams: false, tag: 'ruler'));
  }

  /// 扰动自测:静置,4×10 s,ABBA(关/开/开/关),删流只留计时。
  Future<void> _selfTest() async {
    final Directory? docs = _docs;
    if (_native == null || docs == null || _busy) return;
    setState(() => _selfTestRunning = true);
    final String stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(RegExp(r'[^0-9T]'), '')
        .substring(0, 15);
    final String root = '${docs.path}/lidar_selftest/$stamp';
    await Directory(root).create(recursive: true);
    _note('扰动自测开始:手机放稳别动,约 60 s。结果 → $root');
    final List<Map<String, Object?>> arms = <Map<String, Object?>>[];
    int i = 0;
    for (final bool depth in <bool>[false, true, true, false]) {
      final Map<String, Object?> st = await _recordOnce(
          seconds: 10,
          depth: depth,
          outRoot: root,
          discardStreams: true,
          tag: 'selftest_${i++}_${depth ? 'depth_on' : 'depth_off'}');
      arms.add(<String, Object?>{'depth': depth, 'status': st});
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    final Map<String, Object?> summary = _summarize(arms);
    await File('$root/ab_summary.json')
        .writeAsString(const JsonEncoder.withIndent(' ').convert(summary));
    _note('扰动自测结束:${jsonEncode(summary['verdict'])}');
    if (mounted) setState(() => _selfTestRunning = false);
  }

  static num? _dig(Object? o, List<String> path) {
    Object? cur = o;
    for (final String k in path) {
      if (cur is Map) {
        cur = cur[k];
      } else {
        return null;
      }
    }
    return cur is num ? cur : null;
  }

  /// 两臂各两段取均值。判据只报数,不替用户下结论:
  /// 丢帧(写器 loss_count)与 ARKit 少发帧必须两臂相同量级,回调时延 p99 不许明显变大。
  Map<String, Object?> _summarize(List<Map<String, Object?>> arms) {
    const List<List<String>> keys = <List<String>>[
      <String>['result', 'manifest', 'loss_count'],
      <String>['result', 'manifest', 'frame_count'],
      <String>['result', 'timing', 'arkit_frames_missed_estimate'],
      <String>['result', 'timing', 'arkit_interval_gaps_over_1_5x'],
      <String>['result', 'timing', 'callback_latency_ms', 'p99'],
      <String>['result', 'timing', 'handler_ms', 'p99'],
      <String>['result', 'timing', 'frame_write_ms', 'p99'],
      <String>['result', 'timing', 'writer', 'peak_in_flight'],
      <String>['result', 'timing', 'writer', 'depth_frames_written'],
      <String>['result', 'timing', 'writer', 'depth_dropped'],
    ];
    final Map<String, Object?> table = <String, Object?>{};
    for (final List<String> k in keys) {
      double sum(bool depth) {
        final List<num> v = arms
            .where((Map<String, Object?> a) => a['depth'] == depth)
            .map((Map<String, Object?> a) => _dig(a['status'], k))
            .whereType<num>()
            .toList();
        return v.isEmpty ? double.nan : v.fold<double>(0, (double s, num x) => s + x) / v.length;
      }

      table[k.sublist(1).join('.')] = <String, double>{'depth_off': sum(false), 'depth_on': sum(true)};
    }
    double g(String k, String arm) =>
        ((table[k] as Map<String, double>?)?[arm]) ?? double.nan;
    final bool lossSame =
        g('manifest.loss_count', 'depth_on') <= g('manifest.loss_count', 'depth_off');
    final bool missedSame = g('timing.arkit_frames_missed_estimate', 'depth_on') <=
        g('timing.arkit_frames_missed_estimate', 'depth_off') + 1;
    return <String, Object?>{
      'schema': 'pw.bench.lidar-selftest-ab/1',
      'bench_only_notice': '🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架',
      'order': 'ABBA: off, on, on, off (10 s each, phone static, streams deleted after sealing)',
      'mean_by_arm': table,
      'verdict': <String, Object?>{
        'writer_loss_not_worse_with_depth': lossSame,
        'arkit_missed_frames_not_worse_with_depth_(+1_slack)': missedSame,
      },
      'arms': arms,
    };
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, Object?> tc =
        (_status['tracking_counts'] as Map?)?.cast<String, Object?>() ?? const <String, Object?>{};
    final Object? result = _status['result'];
    return Scaffold(
      appBar: AppBar(title: const Text('LiDAR 米尺录制(台架)')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.red.withValues(alpha: 0.12),
              child: const Text(
                '🔴 bench-only ruler:LiDAR 深度只用于研发期量 XRSLAM / ARKit 的绝对尺度,'
                '永不进入产品代码、产品管线或产品方案。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            if (_problem != null) Text('🔴 $_problem'),
            Text('机型 ${_cap['device_model'] ?? '?'} · sceneDepth '
                '${_cap['scene_depth_supported'] == true ? '支持' : '不支持'} · 相机 ${_cap['camera_authorization'] ?? '?'}'
                ' · 剩余 ${((_cap['free_bytes'] as num?) ?? 0) ~/ (1 << 20)} MiB'),
            const SizedBox(height: 8),
            Row(children: <Widget>[
              const Text('时长'),
              for (final double s in <double>[15, 30, 45, 60])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: ChoiceChip(
                    label: Text('${s.toInt()} s'),
                    selected: _seconds == s,
                    onSelected: _busy ? null : (_) => setState(() => _seconds = s),
                  ),
                ),
            ]),
            SwitchListTile(
              title: const Text('录 LiDAR 深度(每 6 帧一张 = 10 Hz)'),
              value: _depth,
              onChanged: _busy ? null : (bool v) => setState(() => _depth = v),
            ),
            Row(children: <Widget>[
              ElevatedButton(
                  onPressed: _busy || _native == null ? null : _startRecording,
                  child: const Text('开始录制')),
              const SizedBox(width: 8),
              ElevatedButton(
                  onPressed: _phase == 'recording' ? () => _native?.stop() : null,
                  child: const Text('停止')),
              const SizedBox(width: 8),
              OutlinedButton(
                  onPressed: _busy || _native == null ? null : _selfTest,
                  child: const Text('扰动自测(静置)')),
            ]),
            const Divider(),
            Text('状态 $_phase · ${((_status['elapsed_s'] as num?) ?? 0).toStringAsFixed(1)} s'
                ' / ${((_status['seconds'] as num?) ?? 0).toStringAsFixed(0)} s'),
            Text('帧 ${_status['frames_accepted'] ?? '-'} · 深度 ${_status['depth_frames_written'] ?? '-'}'
                ' · 丢帧 ${_status['loss_count'] ?? '-'} · 深度丢 ${_status['depth_dropped'] ?? '-'}'
                ' · 背压峰 ${_status['peak_in_flight'] ?? '-'}/64'),
            Text('跟踪 ${tc.entries.map((MapEntry<String, Object?> e) => '${e.key}:${e.value}').join(' ')}'),
            if (_status['error'] != null) Text('🔴 ${_status['error']}'),
            if (_status['run_dir'] != null)
              SelectableText('目录 ${_status['run_dir']}', style: const TextStyle(fontSize: 11)),
            if (result is Map)
              SelectableText(const JsonEncoder.withIndent(' ').convert(<String, Object?>{
                'manifest': result['manifest'],
                'subset': (result['subset'] as Map?)?['frames'],
                'subset_error': result['subset_error'],
                'arkit_frames_missed_estimate':
                    _dig(result, <String>['timing', 'arkit_frames_missed_estimate']),
                'callback_latency_p99_ms':
                    _dig(result, <String>['timing', 'callback_latency_ms', 'p99']),
              }), style: const TextStyle(fontSize: 11)),
            const Divider(),
            for (final String l in _log.reversed.take(40))
              Text(l, style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
