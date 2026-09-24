// bench_replay_page.dart — 台架页:**录制回放**
//     录制(frames.bin + imu.csv + intrinsics.jsonl)→ 产品 ON 臂喂料通路 → XRSLAM
//     → TUM / 逐帧计时 / 逐帧 K 账 / 回执 落到台架容器
// 控制台 grep `[bench-replay]` 就是全部现场证据;拉回 Mac 用
// `tool/bench/pull_bench_replay_run.sh`,推录制用 `tool/bench/push_replay_recording.sh`。
//
// ══ 🔴 它**不**开摄像头、**不**开 CoreMotion ═══════════════════════════════════
// 相机帧与 IMU 全部来自 `Documents/replay_recordings/<run-…>/`。手机放着不动即可。
//   * 写多少数据:每场一个 `Documents/bench_replay_runs/replay_<录制>_<pfk-on|off>_<节拍>_<时间>/`,
//     两份 yaml + 两份 TUM + 两份 CSV + 两份 JSON,合计几百 KB。
//   * 时长:paced 档 ≥ 录制时长(约 30 s 的录制 ⇒ 30 s 起;引擎慢于实时就更久,不丢帧);
//     max 档由引擎速度决定。
//
// ══ 为什么在台架而不是生产包上跑 ══════════════════════════════════════════
// 公平 A/B 要**同一份输入**:两次实拍的内容、运动、温度都不同,不能比;同一份录制
// 开/关各回放一次才能比。台架是独立 bundle(com.kyle.arloopbench),`lib/vio/**`
// 是生产的镜像;本文件也是生产仓的文件,镜像过去,在生产里**没有任何 import 者**
// (与 `zero_arkit_capture_probe_page.dart` 同一处境)。
//
// ══ 抄的是什么,不是新发明 ═════════════════════════════════════════════════
//   * 页面骨架:`zero_arkit_capture_probe_page.dart`(状态条 + 按钮 + 日志前缀 +
//     Documents/<run> 落盘 + 拉取脚本)。
//   * 喂料:原生 `PwBenchReplay.swift` → `PwXrslamLive`(ON 臂同一条通路),
//     录制装载与节拍器从 BasaltVIOBench 搬来(见那两份 Swift 文件头)。
//   * 配置:`BenchReplayController.plan`(产品 `XrslamConfigBuilder` +
//     `CameraImuExtrinsic.forIosMachine` + `resolveCameraTimeOffset`)。
//
// ══ 脚本化(不用点屏幕)══════════════════════════════════════════════════════
//   xcrun devicectl device process launch --terminate-existing com.kyle.arloopbench -- \
//     -PWBenchReplayRecording 6e2d4b99 -PWPerFrameIntrinsics off [-PWBenchReplayPace max] …
//   有 `-PWBenchReplayRecording` ⇒ main.dart 直接进本页、默认自动开跑
//   (全部参数见 PwBenchReplay.swift 的 PwBenchReplayLaunch)。
//   `tool/bench/launch_bench_replay.sh` 把这一行包好了。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../replay/bench_replay_controller.dart';
import '../replay/bench_replay_native.dart';

/// 日志前缀。
const String kBenchReplayLogTag = '[bench-replay]';

/// main.dart 用:有 `-PWBenchReplayRecording` 启动参数就进本页。
/// 原生符号不在(旧包 / 生产包)⇒ false。
bool benchReplayRequestedByLaunchArgs() {
  final BenchReplayNative? n = BenchReplayNative.process();
  if (n == null) return false;
  return BenchReplayArgs.fromLaunchJson(n.launchArgs()).recording != null;
}

class BenchReplayPage extends StatefulWidget {
  const BenchReplayPage({super.key});

  @override
  State<BenchReplayPage> createState() => _BenchReplayPageState();
}

class _BenchReplayPageState extends State<BenchReplayPage> {
  BenchReplayController? _controller;
  BenchReplayArgs _args = const BenchReplayArgs();
  List<BenchReplayRecording> _recordings = const <BenchReplayRecording>[];
  BenchReplayRecording? _selected;
  Map<String, Object?> _status = const <String, Object?>{};
  BenchReplayResult? _result;
  String? _problem;
  bool _running = false;
  final List<String> _log = <String>[];

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  void _note(String s) {
    debugPrint('$kBenchReplayLogTag $s');
    if (!mounted) return;
    setState(() {
      _log.add(s);
      if (_log.length > 200) _log.removeAt(0);
    });
  }

