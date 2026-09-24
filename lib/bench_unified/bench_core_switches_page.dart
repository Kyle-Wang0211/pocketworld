// bench_core_switches_page.dart — runtime kill switches of the fixes core used by the full
// reconstruction chain in arloopbench. Bench-only.
//
// Mechanism = production's own: production main() applies Documents/official_env.json
// (AetherEnvFile.applyFrom, lib/official_aether_sfm_ffi.dart) with setenv before any capture or
// native call, and logs "EnvFile applied: [...]" to Documents/pw_device_log.txt. This page only
// edits that file. The core reads each switch once per process (`static const bool cached = getenv(...)`),
// and entering the full chain takes over the app until it is killed, so a change applies to the next
// time the full chain is entered after a fresh app start.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// One env switch of the fixes core.
class CoreSwitch {
  const CoreSwitch({
    required this.key,
    required this.title,
    required this.detail,
    required this.onValue,
    required this.defaultOn,
  });

  final String key;
  final String title;
  final String detail;

  /// Value written when the switch is in its non-default state.
  final String onValue;

  /// State when the key is absent (the fixes core's default).
  final bool defaultOn;
}

const List<CoreSwitch> kCoreSwitches = <CoreSwitch>[
  CoreSwitch(
    key: 'OFFICIAL_AETHER_DEVICE_ALIGN_V1',
    title: '交付尺度对齐 DEVICE-ALIGN-V1(核内 Sim3 + 闸)',
    detail: '默认开。关 = 写 "0"(核把此步报 disabled,交付模型回到改动前行为)。',
    onValue: '0',
    defaultOn: true,
  ),
  CoreSwitch(
    key: 'OFFICIAL_AETHER_REG_EVIDENCE',
    title: '注册证据门 REG-EVIDENCE(臂 a)',
    detail: '默认关。开 = 写 "1"(可信帧也要过上游 RegisterNextImage 的证据门)。',
    onValue: '1',
    defaultOn: false,
  ),
  CoreSwitch(
    key: 'OFFICIAL_AETHER_FINALIZE_VIA_RESUME',
    title: 'finalize 走 resume(臂 b)',
    detail: '默认关。开 = 写 "1"。',
    onValue: '1',
    defaultOn: false,
  ),
  CoreSwitch(
    key: 'OFFICIAL_AETHER_GSS_FUSED',
    title: 'SIFT 高斯模糊用融合核(168 基线行为)',
    detail: '默认关 = 上游两遍模糊(fixD)。开 = 写 "1",回到 168 的融合核。',
    onValue: '1',
    defaultOn: false,
  ),
];

/// Fixes in the core/Dart that have no runtime switch (shown on the page, kept here for review).
const List<String> kFixesWithoutSwitch = <String>[
  'fixA 逐帧 devicePoseTrusted + 自动快门追踪闸(Dart;只有 ARKit normal 帧当可信)',
  'fixB 设备跟踪会话切分 deviceSessionId(Dart;只信参考会话,落 official_device_sessions.jsonl)',
  'C-dart 删掉静默失效的 Dart SCALE-ANCHOR(交付尺度只由核内 DEVICE-ALIGN-V1 做)',
  'fixC 产品侧 v2 喂帧入口 pwofficial_add_jpeg_frame_v2(带信任位;框架有 v2 符号就走 v2)',
  'fixC 核:不可信帧不进 Sim3 配对、位姿库 bit0、不可信帧走上游 RegisterNextImage(与臂 a/b 开关无关的部分)',
];

class BenchCoreSwitchesPage extends StatefulWidget {
  const BenchCoreSwitchesPage({super.key});

  @override
  State<BenchCoreSwitchesPage> createState() => _BenchCoreSwitchesPageState();
}

class _BenchCoreSwitchesPageState extends State<BenchCoreSwitchesPage> {
  File? _file;
  Map<String, Object?> _env = <String, Object?>{};
  String _note = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final docs = await getApplicationDocumentsDirectory();
    final f = File('${docs.path}/official_env.json');
    Map<String, Object?> env = <String, Object?>{};
    String note = '';
    if (await f.exists()) {
      try {
        final raw = jsonDecode(await f.readAsString());
        if (raw is Map<String, dynamic>) env = Map<String, Object?>.from(raw);
      } catch (e) {
        note = 'official_env.json 读不了($e);保存会覆盖它';
      }
    }
    if (!mounted) return;
    setState(() {
      _file = f;
      _env = env;
      _note = note;
    });
  }

  bool _isOn(CoreSwitch s) {
    final v = _env[s.key];
    if (v is! String || v.isEmpty) return s.defaultOn;
    return s.defaultOn ? v != s.onValue && v != 'off' : v == s.onValue;
  }

  void _set(CoreSwitch s, bool on) {
    setState(() {
      if (on == s.defaultOn) {
        _env.remove(s.key);
      } else {
        _env[s.key] = s.onValue;
      }
    });
  }

  void _preset({required bool baselineLike}) {
    setState(() {
      for (final s in kCoreSwitches) {
        _env.remove(s.key);
      }
      if (baselineLike) {
        _env['OFFICIAL_AETHER_DEVICE_ALIGN_V1'] = '0';
        _env['OFFICIAL_AETHER_GSS_FUSED'] = '1';
      }
    });
  }

  Future<void> _save() async {
    final f = _file;
    if (f == null) return;
    if (_env.isEmpty) {
      if (await f.exists()) await f.delete();
    } else {
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(_env));
    }
    if (!mounted) return;
    setState(() => _note = '已保存。杀掉 App 重开后,再进「完整重建链」时生效。');
  }

  @override
  Widget build(BuildContext context) {
    final others = _env.keys.where((k) => !kCoreSwitches.any((s) => s.key == k)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('完整链核开关')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: <Widget>[
          const Text(
            '写 Documents/official_env.json,由生产 main() 在任何拍摄/进原生之前 setenv'
            '(生产自带机制,日志 pw_device_log.txt 里有 EnvFile applied)。核对每个开关每个进程只读一次;'
            '进入完整链后直到杀掉 App 都由生产流程接管 ⇒ 改完要杀掉 App 重开再进。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          for (final s in kCoreSwitches)
            SwitchListTile(
              title: Text(s.title),
              subtitle: Text('${s.key}\n${s.detail}'),
              isThreeLine: true,
              value: _isOn(s),
              onChanged: (v) => _set(s, v),
            ),
          Wrap(spacing: 8, children: <Widget>[
            OutlinedButton(
              onPressed: () => _preset(baselineLike: false),
              child: const Text('修复版默认(全删)'),
            ),
            OutlinedButton(
              onPressed: () => _preset(baselineLike: true),
              child: const Text('尽量接近 168 基线'),
            ),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ]),
          if (_note.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note)),
          if (others.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text('文件里其他键(原样保留):${others.map((k) => '$k=${_env[k]}').join(', ')}',
                style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 16),
          const Text('没有运行期开关的修复(「接近基线」也关不掉它们):',
              style: TextStyle(fontWeight: FontWeight.bold)),
          for (final s in kFixesWithoutSwitch)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('• $s', style: const TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 12),
          Text('当前文件内容:\n${_env.isEmpty ? '(无文件 = 修复版默认)' : const JsonEncoder.withIndent('  ').convert(_env)}',
              style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
        ],
      ),
    );
  }
}
