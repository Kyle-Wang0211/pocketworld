// 条目 10 第 2 条单测:初始化窗口闸门。
// 重点钉两件事:(1) 铁律 —— 一帧都不丢;(2) 两个闸门不许互相顶替。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/quality/initialization_window.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability.dart';
import 'package:pocketworld_flutter/vio/quality/texture_sufficiency.dart';

const int kW = 640;
const int kH = 480;

/// 造一个纹理充分 / 不充分的 TextureSample(走真实评估函数,不手搓字段)。
TextureSample _texture({required bool good, int seed = 5}) {
  final r = math.Random(seed);
  final n = good ? 400 : 6;
  final frac = good ? 1.0 : 0.02;
  final side = math.sqrt(frac);
  final xy = Float32List(n * 2);
  for (var i = 0; i < n; i++) {
    xy[i * 2] = r.nextDouble() * kW * side;
    xy[i * 2 + 1] = r.nextDouble() * kH * side;
  }
  final s = evaluateTextureSufficiency(
    xy: xy,
    imageWidth: kW,
    imageHeight: kH,
  );
  // 夹具自检。用 throw 而不是 expect —— 这个函数会在 group 体里被调用,
  // 那里还没有活跃的 test,expect 会抛 OutsideTestException。
  if (s.isSufficient != good) {
    throw StateError('夹具自检失败:期望 good=$good,实际 $s');
  }
  return s;
}

ScaleObservabilitySample _scale(double t, double? bd) =>
    ScaleObservabilitySample(
      tSec: t,
      verdict: ScaleObservabilityVerdict.insufficientData,
      parallaxOk: false,
      excitationOk: false,
      baselineMeters: 0.0,
      medianDepthMeters: 2.0,
      baselineOverDepth: bd,
      relativeScaleSigma: double.infinity,
      acRmsMps2: 0.0,
      imuSamples: 0,
      windowSeconds: 2.0,
      rotationSpanDeg: 0.0,
      excitationBins: 0,
      bandLimitBinSeconds: 0.0,
    );

