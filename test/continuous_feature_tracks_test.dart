import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';

Uint8List _texturedFrame({int shiftX = 0}) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sx = x - shiftX;
      if (sx < 0 || sx >= side) continue;
      final checker = (((sx ~/ 8) + (y ~/ 8)) & 1) == 0 ? 35 : 220;
      final detail = ((sx * 17 + y * 29 + (sx * y) % 31) & 31) - 15;
      out[y * side + x] = (checker + detail).clamp(0, 255);
    }
  }
  return out;
}

void main() {
  _meanNotMedianContract();
  _openCvLkSemanticsContract();

  test('continuous LK carries capture tracks across small frame steps', () {
    final tracks = ContinuousFeatureTracks();
    tracks.setReference(gray: _texturedFrame(), width: 128, height: 128);

    FrameTrackEvidence? evidence;
    for (var shift = 1; shift <= 12; shift++) {
      evidence = tracks.advance(
        gray: _texturedFrame(shiftX: shift),
        width: 128,
        height: 128,
        focalXPixels: 128,
        focalYPixels: 128,
      );
    }

    expect(evidence, isNotNull);
    expect(evidence!.commonTrackCount, greaterThanOrEqualTo(20));
    expect(evidence.medianPixelDisplacement, closeTo(12, 1.5));
    expect(evidence.hasEnoughNovelty, isTrue);
  });

  test('VINS track loss is not a consumer shutter authorization', () {
    const evidence = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 19,
      commonTrackFraction: 19 / 114,
      medianPixelDisplacement: 26.8,
      medianNormalizedDisplacement: 0.21,
      meanNormalizedDisplacement: 0.21,
    );

    expect(evidence.comparable, isFalse);
    expect(evidence.lostTrackedOverlap, isTrue);
    expect(evidence.isKeyframeCandidate, isFalse);
  });

  test('featureless frames do not masquerade as track-loss keyframes', () {
    const evidence = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      meanNormalizedDisplacement: double.nan,
    );

    expect(evidence.lostTrackedOverlap, isFalse);
    expect(evidence.isKeyframeCandidate, isFalse);
  });

  test('official-normalized LK evidence rejects a one-pixel duplicate', () {
    final evidence = trackFrameNovelty(
      previousGray: _texturedFrame(),
      currentGray: _texturedFrame(shiftX: 1),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
    );

    expect(evidence.comparable, isTrue);
    expect(evidence.commonTrackCount, greaterThanOrEqualTo(20));
    expect(evidence.commonTrackFraction, greaterThan(0.4));
    expect(evidence.medianNormalizedDisplacement, lessThan(10 / 460));
    expect(evidence.hasEnoughNovelty, isFalse);
  });

  test('official-normalized LK evidence admits a four-pixel new view', () {
    final evidence = trackFrameNovelty(
      previousGray: _texturedFrame(),
      currentGray: _texturedFrame(shiftX: 4),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
    );

    expect(evidence.comparable, isTrue);
    expect(evidence.commonTrackCount, greaterThanOrEqualTo(20));
    expect(
      evidence.medianNormalizedDisplacement,
      greaterThanOrEqualTo(10 / 460),
    );
    expect(evidence.hasEnoughNovelty, isTrue);
  });

  test('flat frames are explicitly incomparable rather than guessed new', () {
    final evidence = trackFrameNovelty(
      previousGray: Uint8List(128 * 128)..fillRange(0, 128 * 128, 128),
      currentGray: Uint8List(128 * 128)..fillRange(0, 128 * 128, 128),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
    );

    expect(evidence.comparable, isFalse);
    expect(evidence.commonTrackCount, 0);
    expect(evidence.hasEnoughNovelty, isFalse);
  });

  test('128x128 tracking stays below one 6 Hz quality period on host', () {
    final watch = Stopwatch()..start();
    for (var i = 0; i < 3; i++) {
      trackFrameNovelty(
        previousGray: _texturedFrame(),
        currentGray: _texturedFrame(shiftX: 4),
        width: 128,
        height: 128,
        focalXPixels: 128,
        focalYPixels: 128,
      );
    }
    watch.stop();
    expect(watch.elapsedMilliseconds / 3, lessThan(100));
  });
}

