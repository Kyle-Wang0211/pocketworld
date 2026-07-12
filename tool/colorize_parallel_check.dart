// colorize_parallel_check.dart — colorize 解码并行化(07-12 两刀:jpegPath
// 去重 + 有界并行 3)的**逐位一致**断言脚本。纯 Dart VM 可跑(不依赖
// flutter test,此 host 跑不了):
//   cd <仓根> && dart run tool/colorize_parallel_check.dart
// 全部通过输出 "ALL PASS" 并 exit 0;任一断言失败 exit 1。
//
// 对拍基线 = 旧串行实现的逐字拷贝(逐帧 await 解码、无去重、无窗口),
// 与 lib/capture/colorize_pipeline.dart 的 sampleColorsPipelined 在同一组
// 合成帧/观测/假解码器上跑,断言:
//   ① 最终 RGB 输出逐字节一致(maxInFlight=3 与 =1 都对拍);
//   ② 每点样本数(hitCount)一致 —— 样本池状态同构;
//   ③ 顺序敏感性真检出:一批点容量压到 1(超容量静默丢弃),谁先入池
//      谁赢 —— 假解码器把靠前帧的延迟调到最大(完成序倒挂),若 consumer
//      不按帧序采样,这批点颜色必变,①立刻红;
//   ④ 去重刀:pipeline 对同一 jpegPath 只发一次解码(计数对拍),重复
//      路径/解码失败帧的帧级计数与旧语义一致;
//   ⑤ 取消哨兵:哨兵翻真后 consumer 立刻停,不再消费后续帧。
//
// 假解码器确定性:同路径 → 同尺寸同字节(LCG 按路径号播种),模拟
// native ImageIO(同文件同输出);延迟被故意倒挂以打乱完成顺序。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/colorize_pipeline.dart';
import 'package:pocketworld_flutter/capture/representative_color.dart';

int _failures = 0;

void _check(String name, bool cond, [String? detail]) {
  if (cond) {
    stdout.writeln('  ok   $name');
  } else {
    _failures++;
    stdout.writeln('  FAIL $name${detail == null ? '' : ' — $detail'}');
  }
}

/// 自带 LCG(不用 dart:math Random —— 其算法非规范保证,跨版本可能变)。
class Lcg {
  Lcg(this._s);
  int _s;
  int next() {
    _s = (_s * 1103515245 + 12345) & 0x7fffffff;
    return _s;
  }

  double nextDouble() => next() / 0x7fffffff;
}

const int kUniquePaths = 8;
const String kBadPath = 'photo#5'; // 解码失败文件(被 2 个帧引用)

String _pathOf(int id) => 'photo#$id';

/// 确定性假解码:同路径同尺寸同字节;延迟按路径号**倒挂**(靠前的帧延迟
/// 最大),制造完成序与发起序相反的最坏情况。失败路径返回 null。
class FakeDecoder {
  int calls = 0;
  final Map<String, int> perPath = {};
  void Function(int calls)? onCall; // 取消测试的钩子(第 N 次调用翻哨兵)

  Future<({Uint8List rgb, int w, int h})?> call(String path) async {
    calls++;
    perPath[path] = (perPath[path] ?? 0) + 1;
    onCall?.call(calls);
    final id = int.parse(path.split('#').last);
    // 倒挂延迟:id 越小(越早的帧)越慢 → 并行时后发先至。
    await Future<void>.delayed(Duration(milliseconds: 8 - id));
    if (path == kBadPath) return null;
    final w = 40 + (id % 3) * 4, h = 30 + (id % 2) * 6;
    final rgb = Uint8List(w * h * 3);
    final rng = Lcg(9973 * (id + 1));
    for (var i = 0; i < rgb.length; i++) {
      rgb[i] = rng.next() & 0xff;
    }
    return (rgb: rgb, w: w, h: h);
  }
}

