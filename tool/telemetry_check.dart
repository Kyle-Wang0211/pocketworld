// telemetry_check.dart — 遥测链路的纯 Dart 断言(任务铁律④)。
//
// 运行(纯 Dart VM,repo 根目录下):
//   dart tool/telemetry_check.dart
//
// 覆盖两块:
//   1) TelemetryWriter 并发写行完整性 —— init 前 pending 补写、主 isolate
//      并发 async 写、worker isolate 经 SendPort 汇聚(与 sfm_live_recon
//      的 'telem' 路由同构)、不可 JSON 编码值降级。收尾逐行 jsonDecode,
//      任何半行/交错行都会 FAIL。
//   2) 取色统计正确性 —— 构造样本 → 代表色选择、每点观测数直方图桶
//      (obsHistBucket)、样本对代表色均方差(rmsDeviation)、分位数
//      (percentileSorted)与手算值对照。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/representative_color.dart';
import 'package:pocketworld_flutter/capture/telemetry_writer.dart';

int _failures = 0;

void check(String name, Object? actual, Object? expected) {
  final ok = actual == expected;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name'
      '${ok ? '' : '  (expected $expected, got $actual)'}');
  if (!ok) _failures++;
}

void checkNear(String name, double? actual, double expected,
    {double tol = 0.05}) {
  final ok = actual != null && (actual - expected).abs() <= tol;
  stdout.writeln('${ok ? 'PASS' : 'FAIL'}  $name'
      '${ok ? '' : '  (expected ~$expected±$tol, got $actual)'}');
  if (!ok) _failures++;
}

/// 模拟 SfM worker:向主 isolate 发 [count] 条遥测数据(与
/// sfm_live_recon.dart 的 {'evt':'telem'} 消息同构)。
void _workerMain((SendPort, int) args) {
  final (reply, count) = args;
  for (var i = 0; i < count; i++) {
    reply.send(<String, Object?>{
      'evt': 'telem',
      'type': 'worker_evt',
      'data': <String, Object?>{'i': i, 'payload': 'x' * (i % 97)},
    });
  }
  reply.send('done');
}

Future<void> _checkWriter() async {
  stdout.writeln('── TelemetryWriter 并发写行完整性 ──');
  final dir = Directory.systemTemp.createTempSync('pw_telem_check');
  final path = '${dir.path}/telemetry_dart.jsonl';
  final w = TelemetryWriter.instance;

  // 1) init 前事件进 pending,init 后补写(启动早期不丢)。
  const preInit = 5;
  for (var i = 0; i < preInit; i++) {
    w.event('pre_init', {'i': i});
  }
  await w.init(path);

  // 2) 主 isolate 并发 async 写:交错调度 + 变长 payload。
  const concurrent = 400;
  final rnd = math.Random(42);
  final futures = <Future<void>>[];
  for (var i = 0; i < concurrent; i++) {
    futures.add(
      Future<void>.delayed(Duration(microseconds: rnd.nextInt(2000)), () {
        w.event('async_evt', {
          'i': i,
          'payload': 'y' * rnd.nextInt(512),
          'nested': {'a': i, 'b': [1, 2, 3]},
        });
      }),
    );
  }

  // 3) worker isolate 经 SendPort 汇聚(单写手 —— 行完整性的关键设计)。
  const workerEvents = 200;
  final fromWorker = ReceivePort();
  final workerDone = Completer<void>();
  fromWorker.listen((msg) {
    if (msg == 'done') {
      workerDone.complete();
      fromWorker.close();
      return;
    }
    if (msg is Map && msg['evt'] == 'telem') {
      final data = msg['data'];
      w.event(msg['type'] as String? ?? 'worker', {
        'iso': 'worker',
        if (data is Map)
          ...data.map((k, v) => MapEntry(k.toString(), v as Object?)),
      });
    }
  });
  await Isolate.spawn(_workerMain, (fromWorker.sendPort, workerEvents));

  // 4) 不可 JSON 编码值降级(一条脏数据不毁链路)。
  w.event('bad_value', {'obj': Object()});

  await Future.wait(futures);
  await workerDone.future;
  await w.close();

  final lines = File(path)
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty)
      .toList();
  const expected = preInit + concurrent + workerEvents + 1;
  check('行数 = 事件数(无丢行/无并行破坏)', lines.length, expected);
  check('writtenCount 计数一致', w.writtenCount, expected);
  check('droppedCount = 0', w.droppedCount, 0);

  var parsed = 0, withTt = 0, workerSeen = 0, badOk = 0;
  final asyncSeen = <int>{};
  for (final line in lines) {
    try {
      final obj = jsonDecode(line);
      if (obj is! Map) continue;
      parsed++;
      if (obj['t'] is int && obj['type'] is String) withTt++;
      if (obj['type'] == 'worker_evt' && obj['iso'] == 'worker') workerSeen++;
      if (obj['type'] == 'async_evt') asyncSeen.add(obj['i'] as int);
      if (obj['type'] == 'bad_value' && obj['obj'] is String) badOk++;
    } catch (_) {
      // 半行/交错行 → jsonDecode 抛 → parsed 少于行数,下面 FAIL。
    }
  }
  check('每行都是完整 JSON(无半行)', parsed, expected);
  check('每行都带 t + type', withTt, expected);
  check('worker isolate 事件齐全($workerEvents)', workerSeen, workerEvents);
  check('并发 async 事件齐全($concurrent,无覆盖)',
      asyncSeen.length, concurrent);
  check('不可编码值降级为字符串仍成行', badOk, 1);
  try {
    dir.deleteSync(recursive: true);
  } catch (_) {}
}

