// 条目 11 第 4 条单测:采集引导信号。
// 钉三件事:(1) 优先级顺序;(2) 铁律「禁止用户可见的质量滑杆/档位」;
// (3) cloudPreviewOnly 与 blocksAbsoluteDimensions 是两条独立的线。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/quality/capture_guidance.dart';
import 'package:pocketworld_flutter/vio/quality/initialization_window.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability.dart';
import 'package:pocketworld_flutter/vio/quality/texture_sufficiency.dart';

const int kW = 640;
const int kH = 480;

TextureSample _tex(int n, double areaFraction, {int seed = 5}) {
  final r = math.Random(seed);
  final side = math.sqrt(areaFraction);
  final xy = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    xy[i * 2] = r.nextDouble() * kW * side;
    xy[i * 2 + 1] = r.nextDouble() * kH * side;
  }
  return evaluateTextureSufficiency(xy: xy, imageWidth: kW, imageHeight: kH);
}

ScaleObservabilitySample _scale(
  ScaleObservabilityVerdict v, {
  double bd = 0.15,
  double sigma = double.infinity,
}) => ScaleObservabilitySample(
  tSec: 1.0,
  verdict: v,
  parallaxOk: bd >= kMinBaselineOverDepth,
  excitationOk: v == ScaleObservabilityVerdict.sufficient,
  baselineMeters: bd * 2.0,
  medianDepthMeters: 2.0,
  baselineOverDepth: bd,
  relativeScaleSigma: sigma,
  acRmsMps2: 0.0,
  imuSamples: 200,
  windowSeconds: 2.0,
  rotationSpanDeg: 0.0,
  excitationBins: 60,
  bandLimitBinSeconds: 1 / 30,
);

/// 已收敛的 disposition(把初始化这一档让开,好单独测后面的优先级)。
VioFrameDisposition _converged() => const VioFrameDisposition(
  phase: VioInitPhase.converged,
  cloudPreviewOnly: false,
  texturedStreak: 30,
  bestBaselineOverDepth: 0.5,
  elapsedSeconds: 3.0,
);

VioFrameDisposition _initializing() => const VioFrameDisposition(
  phase: VioInitPhase.converging,
  cloudPreviewOnly: true,
  texturedStreak: 3,
  bestBaselineOverDepth: 0.02,
  elapsedSeconds: 0.2,
);

