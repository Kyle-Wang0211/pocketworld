// splat_ab_page.dart — the PWSplatAB benches inside arloopbench (bench-only).
//
// Native side: ios/Runner/PwSplatABRunner.swift (App.swift Runner.go() of pw_splat_ab_bench @ b792d57)
// + PwSplatAB/{bench,bench_points,bench_cloud}.mm verbatim. Same inputs and outputs as PWSplatAB:
//   inputs   Documents/cloud.bin (cloud mode), Documents/lod/<oct>/ (lod / lodverify)
//   outputs  Documents/SplatAB/splat_ab.json | points.json | cloud.json | lod_<tag>.json | lod_verify_<oct>_<tag>.json
// Old automation keeps working with only the bundle id changed:
//   xcrun devicectl device process launch --terminate-existing … com.kyle.arloopbench -- -PWMode points -PWCell 2 -PWTag x
// (the menu routes -PWMode here and this page starts the run once per process).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../bench_unified/bench_unified_native.dart';

const List<String> kSplatModes = <String>['splat', 'points', 'cloud', 'lodverify', 'lod'];

/// Parameter keys (= PWSplatAB launch-argument names without the dash) and PWSplatAB's defaults.
const Map<String, String> kSplatDefaults = <String, String>{
  'PWK': '100',
  'PWR': '6',
  'PWWarm': '30',
  'PWTag': '',
  'PWCell': '-1',
  'PWRad': '15',
  'PWCam': '0',
  'PWArms': '63',
  'PWCloud': 'cloud.bin',
  'PWOct': 'oct_prod',
  'PWLodArgs': 'mode=perf',
};

const Map<String, String> kSplatHelp = <String, String>{
  'PWK': '每块帧数',
  'PWR': '轮数(A/B 交替)',
  'PWWarm': '每臂预热帧数',
  'PWTag': '结果标签(points/cloud/lod 写进 json)',
  'PWCell': 'points:-1 全跑 / 0=1M / 1=4M / 2=6.92M',
  'PWRad': '半径,0.1 px 为单位',
  'PWCam': 'cloud:0 拟合 / 1 拟合÷4 / 2 对角线÷4',
  'PWArms': 'cloud 臂位掩码 RN,RM,RM2,RR,UM,UR',
  'PWCloud': 'cloud:Documents 下的输入文件',
  'PWOct': 'lod / lodverify:Documents/lod/<名字>',
  'PWLodArgs': 'lod:传给 pwlod_run 的参数串',
};

class SplatAbPage extends StatefulWidget {
  const SplatAbPage({super.key});

  @override
  State<SplatAbPage> createState() => _SplatAbPageState();
}

class _SplatAbPageState extends State<SplatAbPage> {
  static bool _autoStarted = false;

  String _mode = 'splat';
  final Map<String, TextEditingController> _c = <String, TextEditingController>{
    for (final e in kSplatDefaults.entries) e.key: TextEditingController(text: e.value),
  };
  Map<String, Object?> _status = const <String, Object?>{};
  Timer? _poll;
  Directory? _docs;
  List<FileSystemEntity> _results = const <FileSystemEntity>[];
  String _preview = '';
  String _inputs = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    _docs = docs;
    await _refresh();
    if (_autoStarted) return;
    _autoStarted = true;
    final a = await BenchUnifiedNative.launchArgs();
    final mode = a['PWMode'];
    if (mode == null || !mounted) return;
    setState(() {
      _mode = mode;
      for (final k in kSplatDefaults.keys) {
        final v = a[k];
        if (v != null) _c[k]!.text = v;
      }
    });
    await _run();
  }

  Future<void> _refresh() async {
    final docs = _docs;
    if (docs == null) return;
    final dir = Directory('${docs.path}/SplatAB');
    final list = await dir.exists()
        ? (await dir.list().toList()).whereType<File>().toList()
        : <File>[];
    list.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    final cloud = File('${docs.path}/${_c['PWCloud']!.text}');
    final lod = Directory('${docs.path}/lod');
    final octs = await lod.exists()
        ? (await lod.list().toList()).whereType<Directory>().map((d) => d.path.split('/').last).join(', ')
        : '';
    final st = await BenchUnifiedNative.splatStatus();
    if (!mounted) return;
    setState(() {
      _results = list;
      _status = st;
      _inputs = 'cloud 输入 ${cloud.path.split('/').last}:'
          '${cloud.existsSync() ? '${(cloud.lengthSync() / 1048576).toStringAsFixed(1)} MiB' : '没有'};'
          'Documents/lod/:${octs.isEmpty ? '没有' : octs}';
    });
  }

  Future<void> _run() async {
    final p = <String, String>{'PWMode': _mode};
    for (final e in _c.entries) {
      p[e.key] = e.value.text;
    }
    final ok = await BenchUnifiedNative.splatStart(p);
    if (!ok) {
      if (mounted) setState(() => _preview = '已有一次在跑,等它结束');
      return;
    }
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) async {
      await _refresh();
      if (_status['running'] != true) _poll?.cancel();
    });
    await _refresh();
  }

  Future<void> _show(File f) async {
    final s = await f.readAsString();
    if (mounted) setState(() => _preview = s.length > 6000 ? '${s.substring(0, 6000)}\n…(截断)' : s);
  }

  @override
  Widget build(BuildContext context) {
    final running = _status['running'] == true;
    return Scaffold(
      appBar: AppBar(title: const Text('泼溅 A/B(PWSplatAB)')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          const Text(
            '离屏 1179×2556 WebGPU(Dawn)台架:splat = 实例化 draw(6,N) vs 顶点展开 draw(6N,1);'
            'points = 裸点;cloud = 真实点云透视;lod / lodverify = LOD 台架与八叉树 sha。'
            '结果落 Documents/SplatAB/(同名文件每次覆盖)。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Text(_inputs, style: const TextStyle(fontSize: 12)),
          DropdownButton<String>(
            value: kSplatModes.contains(_mode) ? _mode : 'splat',
            items: <DropdownMenuItem<String>>[
              for (final m in kSplatModes) DropdownMenuItem<String>(value: m, child: Text('模式 $m')),
            ],
            onChanged: running ? null : (v) => setState(() => _mode = v ?? 'splat'),
          ),
          for (final k in kSplatDefaults.keys)
            TextField(
              controller: _c[k],
              enabled: !running,
              decoration: InputDecoration(labelText: '-$k  ${kSplatHelp[k] ?? ''}', isDense: true),
            ),
          const SizedBox(height: 8),
          Row(children: <Widget>[
            FilledButton(onPressed: running ? null : _run, child: const Text('开始')),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _refresh, child: const Text('刷新')),
          ]),
          const SizedBox(height: 8),
          Text('状态:${_status['status'] ?? '-'}',
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
          const Divider(),
          const Text('Documents/SplatAB/ 结果(点开看内容):'),
          for (final f in _results.whereType<File>())
            ListTile(
              dense: true,
              title: Text(f.path.split('/').last),
              subtitle: Text('${f.lengthSync()} B · ${f.statSync().modified}'),
              onTap: () => _show(f),
            ),
          if (_preview.isNotEmpty)
            SelectableText(_preview, style: const TextStyle(fontFamily: 'Menlo', fontSize: 10)),
        ],
      ),
    );
  }
}
