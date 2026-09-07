import 'dart:io';
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
  _newFeatureBurstContract();

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
        detectNewFeatures: false,
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
      newFeatureCount: -1,
      liveTrackCount: -1,
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
      newFeatureCount: -1,
      liveTrackCount: -1,
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
      newFeatureCount: -1,
      liveTrackCount: -1,
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
      newFeatureCount: -1,
      liveTrackCount: -1,
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
      detectNewFeatures: false,
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
      detectNewFeatures: false,
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

// ── 复刻:VINS-Fusion 新旧比开火条件 ─────────────────────────────────────
// feature_manager.cpp 逐字:`new_feature_num > 0.5 * last_track_num` → 关键帧。
// 适配边界见 FrameTrackEvidence.hasNewFeatureBurst 的注释(六路调研存档:
// docs/research/2026-09-01-info-gain-shutter-trigger-six-path-survey.md)。
void _newFeatureBurstContract() {
  FrameTrackEvidence ev({required int newCount, required int tracked}) =>
      FrameTrackEvidence(
        seedTrackCount: tracked,
        commonTrackCount: tracked,
        commonTrackFraction: 1,
        medianPixelDisplacement: 1,
        medianNormalizedDisplacement: 0.001,
        meanNormalizedDisplacement: 0.001,
        newFeatureCount: newCount,
        liveTrackCount: tracked,
      );

  test('新旧比过半 → burst;未过半/未检测/跟踪不足 → 不 burst', () {
    // 30 tracked,16 new:16 > 15 → burst
    expect(ev(newCount: 16, tracked: 30).hasNewFeatureBurst, isTrue);
    // 15 new:15 > 15 不成立(上游是严格大于)
    expect(ev(newCount: 15, tracked: 30).hasNewFeatureBurst, isFalse);
    // 未检测(-1)绝不 burst —— 节流窗之间不许凭空开火
    expect(ev(newCount: -1, tracked: 30).hasNewFeatureBurst, isFalse);
    // 跟踪 <20:维持我们「无证据不拍」的既有偏离(上游此时反而强制关键帧)
    expect(ev(newCount: 19, tracked: 19).hasNewFeatureBurst, isFalse);
  });

  test('advance 只在 detectNewFeatures 时才数新点;旧场景不 burst', () {
    // 平滑斑点场:LK 友好。此前用高频条纹夹具,一半角点本来就跟不上,
    // 跟不上的进不了掩膜、每次检测都被重复数成"新"(84→91→105 越数越多)
    // —— 那是夹具的混叠毒性,不是判据语义。夹具必须像真实画面(同日
    // 假内参教训:自造夹具的非物理性质会伪造出判据缺陷)。
    final t = ContinuousFeatureTracks();
    t.setReference(gray: _blobField(0), width: 128, height: 128);
    final off = t.advance(
      gray: _blobField(0, shiftX: 1),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      detectNewFeatures: false,
    );
    expect(off!.newFeatureCount, -1, reason: '未检测时绝不凭空给数');
    final on = t.advance(
      gray: _blobField(0, shiftX: 2),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      detectNewFeatures: true,
    );
    expect(on!.newFeatureCount, greaterThanOrEqualTo(0));
    expect(
      on.hasNewFeatureBurst,
      isFalse,
      reason: '纯平移的旧场景不得触发新旧比 —— 掩膜+补池语义在起作用',
    );
  });

  test('画面里出现大片新内容 → burst', () {
    // 参考帧:斑点只在左半;新帧:左半不动、右半冒出另一组斑点 ——
    // "转到新面"的最小模型。
    final t = ContinuousFeatureTracks();
    t.setReference(
      gray: _blobField(0, rightHalfSeed: -1),
      width: 128,
      height: 128,
    );
    final e = t.advance(
      gray: _blobField(0, rightHalfSeed: 7),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      detectNewFeatures: true,
    );
    expect(e, isNotNull);
    expect(
      e!.liveTrackCount,
      greaterThanOrEqualTo(20),
      reason: '左半的旧斑点必须还在跟,否则判据被守卫关掉',
    );
    expect(
      e.hasNewFeatureBurst,
      isTrue,
      reason: 'VINS-Fusion:new > 0.5 × tracked 必须点亮 —— 这正是本刀的全部目的',
    );
  });

  test('接线契约:burst 与流量段是 OR,几何角色闸不动', () {
    final source = File(
      'lib/official_capture/auto_capture_controller.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');
    expect(
      source,
      contains('_smartMotionSegment.ready || _newFeatureBurst'),
      reason: '上游 addFeatureCheckParallax 就是「新旧比 OR 视差」的结构',
    );
    expect(
      source,
      contains('detectNewFeatures:'),
      reason: '检测必须节流,不许每 tick 检测',
    );
    expect(
      source,
      contains('_newFeatureBurst = false;'),
      reason: '开火与新照片入列必须清闩',
    );
  });
}

/// 平滑斑点场:确定性伪随机中心 + 高斯斑,LK 友好(接近真实画面的低频结构)。
/// [rightHalfSeed] >= 0 时右半改用另一组斑点;-1 = 右半留空。
Uint8List _blobField(int seed, {int shiftX = 0, int? rightHalfSeed}) {
  const side = 128;
  final out = Uint8List(side * side);
  List<List<int>> centers(int s, int x0, int x1) {
    final pts = <List<int>>[];
    var state = s * 2654435761 + 97;
    while (pts.length < 24) {
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      final x = x0 + (state >> 8) % (x1 - x0);
      state = (state * 1103515245 + 12345) & 0x7fffffff;
      final y = 8 + (state >> 8) % (side - 16);
      if (pts.every(
        (p) => (p[0] - x) * (p[0] - x) + (p[1] - y) * (p[1] - y) >= 144,
      )) {
        pts.add([x, y]);
      }
    }
    return pts;
  }

  final left = centers(seed, 8, rightHalfSeed == null ? side - 8 : 60);
  final right = rightHalfSeed == null
      ? const <List<int>>[]
      : rightHalfSeed < 0
      ? const <List<int>>[]
      : centers(rightHalfSeed, 68, side - 8);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      var v = 24.0;
      for (final c in [...left, ...right]) {
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