/// 旧串行实现的逐字拷贝(改前 ar_capture_page._colorizeSnapshot 解码循环,
/// meta → job 字段名替换,无去重、逐帧 await)——对拍基线。
Future<({int decoded, int decodeFail})> serialBaseline(
  List<ColorizeFrameJob> jobs,
  RepresentativeColorSamples samples,
  ColorJpegDecoder decode,
) async {
  var decoded = 0, decodeFail = 0;
  for (final job in jobs) {
    final sj = await decode(job.jpegPath);
    if (sj == null) {
      decodeFail++;
      continue;
    }
    decoded++;
    final scaleX = sj.w / job.grayW, scaleY = sj.h / job.grayH;
    final rgbP = sj.rgb;
    final jw = sj.w, jh = sj.h;
    final tri = job.tri;
    for (var k = 0; k < tri.length; k += 3) {
      final i = tri[k].toInt();
      final fx = tri[k + 1] * scaleX - 0.5;
      final fy = tri[k + 2] * scaleY - 0.5;
      final x0 = fx.floor(), y0 = fy.floor();
      final x1 = x0 + 1, y1 = y0 + 1;
      if (x0 < 0 || y0 < 0 || x1 >= jw || y1 >= jh) continue;
      final dx = fx - x0, dy = fy - y0;
      final w00 = (1 - dx) * (1 - dy), w01 = dx * (1 - dy);
      final w10 = (1 - dx) * dy, w11 = dx * dy;
      final o00 = (y0 * jw + x0) * 3, o01 = (y0 * jw + x1) * 3;
      final o10 = (y1 * jw + x0) * 3, o11 = (y1 * jw + x1) * 3;
      samples.add(
        i,
        w00 * rgbP[o00] + w01 * rgbP[o01] + w10 * rgbP[o10] + w11 * rgbP[o11],
        w00 * rgbP[o00 + 1] +
            w01 * rgbP[o01 + 1] +
            w10 * rgbP[o10 + 1] +
            w11 * rgbP[o11 + 1],
        w00 * rgbP[o00 + 2] +
            w01 * rgbP[o01 + 2] +
            w10 * rgbP[o10 + 2] +
            w11 * rgbP[o11 + 2],
      );
    }
  }
  return (decoded: decoded, decodeFail: decodeFail);
}

/// 归约:与生产一致(selectInto,无样本涂灰 185/185/190)。
Uint8List reduceRgb(RepresentativeColorSamples samples, int n) {
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    if (!samples.selectInto(i, rgb)) {
      rgb[i * 3] = 185;
      rgb[i * 3 + 1] = 185;
      rgb[i * 3 + 2] = 190;
    }
  }
  return rgb;
}

int firstDiff(Uint8List a, Uint8List b) {
  if (a.length != b.length) return -2;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return i;
  }
  return -1;
}

