import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/telemetry_writer.dart';

// ── 账本防御契约(2026-09-02)────────────────────────────────────────────
// 病根:非有限 double 是 JSON 非法值,旧降级分支 `v is num ? v : '$v'`
// 对 NaN(是 num!)原样保留 → 二次编码再抛 → 整行进空 catch 蒸发且不计数。
// build-88 会话票据 2 的三行 Dart 遥测就是这样消失的,差点误报 1:1 破裂。
// 契约:①非法数字降级为字符串,行必须活着;②任何丢失/降级必须在
// telemetry_writer_health 行里承认。
void main() {
  test('NaN/Inf 不再毒死整行 —— 行活着,值降级为字符串', () async {
    final dir = await Directory.systemTemp.createTemp('telem_defense');
    final path = '${dir.path}/t.jsonl';
    final w = TelemetryWriter.instance;
    await w.init(path);
    w.event('gate', {
      'mean': double.nan,
      'ratio': double.infinity,
      'neg': double.negativeInfinity,
      'ok': 1.5,
      'nested': {'v': double.nan, 'list': [1.0, double.nan]},
    });
    await w.flush();
    final lines = File(path)
        .readAsLinesSync()
        .where((l) => l.contains('"type":"gate"'))
        .toList();
    expect(lines, hasLength(1), reason: '含 NaN 的行必须存活(旧代码整行蒸发)');
    final m = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(m['mean'], 'NaN');
    expect(m['ratio'], 'Infinity');
    expect(m['neg'], '-Infinity');
    expect(m['ok'], 1.5);
    expect((m['nested'] as Map)['v'], 'NaN');
    expect(((m['nested'] as Map)['list'] as List)[1], 'NaN');
  });

  test('降级必须在健康行里承认', () async {
    final dir = await Directory.systemTemp.createTemp('telem_defense2');
    final path = '${dir.path}/t.jsonl';
    final w = TelemetryWriter.instance;
    await w.close(); // 单例:先关掉上一个测试的 sink,init 才会重开
    await w.init(path);
    w.event('gate2', {'bad': double.nan});
    w.event('gate2', {'fine': 1});
    await w.flush();
    final health = File(path)
        .readAsLinesSync()
        .where((l) => l.contains('"type":"telemetry_writer_health"'))
        .toList();
    expect(health, isNotEmpty, reason: '有降级就必须有健康行 —— 丢可以,必须承认');
    final h = jsonDecode(health.last) as Map<String, dynamic>;
    expect(h['degraded_values_total'], greaterThanOrEqualTo(1));
    expect(h.keys, containsAll(['dropped_total', 'sink_error']));
  });
}
