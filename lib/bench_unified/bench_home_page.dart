// bench_home_page.dart — arloopbench home menu: one installed bench package, every bench function.
// Bench-only. The entry list is built by arloopbench's own lib/main.dart (it owns the imports of
// every page); this file only lays the list out and routes launch arguments.
//
// Launch arguments (xcrun devicectl device process launch … com.kyle.arloopbench -- <args>):
//   -PWBenchPage <id>              open one entry directly (ids are listed on each menu row)
//   -PWBenchReplayRecording <run>  → 'replay'   (BenchReplayPage reads the rest of its -PWBenchReplay* args)
//   -PWLodCapture / -PWLodAuto     → 'lod'      (LodDebugPage reads its -PWLod* args)
//   -PWMode <splat|points|cloud|lod|lodverify>  → 'splat-ab' (old PWSplatAB automation; auto-runs)
//   -PWAutoRun <mode>              → 'viobench' (old VIO Replacement Bench automation; auto-runs)
// Routing happens once per process.

import 'dart:async';

import 'package:flutter/material.dart';

import 'bench_unified_native.dart';

/// One bench function in the menu.
class BenchEntry {
  const BenchEntry({
    required this.id,
    required this.group,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.page,
    this.action,
  }) : assert(page != null || action != null);

  /// Stable id for `-PWBenchPage <id>`.
  final String id;
  final String group;
  final String title;
  final String subtitle;
  final IconData icon;

  /// A Flutter page pushed on the navigator …
  final Widget Function()? page;

  /// … or an action (native screen, takeover of the whole app).
  final Future<void> Function(BuildContext context)? action;
}

/// Picks the entry id the launch arguments ask for, or null for the plain menu.
String? benchEntryIdFromLaunchArgs(Map<String, String> a) {
  final page = a['PWBenchPage'];
  if (page != null && page.isNotEmpty) return page;
  if ((a['PWBenchReplayRecording'] ?? '').isNotEmpty) return 'replay';
  if (a.containsKey('PWLodAuto') || a.containsKey('PWLodCapture')) return 'lod';
  if (a.containsKey('PWMode')) return 'splat-ab';
  if (a.containsKey('PWAutoRun')) return 'viobench';
  return null;
}

class BenchHomePage extends StatefulWidget {
  const BenchHomePage({super.key, required this.entries, this.footer});

  final List<BenchEntry> entries;
  final String? footer;

  @override
  State<BenchHomePage> createState() => _BenchHomePageState();
}

class _BenchHomePageState extends State<BenchHomePage> {
  static bool _routed = false;
  String _launchNote = '';

  @override
  void initState() {
    super.initState();
    unawaited(_routeLaunchArgs());
  }

  Future<void> _routeLaunchArgs() async {
    if (_routed) return;
    _routed = true;
    final a = await BenchUnifiedNative.launchArgs();
    final id = benchEntryIdFromLaunchArgs(a);
    if (id == null || !mounted) return;
    final matches = widget.entries.where((e) => e.id == id).toList();
    if (matches.isEmpty) {
      setState(() => _launchNote = '启动参数要打开「$id」,但菜单里没有这个 id');
      return;
    }
    setState(() => _launchNote = '按启动参数打开:$id');
    // Let the menu finish its first frame before pushing on top of it.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    await open(matches.first);
  }

  Future<void> open(BenchEntry e) async {
    final page = e.page;
    if (page != null) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page()));
      return;
    }
    await e.action!(context);
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<BenchEntry>>{};
    for (final e in widget.entries) {
      groups.putIfAbsent(e.group, () => <BenchEntry>[]).add(e);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('AR Loop Bench · 台架菜单')),
      body: ListView(
        children: <Widget>[
          if (_launchNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(_launchNote, style: const TextStyle(fontSize: 12)),
            ),
          for (final g in groups.entries) ...<Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(g.key,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      )),
            ),
            for (final e in g.value)
              ListTile(
                leading: Icon(e.icon),
                title: Text(e.title),
                subtitle: Text('${e.subtitle}\nid: ${e.id}'),
                isThreeLine: true,
                trailing: const Icon(Icons.chevron_right),
                onTap: () => open(e),
              ),
          ],
          if (widget.footer != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(widget.footer!,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ),
        ],
      ),
    );
  }
}