// ── 复刻:判决用均值,不是中位数 ─────────────────────────────────────────
// VINS-Mono feature_manager.cpp,addFeatureCheckParallax 逐字:
//     parallax_sum += compensatedParallax2(it_per_id, frame_count);
//     parallax_num++;
//     ...
//     return parallax_sum / parallax_num >= MIN_PARALLAX;
// 是算术均值。2026-09-01 之前我们用中位数 —— 那是自研,没有任何上游这么做,
// 代码里也没写理由。用户:「其他同行都没做这个算法,轮得到咱们自研?」
void _meanNotMedianContract() {
  test('新颖度判决用均值(上游口径),中位数只作证据', () {
    // 少数大位移把均值拽过线,拽不动中位数 —— 两者唯一会分歧的形状。
    // 90 个 0.01 + 10 个 0.15:均值 0.024 > 10/460;中位 0.01 < 10/460。
    const bar = kOfficialNormalizedTrackDisplacement; // 10/460 ≈ 0.02174
    final many = List<double>.filled(90, 0.01);
    final few = List<double>.filled(10, 0.15);
    final all = [...many, ...few];
    final mean = all.reduce((a, b) => a + b) / all.length;
    final sorted = [...all]..sort();
    final median = (sorted[49] + sorted[50]) / 2;
    expect(mean, greaterThan(bar));
    expect(median, lessThan(bar));

    final evidence = FrameTrackEvidence(
      seedTrackCount: 100,
      commonTrackCount: 100,
      commonTrackFraction: 1,
      medianPixelDisplacement: 5,
      medianNormalizedDisplacement: median,
      meanNormalizedDisplacement: mean,
    );
    expect(evidence.hasEnoughNovelty, isTrue, reason: '上游按均值判决;中位数低于阈值不得推翻它');

    // 反向:均值低于阈值时不得开火,哪怕中位数高。
    final inverted = FrameTrackEvidence(
      seedTrackCount: 100,
      commonTrackCount: 100,
      commonTrackFraction: 1,
      medianPixelDisplacement: 5,
      medianNormalizedDisplacement: 0.9,
      meanNormalizedDisplacement: 0.001,
    );
    expect(inverted.hasEnoughNovelty, isFalse);
  });
}

// ── 复刻:OpenCV lkpyramid.cpp 的边界与终止语义(2026-09-02 回源)────────
// 四处对齐:REFLECT_101 采样(金字塔按 winSize 填充的等价);「界外」只指
// 完全飞出填充区;边界/退化只在第 0 层判死(粗层 continue);无位移上限;
// ε 比的是平方范数(0.01,即 |δ|≤0.1)+ 振荡早停退半步。
// 修复前:1px 平移在真实照片上存活率只有 60%(该是 ~100%),主凶是顶层
// 32×32 的窗口检查把离边 20px 内的角点全部误杀(可跟踪面积 47%)。
void _openCvLkSemanticsContract() {
  test('1px 平移:存活率必须接近满分(修复前 ~50%)', () {
    final t = ContinuousFeatureTracks();
    t.setReference(gray: _blobField(3), width: 128, height: 128);
    final e = t.advance(
      gray: _blobField(3, shiftX: 1),
      width: 128,
      height: 128,
      focalXPixels: 101.6,
      focalYPixels: 101.6,
    );
    expect(e, isNotNull);
    expect(
      e!.commonTrackCount / e.seedTrackCount,
      greaterThan(0.9),
      reason: '纯 1px 平移没有任何理由丢点 —— 掉回 0.5 就是边界误杀回来了',
    );
  });

  test('大位移(10px)不再被每层位移上限判死', () {
    final t = ContinuousFeatureTracks();
    t.setReference(gray: _blobField(3), width: 128, height: 128);
    final e = t.advance(
      gray: _blobField(3, shiftX: 10),
      width: 128,
      height: 128,
      focalXPixels: 101.6,
      focalYPixels: 101.6,
    );
    expect(e, isNotNull);
    expect(e!.commonTrackCount, greaterThanOrEqualTo(20));
    expect(
      e.medianPixelDisplacement,
      closeTo(10, 1.5),
      reason: 'OpenCV 对总位移没有上限;旧实现的 |δ|>radius 判拒是自加的',
    );
  });
}

/// 平滑斑点场:确定性伪随机中心 + 高斯斑,LK 友好(接近真实画面的低频结构)。
/// 高频条纹类夹具是 LK 毒药(混叠),会伪造出跟踪缺陷 —— 见当日 88 个假
/// "新点"的教训。
Uint8List _blobField(int seed, {int shiftX = 0}) {
  const side = 128;
  final out = Uint8List(side * side);
  final pts = <List<int>>[];
  var state = seed * 2654435761 + 97;
  while (pts.length < 24) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    final x = 8 + (state >> 8) % (side - 16);
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    final y = 8 + (state >> 8) % (side - 16);
    if (pts.every(
      (p) => (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y) >= 144,
    )) {
      pts.add([x, y]);
    }
  }
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      var v = 24.0;
      for (final c in pts) {
        final dx = x - c[0] - shiftX;
        final dy = y - c[1];
        final d2 = dx * dx + dy * dy;
        if (d2 < 100) v += 200.0 * math.exp(-d2 / 18.0);
      }
      out[y * side + x] = v.clamp(0, 255).toInt();
    }
  }
  return out;
}
