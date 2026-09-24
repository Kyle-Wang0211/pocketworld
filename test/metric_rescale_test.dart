// metric_rescale_test.dart — 整体等比缩放机制的单元测试。
//
// 纯 Dart VM(不起 Flutter binding)。覆盖四件事:
//   1. 语义正确:缩放后两点距离 == 用户输入的真实距离(±1e-9);
//      Open3D `ScalePoints` 的 center 语义(center 点不动)也逐点核过。
//   2. 与本仓既有原语等价:center == 原点时,点与位姿的结果与
//      gravity_align.dart 的 scaleAnchoredPoints / scaleAnchoredPosesPacked
//      **逐位相同** —— 保证新函数是既有机制的推广而不是分叉。
//   3. provenance 字段齐全且自洽(‖A−B‖ == measuredDistance,
//      s == real/measured,JSON 可序列化)。
//   4. s 异常一律**显式报错**,不静默施加:≤0、非有限、偏离 1 超过 50%。

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/gravity_align.dart'
    show scaleAnchoredPoints, scaleAnchoredPosesPacked;
import 'package:pocketworld_flutter/official_capture/metric_rescale.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability.dart'
    show ScaleObservabilitySample, ScaleObservabilityVerdict;

/// 边长 [side] 的轴对齐立方体,一角在原点。8 个顶点,顺序固定:
/// 0:(0,0,0) 1:(s,0,0) 2:(0,s,0) 3:(s,s,0) 4:(0,0,s) 5:(s,0,s) 6:(0,s,s) 7:(s,s,s)
Float32List cube(double side) {
  final out = Float32List(8 * 3);
  var i = 0;
  for (final z in <double>[0.0, side]) {
    for (final y in <double>[0.0, side]) {
      for (final x in <double>[0.0, side]) {
        out[i++] = x;
        out[i++] = y;
        out[i++] = z;
      }
    }
  }
  return out;
}

double dist(Float32List xyz, int a, int b) {
  final dx = xyz[a * 3] - xyz[b * 3];
  final dy = xyz[a * 3 + 1] - xyz[b * 3 + 1];
  final dz = xyz[a * 3 + 2] - xyz[b * 3 + 2];
  return math.sqrt(dx * dx + dy * dy + dz * dz);
}

ScaleObservabilitySample sampleWith(
  ScaleObservabilityVerdict verdict,
  double sigma,
) => ScaleObservabilitySample(
  tSec: 12.5,
  verdict: verdict,
  parallaxOk: verdict == ScaleObservabilityVerdict.sufficient,
  excitationOk: verdict == ScaleObservabilityVerdict.sufficient,
  baselineMeters: 0.6,
  medianDepthMeters: 2.0,
  baselineOverDepth: 0.3,
  relativeScaleSigma: sigma,
  acRmsMps2: 0.4,
  imuSamples: 300,
  windowSeconds: 3.0,
  rotationSpanDeg: 20.0,
  excitationBins: 90,
  bandLimitBinSeconds: 1 / 30,
);

/// 9 double/帧:[frameId, registered, qw,qx,qy,qz, tx,ty,tz]。
Float64List poses() => Float64List.fromList(<double>[
  // 帧 0:已注册,单位四元数。
  0, 1, 1, 0, 0, 0, 0.5, -1.25, 3.0,
  // 帧 1:已注册,绕 z 转 90°(w=cos45, z=sin45)。
  1, 1, 0.7071067811865476, 0, 0, 0.7071067811865476, -2.0, 0.75, 0.125,
  // 帧 2:未注册 —— 必须原样透传。
  2, 0, 0, 0, 0, 0, 9.0, 9.0, 9.0,
]);

