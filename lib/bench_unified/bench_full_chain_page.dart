// bench_full_chain_page.dart — entry to the full production reconstruction chain inside arloopbench.
// Bench-only.
//
// What runs: production 168's own main() (package:pocketworld_flutter = bench/unified lib/, byte-identical
// to bench/full-chain-168-fixes) with the fixes PWOfficialSfm core linked into this package.
//
// Entering is one-way for the life of the process: production main() does runApp(PocketWorldApp) and its
// own initialisation (archive runtime, device logs, EnvFile, telemetry, dense launcher, ARKit plugin).
// Returning to the bench menu would need production code to tear that down, which it does not have and
// which this bench must not add. So: enter → production app until the app is killed; the next launch
// opens the bench menu again. `-PWBenchPage fullchain` enters directly at launch (automation).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/main.dart' as pw168;

import 'bench_core_switches_page.dart';
import 'bench_unified_native.dart';

/// Registers production's Runner plugins, then hands the whole app to production main().
/// Returns an error text, or null after production has taken over.
Future<String?> benchEnterFullChain() async {
  final bool ok;
  try {
    ok = await BenchUnifiedNative.enterFullChain();
  } catch (e) {
    return '注册生产插件失败:$e';
  }
  if (!ok) return '注册生产插件失败(AppDelegate 未装注册器)';
  unawaited(pw168.main());
  return null;
}

class BenchFullChainPage extends StatefulWidget {
  const BenchFullChainPage({super.key});

  @override
  State<BenchFullChainPage> createState() => _BenchFullChainPageState();
}

class _BenchFullChainPageState extends State<BenchFullChainPage> {
  String _env = '…';
  String _error = '';

  @override
  void initState() {
    super.initState();
    _readEnv();
  }

  Future<void> _readEnv() async {
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/official_env.json');
    String s;
    if (await f.exists()) {
      try {
        final raw = jsonDecode(await f.readAsString());
        s = raw is Map ? raw.entries.map((e) => '${e.key}=${e.value}').join('\n') : '(格式不对)';
        if (s.isEmpty) s = '(空)';
      } catch (e) {
        s = '(读不了:$e)';
      }
    } else {
      s = '(无 official_env.json = 修复版默认)';
    }
    if (mounted) setState(() => _env = s);
  }

  Future<void> _enter() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('进入完整重建链?'),
        content: const Text(
          '接下来整台 App 交给生产 168 的流程(登录门 → 拍摄 → 重建 → 我的),'
          '用的是修复核。\n\n进去之后回不到台架菜单:要回来就杀掉 App 重开。'
          '\n\n核开关只在进程第一次用到核时读一次,改开关要先杀掉 App。',
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('进入')),
        ],
      ),
    );
    if (go != true) return;
    final err = await benchEnterFullChain();
    if (err != null && mounted) setState(() => _error = err);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('完整重建链(生产原样)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            '生产 168 的 main() 原样运行(Dart 与 bench/full-chain-168-fixes 逐字节相同),'
            '链接的是修复核 PWOfficialSfm(fixA/B/C/D + DEVICE-ALIGN-V1)。\n\n'
            '台架与生产的差别(适配清单):不登记两个后台任务 ⇒ 重建时 App 要留在前台;'
            '台架没有 increased-memory-limit ⇒ 大场景可能被系统杀;Info.plist 只允许竖屏;'
            '生产插件在点「进入」时才注册,台架其他页面不受影响。',
          ),
          const SizedBox(height: 12),
          Text('当前核开关(Documents/official_env.json):\n$_env',
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 12)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: <Widget>[
            OutlinedButton(
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => const BenchCoreSwitchesPage()));
                await _readEnv();
              },
              child: const Text('核开关…'),
            ),
            FilledButton(onPressed: _enter, child: const Text('进入生产流程')),
          ]),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }
}