void _checkColorStats() {
  stdout.writeln('\n── 取色统计(直方图桶 / 代表色 / 均方差 / 分位)──');

  // obsHistBucket:buckets = [1, 2, 3-4, 5-8, 9+]。
  check('bucket(1) → 0', obsHistBucket(1), 0);
  check('bucket(2) → 1', obsHistBucket(2), 1);
  check('bucket(3) → 2', obsHistBucket(3), 2);
  check('bucket(4) → 2', obsHistBucket(4), 2);
  check('bucket(5) → 3', obsHistBucket(5), 3);
  check('bucket(8) → 3', obsHistBucket(8), 3);
  check('bucket(9) → 4', obsHistBucket(9), 4);
  check('bucket(20) → 4', obsHistBucket(20), 4);

  // 样本池:点0 = 白×2 + 红×1(白床单混红观测的最小复现);
  //         点1 = 纯白×3;点2 = 单样本;点3 = 无样本。
  final samples = RepresentativeColorSamples(
    Int32List.fromList([3, 3, 1, 0]),
  );
  samples.add(0, 255, 255, 255);
  samples.add(0, 255, 0, 0);
  samples.add(0, 255, 255, 255);
  samples.add(1, 250, 250, 250);
  samples.add(1, 252, 252, 252);
  samples.add(1, 251, 251, 251);
  samples.add(2, 10, 20, 30);

  final out = Uint8List(4 * 3);
  check('点0 有样本', samples.selectInto(0, out), true);
  // 亮度:白=255,红=76.2 → 下中位数(3 个取中间)= 255 的白 → 代表色白。
  check('点0 代表色 = 真实观测(白,不平均成粉)',
      [out[0], out[1], out[2]].join(','), '255,255,255');
  // 均方差 vs 白:白样本差 0;红样本差 (0,255,255) → (0+65025+65025)/3。
  // mean = 2*0 + 43350 → /3 = 14450 → sqrt ≈ 120.21。
  checkNear('点0 rmsDeviation ≈ 120.2(混色嫌疑显著)',
      samples.rmsDeviation(0, 255, 255, 255), 120.21, tol: 0.1);

  check('点1 有样本', samples.selectInto(1, out), true);
  check('点1 代表色 = 亮度中位样本(251)',
      [out[3], out[4], out[5]].join(','), '251,251,251');
  checkNear('点1 rmsDeviation ≈ 0.8(纯色地板)',
      samples.rmsDeviation(1, 251, 251, 251), 0.816, tol: 0.05);

  check('点2 单样本 → 代表色 = 自己', samples.selectInto(2, out), true);
  check('点2 颜色', [out[6], out[7], out[8]].join(','), '10,20,30');
  check('点2 单样本 rms = 0', samples.rmsDeviation(2, 10, 20, 30), 0.0);
  check('点3 无样本 → false(调用方涂灰)', samples.selectInto(3, out), false);
  check('hitCount(0) = 3', samples.hitCount(0), 3);
  check('hitCount(3) = 0', samples.hitCount(3), 0);

  // 直方图聚合(与 _colorizeSnapshot 的循环同逻辑)。
  final hist = List<int>.filled(5, 0);
  for (var i = 0; i < 4; i++) {
    final hc = samples.hitCount(i);
    if (hc > 0) hist[obsHistBucket(hc)]++;
  }
  check('直方图 [1]桶 = 1(点2)', hist[0], 1);
  check('直方图 [3-4]桶 = 2(点0/点1)', hist[2], 2);
  check('直方图 [2]/[5-8]/[9+]桶 = 0',
      '${hist[1]},${hist[3]},${hist[4]}', '0,0,0');

  // percentileSorted。
  final sorted = List<double>.generate(101, (i) => i.toDouble());
  check('p50 of 0..100 = 50', percentileSorted(sorted, 0.50), 50.0);
  check('p90 of 0..100 = 90', percentileSorted(sorted, 0.90), 90.0);
  check('p10 of 0..100 = 10', percentileSorted(sorted, 0.10), 10.0);
  check('p0 = 首元素', percentileSorted(sorted, 0), 0.0);
  check('p100 = 末元素', percentileSorted(sorted, 1.0), 100.0);
  check('空列表 → null', percentileSorted(<double>[], 0.5), null);
  check('单元素', percentileSorted([7.0], 0.9), 7.0);
}

Future<void> main() async {
  await _checkWriter();
  _checkColorStats();
  if (_failures > 0) {
    stdout.writeln('\n$_failures assertion(s) FAILED');
    exit(1);
  }
  stdout.writeln('\nALL PASS');
}