  Future<void> _init() async {
    final BenchReplayNative? native = BenchReplayNative.process();
    if (native == null) {
      setState(() => _problem = '找不到 pw_bench_replay_* 符号(这个包没编 PwBenchReplay.swift)');
      _note('native missing');
      return;
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    final BenchReplayController c = BenchReplayController(native: native, documents: docs);
    final BenchReplayArgs args = c.launchArgs();
    final List<BenchReplayRecording> recs = c.listRecordings();
    _note('$kBenchReplayMarker docs=${docs.path} 录制 ${recs.length} 份 '
        '逐帧K=${args.perFrameArmLabel}(来源 ${args.perFrameIntrinsicsSource}) '
        '节拍=${args.pace} 参数问题=${args.problems}');
    for (final BenchReplayRecording r in recs) {
      _note('  ${r.describe()}');
    }
    BenchReplayRecording? pick;
    final List<String> why = <String>[];
    if (args.recording != null) {
      pick = BenchReplayController.resolve(recs, args.recording!, why: why);
      for (final String w in why) {
        _note('🔴 $w');
      }
    } else if (recs.length == 1) {
      pick = recs.single;
    }
    if (!mounted) return;
    setState(() {
      _controller = c;
      _args = args;
      _recordings = recs;
      _selected = pick;
      if (why.isNotEmpty) _problem = why.join(';');
    });
    if (args.autoStart && pick != null) {
      _note('启动参数要求自动开跑:${pick.dirName}');
      await _start();
    }
  }

  Future<void> _start() async {
    final BenchReplayController? c = _controller;
    final BenchReplayRecording? r = _selected;
    if (c == null || r == null || _running) return;
    setState(() {
      _running = true;
      _result = null;
      _problem = null;
    });
    try {
      final BenchReplayPlan plan = c.plan(r, _args);
      _note('开跑 ${plan.runDir.path}  ${plan.cameraTimeOffset.describe}  '
          '外参=${plan.builder.extrinsic.provenance.name}');
      int lastLogged = -1;
      final BenchReplayResult res = await c.run(plan, onStatus: (Map<String, Object?> s) {
        if (!mounted) return;
        setState(() => _status = s);
        final int offered = (s['camera_offered'] as num?)?.toInt() ?? 0;
        if (offered ~/ 300 != lastLogged) {
          lastLogged = offered ~/ 300;
          _note('phase=${s['phase']} 帧 $offered/${s['camera_total']} '
              '已算 ${s['observations']} 用时 ${(s['elapsed_s'] as num?)?.toStringAsFixed(1)}s');
        }
      });
      final Map<String, Object?> inv =
          (res.receipt['invariants'] as Map<String, Object?>?) ?? const <String, Object?>{};
      _note('结束 ok=${res.ok} phase=${res.receipt['phase']} '
          'invariants=${inv['passed']} ${inv['failed']} error=${res.error ?? "-"}');
      _note('回执 ${res.receiptPath}');
      final Object? outs = res.receipt['outputs'];
      if (outs is Map<String, Object?>) {
        outs.forEach((String k, Object? v) {
          _note('  $k rows=${(v as Map<String, Object?>?)?['rows']}');
        });
      }
      if (mounted) setState(() => _result = res);
    } catch (e) {
      _note('🔴 $e');
      if (mounted) setState(() => _problem = '$e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle mono = const TextStyle(fontFamily: 'Menlo', fontSize: 11);
    return Scaffold(
      appBar: AppBar(title: const Text('Bench Replay · $kBenchReplayMarker')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: <Widget>[
            if (_problem != null)
              Text('🔴 $_problem', style: const TextStyle(color: Colors.red)),
            Text('逐帧 K:${_args.perFrameArmLabel}'
                '(-PWPerFrameIntrinsics,来源 ${_args.perFrameIntrinsicsSource};'
                '进程级开关,换臂要带参数重启)'),
            Row(children: <Widget>[
              const Text('节拍 '),
              DropdownButton<String>(
                value: _args.pace,
                items: kBenchReplayPaces
                    .map((String p) => DropdownMenuItem<String>(value: p, child: Text(p)))
                    .toList(),
                onChanged: _running
                    ? null
                    : (String? v) {
                        if (v != null) setState(() => _args = _args.copyWith(pace: v));
                      },
              ),
            ]),
            CheckboxListTile(
              dense: true,
              title: const Text('有损录制也回放(回执里标出 loss_count)'),
              value: _args.allowLossy,
              onChanged: _running
                  ? null
                  : (bool? v) => setState(() => _args = _args.copyWith(allowLossy: v)),
            ),
            CheckboxListTile(
              dense: true,
              title: const Text('忽略录制的 exposure_s(按 0 推)'),
              value: _args.ignoreExposure,
              onChanged: _running
                  ? null
                  : (bool? v) =>
                      setState(() => _args = _args.copyWith(ignoreExposure: v)),
            ),
            const Divider(),
            Text('录制(Documents/$kBenchReplayRecordingsDir/):${_recordings.length} 份'),
            for (final BenchReplayRecording r in _recordings)
              ListTile(
                dense: true,
                leading: Icon(_selected?.dirName == r.dirName
                    ? Icons.check_circle
                    : Icons.circle_outlined),
                enabled: !_running && r.ok,
                onTap: () => setState(() => _selected = r),
                title: Text(r.describe(), style: mono),
              ),
            ElevatedButton(
              onPressed: _running || _selected == null ? null : _start,
              child: Text(_running ? '回放中…' : '开始回放'),
            ),
            if (_status.isNotEmpty)
              Text('phase=${_status['phase']} 帧 ${_status['camera_offered']}/'
                  '${_status['camera_total']} 已算 ${_status['observations']} '
                  '${(_status['elapsed_s'] as num?)?.toStringAsFixed(1)}s',
                  style: mono),
            if (_result != null)
              Text('结果 ok=${_result!.ok}  ${_result!.runDir.path}', style: mono),
            const Divider(),
            for (final String l in _log.reversed.take(60)) Text(l, style: mono),
          ],
        ),
      ),
    );
  }
}