void main() async {
  stdout.writeln('colorize 并行化逐位一致断言(串行基线 vs pipeline)');

  // ── 合成场景:12 帧 / 8 个独立 jpegPath(1 个被 3 帧复用、2 个被 2 帧
  // 复用,模拟槽位重拍历史)、400 点、~1500 条观测(含越界跳过)。──
  const nFrames = 12, nPoints = 400;
  // 帧 → 路径号:0..7 各自独立;8..11 复用 [1,3,5,1](path1 ×3,path3/5 ×2)。
  const framePath = [0, 1, 2, 3, 4, 5, 6, 7, 1, 3, 5, 1];
  const grayW = 80, grayH = 60;

  final rng = Lcg(20260712);
  final obsCap = Int32List(nPoints);
  final triByFrame = List<List<double>>.generate(nFrames, (_) => <double>[]);
  for (var f = 0; f < nFrames; f++) {
    final count = 110 + (f * 7) % 40;
    for (var c = 0; c < count; c++) {
      final i = rng.next() % nPoints;
      // 坐标范围略超 gray 边界 → 缩放后部分越界,覆盖 skip 分支。
      final x = rng.nextDouble() * 88.0 - 4.0;
      final y = rng.nextDouble() * 66.0 - 4.0;
      obsCap[i]++;
      triByFrame[f]
        ..add(i.toDouble())
        ..add(x)
        ..add(y);
    }
  }
  // 顺序敏感点:容量压到 1 → 谁先入池谁赢(超容量静默丢弃)。配合假解码
  // 器的倒挂延迟,consumer 乱序会让这批点变色,逐位对拍立刻红。
  for (var i = 0; i < 24; i++) {
    if (obsCap[i] > 1) obsCap[i] = 1;
  }

  final jobs = <ColorizeFrameJob>[
    for (var f = 0; f < nFrames; f++)
      ColorizeFrameJob(
        jpegPath: _pathOf(framePath[f]),
        grayW: grayW,
        grayH: grayH,
        tri: triByFrame[f],
      ),
  ];
  const failFrames = 2; // kBadPath=photo#5 被帧 5/10 引用

  // ── 基线:旧串行逐帧解码。──
  final decSerial = FakeDecoder();
  final poolSerial = RepresentativeColorSamples(Int32List.fromList(obsCap));
  final baseStats = await serialBaseline(jobs, poolSerial, decSerial.call);
  final rgbSerial = reduceRgb(poolSerial, nPoints);
  _check(
    '基线:逐帧解码次数 = 帧数($nFrames)',
    decSerial.calls == nFrames,
    'calls=${decSerial.calls}',
  );
  _check(
    '基线:decodeFail=$failFrames(坏文件被 2 帧引用,逐帧计)',
    baseStats.decodeFail == failFrames,
    'fail=${baseStats.decodeFail}',
  );

  // ── pipeline maxInFlight=3(生产配置)。──
  final decPar3 = FakeDecoder();
  final poolPar3 = RepresentativeColorSamples(Int32List.fromList(obsCap));
  final st3 = await sampleColorsPipelined(
    jobs: jobs,
    samples: poolPar3,
    decode: decPar3.call,
    maxInFlight: 3,
  );
  final rgbPar3 = reduceRgb(poolPar3, nPoints);
  final d3 = firstDiff(rgbSerial, rgbPar3);
  _check('①逐位一致:串行 vs 并行3(${rgbSerial.length} 字节)', d3 == -1,
      'first diff @byte $d3');
  var hitsEqual = true;
  for (var i = 0; i < nPoints; i++) {
    if (poolSerial.hitCount(i) != poolPar3.hitCount(i)) {
      hitsEqual = false;
      break;
    }
  }
  _check('②每点样本数一致(池状态同构)', hitsEqual);
  _check(
    '④去重:unique 解码=$kUniquePaths(串行要 $nFrames 次)',
    decPar3.calls == kUniquePaths && st3.uniqueDecodes == kUniquePaths,
    'calls=${decPar3.calls} unique=${st3.uniqueDecodes}',
  );
  var dupOnce = true;
  decPar3.perPath.forEach((p, c) {
    if (c != 1) dupOnce = false;
  });
  _check('④去重:每路径恰好解码 1 次', dupOnce, '${decPar3.perPath}');
  _check(
    '④帧级计数与旧语义一致:decoded=${baseStats.decoded} fail=$failFrames',
    st3.framesSampled == baseStats.decoded && st3.decodeFail == failFrames,
    'sampled=${st3.framesSampled} fail=${st3.decodeFail}',
  );

  // ── pipeline maxInFlight=1(退化串行)也必须逐位一致。──
  final decPar1 = FakeDecoder();
  final poolPar1 = RepresentativeColorSamples(Int32List.fromList(obsCap));
  final st1 = await sampleColorsPipelined(
    jobs: jobs,
    samples: poolPar1,
    decode: decPar1.call,
    maxInFlight: 1,
  );
  final rgbPar1 = reduceRgb(poolPar1, nPoints);
  final d1 = firstDiff(rgbSerial, rgbPar1);
  _check('①逐位一致:串行 vs 并行1(退化)', d1 == -1, 'first diff @byte $d1');
  _check(
    '并行1/并行3 计数一致',
    st1.uniqueDecodes == st3.uniqueDecodes &&
        st1.framesSampled == st3.framesSampled,
    'u=${st1.uniqueDecodes}/${st3.uniqueDecodes} '
        's=${st1.framesSampled}/${st3.framesSampled}',
  );

  // ── ⑤取消哨兵:第 3 次解码发起时翻真(窗口=3 → k=0 迭代内发完 3 个,
  // k=1 循环顶检查即停)→ 恰好消费 1 帧后返回。──
  var cancelled = false;
  final decCancel = FakeDecoder()
    ..onCall = (calls) {
      if (calls == 3) cancelled = true;
    };
  final poolCancel = RepresentativeColorSamples(Int32List.fromList(obsCap));
  final stC = await sampleColorsPipelined(
    jobs: jobs,
    samples: poolCancel,
    decode: decCancel.call,
    maxInFlight: 3,
    isCancelled: () => cancelled,
  );
  _check(
    '⑤取消哨兵:恰消费 1 帧即停(发起 ≤3 次解码)',
    stC.framesSampled == 1 && decCancel.calls == 3,
    'sampled=${stC.framesSampled} calls=${decCancel.calls}',
  );

  stdout.writeln(
    _failures == 0
        ? 'ALL PASS(串行 vs 并行 ${rgbSerial.length ~/ 3} 点逐位一致;'
              '去重 $nFrames→$kUniquePaths 次解码)'
        : '$_failures FAILURE(S)',
  );
  exit(_failures == 0 ? 0 : 1);
}