void main() {
  group('rescaleToKnownDistance — 语义', () {
    test('缩放后两点距离 == 用户输入的真实距离(±1e-9)', () {
      // 边长 20 的立方体;沿 x 轴量顶点 0↔1 得 20,用户说真实是 21
      // ⇒ s = 1.05。21 在 float32 上精确可表示,所以 1e-9 的断言是实打实的。
      final xyz = cube(20.0);
      const real = 21.0;
      final r = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: real,
      );

      expect(r.provenance.scaleFactor, closeTo(1.05, 1e-12));
      expect(dist(r.xyz, 0, 1), closeTo(real, 1e-9));
    });

    test('非轴对齐的体对角线也整体等比(相对误差在 float32 量级内)', () {
      final xyz = cube(20.0);
      final before = dist(xyz, 0, 7);
      final r = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
      );
      expect(dist(r.xyz, 0, 7) / before, closeTo(1.05, 1e-6));
    });

    test('Open3D ScalePoints 语义:center 本身不动', () {
      final xyz = cube(20.0);
      // 拿顶点 7 (20,20,20) 当 center。
      final center = <double>[20.0, 20.0, 20.0];
      final r = rescaleToKnownDistance(
        xyz: xyz,
        pointA: anchorPointAt(xyz, 0),
        pointB: anchorPointAt(xyz, 1),
        realDistanceMeters: 21.0,
        center: center,
      );
      expect(r.xyz[7 * 3], closeTo(20.0, 1e-9));
      expect(r.xyz[7 * 3 + 1], closeTo(20.0, 1e-9));
      expect(r.xyz[7 * 3 + 2], closeTo(20.0, 1e-9));
      // 距离仍然被正确重定尺(平移不改距离)。
      expect(dist(r.xyz, 0, 1), closeTo(21.0, 1e-9));
    });

    test('输入缓冲区不被修改', () {
      final xyz = cube(20.0);
      final copy = Float32List.fromList(xyz);
      final p = poses();
      final pcopy = Float64List.fromList(p);
      rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
        posesPacked: p,
      );
      expect(xyz, orderedEquals(copy));
      expect(p, orderedEquals(pcopy));
    });
  });

  group('与既有原语等价(center == 原点)', () {
    test('点:与 scaleAnchoredPoints 逐位相同', () {
      final xyz = cube(20.0);
      final r = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
      );
      expect(r.xyz, orderedEquals(scaleAnchoredPoints(xyz, 1.05)));
    });

    test('位姿:与 scaleAnchoredPosesPacked 逐位相同,未注册帧透传', () {
      final xyz = cube(20.0);
      final p = poses();
      final r = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
        posesPacked: p,
      );
      expect(r.posesPacked, isNotNull);
      expect(r.posesPacked!, orderedEquals(scaleAnchoredPosesPacked(p, 1.05)));
      // 未注册帧(第 3 帧,偏移 18)整条原样。
      expect(r.posesPacked!.sublist(18), orderedEquals(p.sublist(18)));
    });

    test('位姿:center 非原点时相机中心按 C\' = s(C−c)+c 走', () {
      // 帧 0 是单位四元数 ⇒ C = −Rᵀt = −t = (−0.5, 1.25, −3.0)。
      final xyz = cube(20.0);
      final p = poses();
      const c = <double>[1.0, 2.0, 3.0];
      const s = 1.05;
      final r = rescaleToKnownDistance(
        xyz: xyz,
        pointA: anchorPointAt(xyz, 0),
        pointB: anchorPointAt(xyz, 1),
        realDistanceMeters: 21.0,
        posesPacked: p,
        center: c,
      );
      final t = r.posesPacked!;
      // R = I ⇒ C' = −t'
      final cAfter = <double>[-t[6], -t[7], -t[8]];
      final cBefore = <double>[-p[6], -p[7], -p[8]];
      for (var k = 0; k < 3; k++) {
        expect(cAfter[k], closeTo(s * (cBefore[k] - c[k]) + c[k], 1e-12));
      }
    });
  });

  group('provenance', () {
    test('字段齐全、自洽、可 JSON 序列化', () {
      final xyz = cube(20.0);
      final ts = DateTime.utc(2026, 9, 22, 13, 5, 7);
      final r = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
        posesPacked: poses(),
        timestampUtc: ts,
        vioScaleConfidence: sampleWith(
          ScaleObservabilityVerdict.constantVelocity,
          double.infinity,
        ),
      );
      final pv = r.provenance;

      expect(pv.schemaVersion, kMetricRescaleProvenanceSchemaVersion);
      expect(pv.source, MetricRescaleSource.userEnteredDistance);
      expect(pv.scaleFactor, closeTo(1.05, 1e-12));
      expect(pv.anchorPointA, orderedEquals(<double>[0.0, 0.0, 0.0]));
      expect(pv.anchorPointB, orderedEquals(<double>[20.0, 0.0, 0.0]));
      expect(pv.center, orderedEquals(<double>[0.0, 0.0, 0.0]));
      expect(pv.measuredDistance, closeTo(20.0, 1e-12));
      expect(pv.realDistance, 21.0);
      // 自洽:s == real / measured
      expect(pv.scaleFactor, closeTo(pv.realDistance / pv.measuredDistance, 1e-15));
      expect(pv.pointCount, 8);
      expect(pv.poseCount, 3);
      expect(pv.timestampUtc, ts);
      expect(pv.vioScaleVerdict, 'constantVelocity');
      expect(pv.vioRelativeScaleSigma, double.infinity);
      expect(pv.vioSampleTSec, 12.5);

      final j = pv.toJson();
      // 每个契约字段都在,一个不许缺。
      expect(
        j.keys.toSet(),
        <String>{
          'schema_version',
          'scale_factor',
          'source',
          'anchor_point_a',
          'anchor_point_b',
          'center',
          'measured_distance',
          'real_distance',
          'point_count',
          'pose_count',
          'timestamp_utc',
          'vio_scale_verdict',
          'vio_relative_scale_sigma',
          'vio_sample_t_sec',
        },
      );
      expect(j['source'], 'userEnteredDistance');
      expect(j['timestamp_utc'], ts.toIso8601String());
      // 匀速段 σ = Infinity:JSON 不认,必须转成字符串而不是丢掉。
      expect(j['vio_relative_scale_sigma'], 'inf');
      expect(() => jsonEncode(j), returnsNormally);
    });

    test('没喂 VIO 可信度时三个字段为 null,其余照常', () {
      final xyz = cube(20.0);
      final pv = rescaleToKnownDistanceByIndex(
        xyz: xyz,
        indexA: 0,
        indexB: 1,
        realDistanceMeters: 21.0,
      ).provenance;
      expect(pv.vioScaleVerdict, isNull);
      expect(pv.vioRelativeScaleSigma, isNull);
      expect(pv.vioSampleTSec, isNull);
      expect(pv.poseCount, 0);
      expect(() => jsonEncode(pv.toJson()), returnsNormally);
    });
  });

  group('s 异常必须显式报错,不静默施加', () {
    final xyz = cube(20.0);

    void expectCode(void Function() body, String code) {
      expect(
        body,
        throwsA(
          isA<MetricRescaleException>().having((e) => e.code, 'code', code),
        ),
      );
    }

    test('真实距离 ≤ 0', () {
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: 0.0,
        ),
        MetricRescaleException.invalidRealDistance,
      );
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: -1.0,
        ),
        MetricRescaleException.invalidRealDistance,
      );
    });

    test('真实距离非有限(NaN / Infinity)', () {
      for (final bad in <double>[double.nan, double.infinity, double.negativeInfinity]) {
        expectCode(
          () => rescaleToKnownDistanceByIndex(
            xyz: xyz,
            indexA: 0,
            indexB: 1,
            realDistanceMeters: bad,
          ),
          MetricRescaleException.invalidRealDistance,
        );
      }
    });

    test('两点重合 ⇒ 量得距离为 0,s 无定义', () {
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 3,
          indexB: 3,
          realDistanceMeters: 1.0,
        ),
        MetricRescaleException.degenerateMeasuredDistance,
      );
    });

    test('s 偏离 1 超过 50%(典型成因:厘米当米)', () {
      // 量得 20,用户把 21 m 输成了 2100 cm ⇒ s = 105。
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: 2100.0,
        ),
        MetricRescaleException.scaleOutOfBand,
      );
      // 反向:把 21 m 输成 0.21 m ⇒ s = 0.0105。
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: 0.21,
        ),
        MetricRescaleException.scaleOutOfBand,
      );
    });

    test('边界:刚好 ±50% 通过,越一点就拒', () {
      expect(
        rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: 30.0, // s = 1.5
        ).provenance.scaleFactor,
        closeTo(1.5, 1e-12),
      );
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 1,
          realDistanceMeters: 30.2, // s = 1.51
        ),
        MetricRescaleException.scaleOutOfBand,
      );
    });

    test('点索引越界', () {
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: 0,
          indexB: 8,
          realDistanceMeters: 21.0,
        ),
        MetricRescaleException.pointIndexOutOfRange,
      );
      expectCode(
        () => rescaleToKnownDistanceByIndex(
          xyz: xyz,
          indexA: -1,
          indexB: 1,
          realDistanceMeters: 21.0,
        ),
        MetricRescaleException.pointIndexOutOfRange,
      );
    });

    test('缓冲区畸形', () {
      expectCode(
        () => rescaleToKnownDistance(
          xyz: Float32List.fromList(<double>[0, 0, 0, 1]), // 4 个 float
          pointA: <double>[0, 0, 0],
          pointB: <double>[1, 0, 0],
          realDistanceMeters: 1.0,
        ),
        MetricRescaleException.malformedPointBuffer,
      );
      expectCode(
        () => rescaleToKnownDistance(
          xyz: xyz,
          pointA: anchorPointAt(xyz, 0),
          pointB: anchorPointAt(xyz, 1),
          realDistanceMeters: 21.0,
          posesPacked: Float64List(10), // 不是 9 的倍数
        ),
        MetricRescaleException.malformedPosesBuffer,
      );
    });

    test('锚点 / center 畸形', () {
      expectCode(
        () => rescaleToKnownDistance(
          xyz: xyz,
          pointA: <double>[0, 0],
          pointB: <double>[1, 0, 0],
          realDistanceMeters: 1.0,
        ),
        MetricRescaleException.malformedAnchorPoint,
      );
      expectCode(
        () => rescaleToKnownDistance(
          xyz: xyz,
          pointA: <double>[double.nan, 0, 0],
          pointB: <double>[1, 0, 0],
          realDistanceMeters: 1.0,
        ),
        MetricRescaleException.malformedAnchorPoint,
      );
      expectCode(
        () => rescaleToKnownDistance(
          xyz: xyz,
          pointA: anchorPointAt(xyz, 0),
          pointB: anchorPointAt(xyz, 1),
          realDistanceMeters: 21.0,
          center: <double>[0, 0, double.infinity],
        ),
        MetricRescaleException.malformedCenter,
      );
    });
  });
}