void main() {
  group('🔒 铁律:这是引导,不是质量档位', () {
    test('guidance exposes no quality tier', () {
      // 穷举 cue:每一个都必须是「现在缺什么」,不许出现 low/medium/high、
      // star、score、level 这类档位词。有人想加一档质量等级,这条会挂。
      expect(CaptureGuidanceCue.values, hasLength(7));
      expect(CaptureGuidanceCue.values.toSet(), <CaptureGuidanceCue>{
        CaptureGuidanceCue.none,
        CaptureGuidanceCue.initializing,
        CaptureGuidanceCue.needTexture,
        CaptureGuidanceCue.spreadView,
        CaptureGuidanceCue.translate,
        CaptureGuidanceCue.widerBaseline,
        CaptureGuidanceCue.breakCadence,
      });
      const banned = <String>[
        'low',
        'medium',
        'high',
        'level',
        'tier',
        'score',
        'star',
        'quality',
      ];
      for (final c in CaptureGuidanceCue.values) {
        final name = c.name.toLowerCase();
        for (final b in banned) {
          expect(name.contains(b), isFalse, reason: '${c.name} 看起来像质量档位而不是引导');
        }
      }
    });

    test('达标时 cue 消失(进度是任务进度,不是质量刻度)', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(400, 1.0),
        scale: _scale(
          ScaleObservabilityVerdict.sufficient,
          bd: 0.5,
          sigma: 0.005,
        ),
      );
      expect(g.cue, CaptureGuidanceCue.none);
      expect(g.progress01, 1.0);
      expect(g.blocksAbsoluteDimensions, isFalse);
    });
  });

  group('优先级:一次只说一句话', () {
    test('初始化压过一切', () {
      final g = computeCaptureGuidance(
        disposition: _initializing(),
        // 纹理和尺度同时也是坏的,但这时候它们的结论还不可信。
        texture: _tex(6, 0.02),
        scale: _scale(ScaleObservabilityVerdict.pureRotation, bd: 0.0),
      );
      expect(g.cue, CaptureGuidanceCue.initializing);
      expect(g.cloudPreviewOnly, isTrue);
    });

    test('纹理数量压过分布与尺度', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(6, 0.02), // starved
        scale: _scale(ScaleObservabilityVerdict.constantVelocity, bd: 0.5),
      );
      expect(g.cue, CaptureGuidanceCue.needTexture);
      expect(g.progress01, lessThan(1.0));
    });

    test('纹理分布压过尺度', () {
      final t = _tex(400, 0.05);
      expect(t.verdict, TextureVerdict.clustered); // 夹具自检
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: t,
        scale: _scale(ScaleObservabilityVerdict.constantVelocity, bd: 0.5),
      );
      expect(g.cue, CaptureGuidanceCue.spreadView);
    });

    test('原地转 ⇒ translate', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(400, 1.0),
        scale: _scale(ScaleObservabilityVerdict.pureRotation, bd: 0.0),
      );
      expect(g.cue, CaptureGuidanceCue.translate);
    });

    test('基线不够 ⇒ widerBaseline,并带出还差多少', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(400, 1.0),
        scale: _scale(ScaleObservabilityVerdict.parallaxStarved, bd: 0.15),
      );
      expect(g.cue, CaptureGuidanceCue.widerBaseline);
      // b/d=0.15、深度 2 m ⇒ 基线 0.3 m,需要 0.6 m ⇒ 还差 0.3 m
      expect(g.neededExtraBaselineMeters, closeTo(0.3, 1e-9));
      expect(g.progress01, closeTo(0.5, 1e-9));
    });

    test('🔴 匀速段:前面都干净了才轮到它说话,但它一定会说', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(400, 1.0),
        scale: _scale(
          ScaleObservabilityVerdict.constantVelocity,
          bd: 0.5,
          sigma: 0.04,
        ),
      );
      expect(g.cue, CaptureGuidanceCue.breakCadence);
      // 目标 0.01、实际 0.04 ⇒ 进度 0.25
      expect(g.progress01, closeTo(0.25, 1e-9));
      expect(g.blocksAbsoluteDimensions, isTrue);
    });

    test('负向对照:把匀速段的 verdict 换成 sufficient ⇒ cue 立刻变 none', () {
      // 证明 breakCadence 这一档确实是被 constantVelocity 这个结论驱动的,
      // 不是被别的东西顺带点亮的。
      final same = _tex(400, 1.0);
      final bad = computeCaptureGuidance(
        disposition: _converged(),
        texture: same,
        scale: _scale(ScaleObservabilityVerdict.constantVelocity, bd: 0.5),
      );
      final good = computeCaptureGuidance(
        disposition: _converged(),
        texture: same,
        scale: _scale(
          ScaleObservabilityVerdict.sufficient,
          bd: 0.5,
          sigma: 0.005,
        ),
      );
      expect(bad.cue, CaptureGuidanceCue.breakCadence);
      expect(good.cue, CaptureGuidanceCue.none);
    });
  });

  group('两条线独立', () {
    test('几何可交付但尺寸被挡(自动步道)', () {
      final g = computeCaptureGuidance(
        disposition: _converged(),
        texture: _tex(400, 1.0),
        scale: _scale(ScaleObservabilityVerdict.constantVelocity, bd: 0.5),
      );
      expect(g.cloudPreviewOnly, isFalse, reason: '几何照常交付');
      expect(g.blocksAbsoluteDimensions, isTrue, reason: '但尺寸不许标');
    });

    test('缺席的输入按 fail-safe 处理,不崩', () {
      final g = computeCaptureGuidance(disposition: _converged());
      expect(g.cue, CaptureGuidanceCue.needTexture);
      expect(g.blocksAbsoluteDimensions, isTrue);
      expect(g.progress01, 0.0);
    });
  });
}
