// lod_debug_page.dart — debug entry for plan L6 (on-device octree build + self-check) and
// M1 (pwlod_run), for the bench app. Branch feat/lod-viewer only — never production.
//
// What it finds: every directory directly under the app's Documents that holds a *.ply
// (official_dense.ply preferred, lod_jobs.dart findCapturePly) or an already built lod/.
// PLYs get there with `xcrun devicectl device copy to` (plan §6 M1 "数据").
//
// Detached launch (product CLAUDE.md: detached, results in the container, copy back after):
//   xcrun devicectl device process launch --terminate-existing -d <dev> com.kyle.arloopbench \
//     -- -PWLodCapture <dir under Documents> -PWLodAuto build|view|m1|build+m1 \
//        [-PWLodArgs "mode=perf frames=900 rounds=3"] [-PWLodTag t] \
//        [-PWLodThreads 4] [-PWLodBudgetMB 0] [-PWLodRebuild 1]
// -PWLodArgs / tag suffix follow pw_splat_ab_bench Sources/App.swift:103-106 (-PWLodArgs,
// default "mode=perf"). Every step is appended to Documents/lod_debug_log.txt so a run with
// nobody watching still leaves a trace; receipts: <capture>/lod_build_receipt.json and
// Documents/lod_bench/<tag>_<stamp>/m1_receipt.json.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/official_capture/lod_cloud_view.dart';
import 'lod_bridge.dart';
import 'lod_jobs.dart';

class _Capture {
  _Capture(this.dir, this.ply, this.ready, this.receipt);
  final Directory dir;
  final File? ply;
  final bool ready;
  final bool receipt;
  String get name => dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  Directory get octree => Directory('${dir.path}/$kLodDirName');
}

class LodDebugPage extends StatefulWidget {
  const LodDebugPage({super.key, this.bridge});
  final LodBridge? bridge;

  @override
  State<LodDebugPage> createState() => _LodDebugPageState();
}

class _LodDebugPageState extends State<LodDebugPage> {
  /// Launch arguments are acted on once per process, not on every rebuild of the page.
  static bool _autoStarted = false;

