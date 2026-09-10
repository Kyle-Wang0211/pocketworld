// ref_keyfrm 全比扫描的**成本曲线**。
//
// 用户 2026-09-10 拍板走 (a):"全比、接受随张数增长的开销,先达到效果,然后
// 去做优化提速+降本(在复刻的同时都开始想)"。这个文件就是那笔账 —— 优化
// 之前先有数,免得又变成"感觉慢"。
//
// 它不是判据、不设阈值(阈值要有出处),只把 N 张参考下的单次扫描耗时打出来。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';

Uint8List _trackGray(int shiftX) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sx = x - shiftX;
      var h = (sx * 73856093) ^ (y * 19349663);
      h = (h ^ (h >> 13)) * 1274126177;
      final coarse =
          ((((sx >> 3) * 2654435761) ^ ((y >> 3) * 40503)) >> 7) & 0xff;
      out[y * side + x] = ((coarse * 3 + (h & 0xff)) >> 2).clamp(0, 255);
    }
  }
  return out;
}

void main() {
  test('ref_keyfrm 全比扫描的成本曲线(N 张参考 → 单次扫描耗时)', () {
    final refs = <CapturedViewReference>[];
    final report = StringBuffer('\n  N\t单次扫描\t每张\n');
    var seeds = 0;
    for (final n in <int>[1, 8, 35, 100, 300]) {
      while (refs.length < n) {
        final r = CapturedViewReference.build(
          gray: _trackGray(refs.length * 7 + 3),
          width: 128,
          height: 128,
        );
        expect(r, isNotNull, reason: '参考建不出来,基准就无从谈起');
        seeds = math.max(seeds, r!.seedTrackCount);
        refs.add(r);
      }
      final matcher = CurrentViewMatcher.build(
        gray: _trackGray(11),
        width: 128,
        height: 128,
      )!;
      // 先跑一遍热身(JIT),再取三次的中位。
      selectReferenceKeyframe(matcher: matcher, references: refs);
      final runs = <int>[
        for (var i = 0; i < 3; i++)
          selectReferenceKeyframe(
            matcher: matcher,
            references: refs,
          ).scanMicros,
      ]..sort();
      final us = runs[1];
      report.writeln(
        '  $n\t${(us / 1000).toStringAsFixed(1)} ms'
        '\t${(us / n / 1000).toStringAsFixed(3)} ms',
      );
    }
    report.writeln(
      '  (每张参考的种子角点上限 $seeds;'
      '生产判决按 QUALITY_HZ=6 走 ⇒ 每秒 6 次扫描)',
    );
    // ignore: avoid_print
    print(report.toString());
    expect(refs.length, 300);
  });
}