void main() {
  group('🔒 铁律:闸门只打标,一帧都不丢', () {
    test('gate never discards a frame', () {
      final gate = VioInitializationGate();
      final good = _texture(good: true);
      final bad = _texture(good: false);
      var retained = 0;
      const n = 200;
      for (var i = 0; i < n; i++) {
        final d = gate.admit(
          tSec: i / 30.0,
          // 前 100 帧故意全是坏帧,后 100 帧好帧。
          texture: i < 100 ? bad : good,
          scale: _scale(i / 30.0, i < 100 ? 0.0 : 0.5),
        );
        expect(d.frameRetained, isTrue);
        retained++;
      }
      expect(retained, n);
      expect(gate.totalFrames, n, reason: '喂多少帧记多少帧');
      // previewOnly 只是注释,被标注的帧仍然在 totalFrames 里。
      expect(gate.previewOnlyFrames, lessThan(n));
      expect(gate.previewOnlyFrames, greaterThan(0));
    });

    test('texture 缺席按不充分算(fail-safe),但帧照留', () {
      final gate = VioInitializationGate();
      for (var i = 0; i < 50; i++) {
        final d = gate.admit(tSec: i / 30.0, texture: null);
        expect(d.frameRetained, isTrue);
        expect(d.cloudPreviewOnly, isTrue);
      }
      expect(gate.phase, isNot(VioInitPhase.converged));
      expect(gate.totalFrames, 50);
    });
  });

  group('收敛判据:三条缺一不可', () {
    final good = _texture(good: true);

    test('只有纹理、没有基线 ⇒ 不收敛', () {
      final gate = VioInitializationGate();
      for (var i = 0; i < 60; i++) {
        gate.admit(tSec: i / 30.0, texture: good, scale: _scale(i / 30.0, 0.0));
      }
      expect(gate.phase, VioInitPhase.converging);
      expect(gate.bestBaselineOverDepth, 0.0);
    });

    test('纹理 + 基线,但时间不够 ⇒ 不收敛', () {
      // minInitSeconds 默认 0.5 s;这里只喂 0.3 s。
      final gate = VioInitializationGate();
      for (var i = 0; i < 10; i++) {
        gate.admit(tSec: i / 30.0, texture: good, scale: _scale(i / 30.0, 0.5));
      }
      expect(gate.phase, VioInitPhase.converging);
    });

    test('纹理连续帧数不够 ⇒ 不收敛(streak 被坏帧打断)', () {
      final bad = _texture(good: false);
      final gate = VioInitializationGate();
      for (var i = 0; i < 60; i++) {
        gate.admit(
          tSec: i / 30.0,
          // 每 5 帧插一个坏帧,streak 永远到不了 10。
          texture: (i % 5 == 4) ? bad : good,
          scale: _scale(i / 30.0, 0.5),
        );
      }
      expect(gate.phase, VioInitPhase.converging);
    });

    test('三条齐 ⇒ converged,此后点云可进交付', () {
      final gate = VioInitializationGate();
      late VioFrameDisposition last;
      for (var i = 0; i < 60; i++) {
        last = gate.admit(
          tSec: i / 30.0,
          texture: good,
          scale: _scale(i / 30.0, 0.5),
        );
      }
      expect(gate.phase, VioInitPhase.converged);
      expect(last.cloudPreviewOnly, isFalse);
      expect(last.deliverable, isTrue);
      // 初始化那一小段被标成 previewOnly,数量应当等于收敛前的帧数。
      expect(gate.previewOnlyFrames, greaterThan(0));
      expect(gate.previewOnlyFrames, lessThan(60));
    });

    test('初始化的基线门复用覆盖云 5°,不是尺度侧的 0.30', () {
      expect(
        kInitMinBaselineOverDepth,
        closeTo(baselineOverDepthFromTriangulationDeg(5.0), 1e-12),
      );
      expect(kInitMinBaselineOverDepth, lessThan(kMinBaselineOverDepth));
      // 负向对照:如果误用 0.30 当初始化门,同一段 b/d=0.15 的数据会卡死不收敛。
      final strict = VioInitializationGate(
        policy: VioInitPolicy(minInitBaselineOverDepth: kMinBaselineOverDepth),
      );
      final loose = VioInitializationGate();
      for (var i = 0; i < 60; i++) {
        strict.admit(
          tSec: i / 30.0,
          texture: good,
          scale: _scale(i / 30.0, 0.15),
        );
        loose.admit(
          tSec: i / 30.0,
          texture: good,
          scale: _scale(i / 30.0, 0.15),
        );
      }
      expect(loose.phase, VioInitPhase.converged);
      expect(
        strict.phase,
        isNot(VioInitPhase.converged),
        reason: '证明这两个门确实是不同的数,混用会让初始化白等',
      );
    });
  });

  group('丢失重定位', () {
    final good = _texture(good: true);

    test('relocalization reopens the window', () {
      final gate = VioInitializationGate();
      for (var i = 0; i < 60; i++) {
        gate.admit(tSec: i / 30.0, texture: good, scale: _scale(i / 30.0, 0.5));
      }
      expect(gate.phase, VioInitPhase.converged);

      gate.markTrackingLost(tSec: 2.0);
      expect(gate.phase, VioInitPhase.bootstrapping);
      expect(gate.bestBaselineOverDepth, 0.0, reason: '历史基线不许让新窗口白捡');

      // 重开之后立刻喂一帧好纹理:不能立刻放行(时间/连续帧数都还没攒够)。
      final d = gate.admit(tSec: 2.0, texture: good, scale: _scale(2.0, 0.5));
      expect(d.cloudPreviewOnly, isTrue);

      // 会话级账不清零。
      expect(gate.totalFrames, 61);
    });
  });

  group('两个闸门独立,不许互相顶替', () {
    final good = _texture(good: true);

    test('几何可交付 ≠ 尺寸可标', () {
      final gate = VioInitializationGate();
      for (var i = 0; i < 60; i++) {
        gate.admit(tSec: i / 30.0, texture: good, scale: _scale(i / 30.0, 0.5));
      }
      final a = gate.admission(mayReportAbsoluteDimensions: false);
      expect(a.cloudDeliverable, isTrue, reason: '整段自动步道也照样交付几何');
      expect(a.mayReportAbsoluteDimensions, isFalse, reason: '但不许标尺寸');
      expect(a.toTelemetry()['vio_init_cloud_deliverable'], '1');
      expect(a.toTelemetry()['vio_may_report_dims'], '0');
    });

    test('尺度可观测但初始化没收敛 ⇒ 点云仍然只做预览', () {
      final gate = VioInitializationGate();
      gate.admit(tSec: 0.0, texture: null);
      final a = gate.admission(mayReportAbsoluteDimensions: true);
      expect(a.cloudDeliverable, isFalse);
      expect(a.mayReportAbsoluteDimensions, isTrue);
    });
  });
}