  late final LodBridge _bridge = widget.bridge ?? LodBridge();
  Directory? _docs;
  List<_Capture> _captures = const [];
  final List<String> _log = [];
  bool _busy = false;
  final TextEditingController _args = TextEditingController(text: 'mode=perf');

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _args.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final docs = await getApplicationDocumentsDirectory();
    if (!mounted) return;
    setState(() => _docs = docs);
    _scan();
    if (_autoStarted) return;
    _autoStarted = true;
    Map<String, String> a;
    try {
      a = await _bridge.launchArgs();
    } catch (e) {
      _say('launchArgs failed: $e');
      return;
    }
    if (a.isEmpty) return;
    _say('launch args: $a');
    final auto = a['PWLodAuto'] ?? '';
    final name = a['PWLodCapture'];
    if (auto.isEmpty || name == null) return;
    final cap = _captures.where((c) => c.name == name).toList();
    if (cap.isEmpty) {
      _say('PWLodCapture "$name" not found under ${docs.path}');
      return;
    }
    if (a['PWLodArgs'] != null) _args.text = a['PWLodArgs']!;
    final steps = auto.split('+');
    for (final step in steps) {
      if (!mounted) return;
      switch (step) {
        case 'build':
          await _build(
            cap.first,
            threads: int.tryParse(a['PWLodThreads'] ?? '') ?? 0,
            budgetMb: int.tryParse(a['PWLodBudgetMB'] ?? '') ?? 0,
            rebuild: a['PWLodRebuild'] == '1',
          );
          _scan();
        case 'm1':
          final fresh = _captures.firstWhere(
            (c) => c.name == name,
            orElse: () => cap.first,
          );
          await _m1(fresh, tag: a['PWLodTag'] ?? 'm1');
        case 'view':
          if (mounted) _view(cap.first);
        default:
          _say('unknown PWLodAuto step "$step"');
      }
    }
  }

  void _scan() {
    final docs = _docs;
    if (docs == null) return;
    final out = <_Capture>[];
    for (final e in docs.listSync(followLinks: false)) {
      if (e is! Directory || e.path.endsWith('/$kLodBenchDirName')) continue;
      final ply = findCapturePly(e);
      final ready = octreeReady(Directory('${e.path}/$kLodDirName'));
      if (ply == null && !ready) continue;
      out.add(
        _Capture(
          e,
          ply,
          ready,
          File('${e.path}/$kLodBuildReceiptName').existsSync(),
        ),
      );
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    if (mounted) setState(() => _captures = out);
  }

  void _say(String line) {
    final stamped = '${DateTime.now().toIso8601String()}  $line';
    debugPrint('[pw_lod] $stamped');
    final docs = _docs;
    if (docs != null) {
      try {
        File(
          '${docs.path}/lod_debug_log.txt',
        ).writeAsStringSync('$stamped\n', mode: FileMode.append, flush: true);
      } catch (_) {}
    }
    if (mounted) setState(() => _log.insert(0, stamped));
  }

  Future<void> _build(
    _Capture c, {
    int threads = 0,
    int budgetMb = 0,
    bool rebuild = false,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    _say(
      'build ${c.name}: ${c.ply?.path} threads=$threads budgetMB=$budgetMb rebuild=$rebuild',
    );
    try {
      final r = await buildAndVerify(
        bridge: _bridge,
        captureDir: c.dir,
        ply: c.ply,
        threads: threads,
        memoryBudgetMb: budgetMb,
        rebuild: rebuild,
      );
      for (final k in r.checks) {
        _say('  ${k.name} ${k.pass ? 'PASS' : 'FAIL'}  ${k.detail}');
      }
      _say(
        '  build ${r.build.status} ${r.build.elapsedMs.toStringAsFixed(0)} ms, '
        'peak ${r.build.peakFootprintMb.toStringAsFixed(0)} MB '
        '(baseline ${r.build.baselineFootprintMb.toStringAsFixed(0)} MB, '
        '${r.build.footprintSamples} samples) ${r.build.error}',
      );
      _say('  ${r.pass ? 'PASS' : 'FAIL'} receipt ${r.receipt.path}');
    } catch (e) {
      _say('  build error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _m1(_Capture c, {String tag = 'm1'}) async {
    final docs = _docs;
    if (_busy || docs == null) return;
    if (!octreeReady(c.octree)) {
      _say('m1 ${c.name}: no built octree in ${c.octree.path}');
      return;
    }
    setState(() => _busy = true);
    _say('m1 ${c.name}: args="${_args.text}" tag=$tag');
    try {
      final r = await runM1(
        bridge: _bridge,
        octreeDir: c.octree,
        documentsDir: docs,
        args: _args.text,
        tag: tag,
      );
      _say(
        '  pwlod_run -> ${r.result.result} (file=${r.result.resultIsFile}) '
        '${(r.result.wallMs / 1000).toStringAsFixed(1)} s, thermal '
        '${r.result.probeStart['thermal_state']}→${r.result.probeEnd['thermal_state']}',
      );
      _say('  receipt ${r.receipt.path}');
    } catch (e) {
      _say('  m1 error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _view(_Capture c) {
    if (!octreeReady(c.octree)) {
      _say('view ${c.name}: no built octree');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LodCloudPage(
          octreeDir: c.octree.path,
          title: c.name,
          bridge: _bridge,
        ),
      ),
    );
  }

  Future<void> _confirmBuild(_Capture c) async {
    if (!c.ready) return _build(c);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重建八叉树?'),
        content: Text('会删除 ${c.octree.path} 后重建。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重建'),
          ),
        ],
      ),
    );
    if (ok == true) await _build(c, rebuild: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LOD 建树 / M1'),
        actions: [
          IconButton(onPressed: _scan, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: _args,
              decoration: const InputDecoration(
                labelText: 'pwlod_run args (pw_lod_bench.cpp ParseArgs)',
                isDense: true,
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            flex: 3,
            child: ListView(
              children: [
                for (final c in _captures)
                  ListTile(
                    dense: true,
                    title: Text(c.name),
                    subtitle: Text(
                      '${c.ply != null ? c.ply!.uri.pathSegments.last : '无 PLY'}'
                      '  ${c.ready ? 'lod/ 已建' : 'lod/ 未建'}'
                      '${c.receipt ? '  有回执' : ''}',
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        if (c.ply != null)
                          TextButton(
                            onPressed: _busy ? null : () => _confirmBuild(c),
                            child: const Text('建树+自检'),
                          ),
                        TextButton(
                          onPressed: c.ready ? () => _view(c) : null,
                          child: const Text('查看'),
                        ),
                        TextButton(
                          onPressed: _busy || !c.ready ? null : () => _m1(c),
                          child: const Text('M1'),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                for (final l in _log)
                  Text(
                    l,
                    style: const TextStyle(fontSize: 11, fontFamily: 'Menlo'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
