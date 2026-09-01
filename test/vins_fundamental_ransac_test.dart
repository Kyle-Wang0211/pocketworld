import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/vins_fundamental_ransac.dart';

List<VinsCorrespondence> _sceneWithOutliers() {
  const focal = 460.0;
  const center = 230.0;
  const yaw = 0.055;
  final cosine = math.cos(yaw);
  final sine = math.sin(yaw);
  final inliers = <VinsCorrespondence>[];
  for (var i = 0; i < 50; i++) {
    final x = ((i * 37) % 101 - 50) / 38.0;
    final y = ((i * 53) % 97 - 48) / 42.0;
    final z = 3.0 + ((i * 29) % 41) / 20.0;
    final firstX = focal * x / z + center;
    final firstY = focal * y / z + center;
    final translatedX = x - 0.18;
    final secondX = cosine * translatedX - sine * z;
    final secondZ = sine * translatedX + cosine * z;
    final noiseX = ((i * 11) % 7 - 3) * 0.015;
    final noiseY = ((i * 13) % 7 - 3) * 0.015;
    inliers.add(
      VinsCorrespondence(
        firstX: firstX,
        firstY: firstY,
        secondX: focal * secondX / secondZ + center + noiseX,
        secondY: focal * y / secondZ + center + noiseY,
      ),
    );
  }

  final outliers = <VinsCorrespondence>[];
  for (var i = 0; i < 12; i++) {
    final first = inliers[i];
    final wrong = inliers[(i + 19) % inliers.length];
    outliers.add(
      VinsCorrespondence(
        firstX: first.firstX,
        firstY: first.firstY,
        secondX: wrong.secondX,
        secondY: wrong.secondY,
      ),
    );
  }
  return <VinsCorrespondence>[...inliers, ...outliers];
}

void main() {
  _wiringContract();

  test('OpenCV-style seven-point RANSAC rejects geometric mismatches', () {
    final correspondences = _sceneWithOutliers();
    final mask = vinsFundamentalRansacInlierMask(
      correspondences,
      thresholdPixels: 1.0,
      confidence: 0.99,
      maximumIterations: 1000,
    );

    expect(mask, hasLength(correspondences.length));
    expect(
      mask.take(50).where((value) => value).length,
      greaterThanOrEqualTo(46),
    );
    expect(mask.skip(50).where((value) => value).length, lessThanOrEqualTo(2));
  });

  test('RANSAC sampling is deterministic for identical evidence', () {
    final correspondences = _sceneWithOutliers();
    final first = vinsFundamentalRansacInlierMask(correspondences);
    final second = vinsFundamentalRansacInlierMask(correspondences);

    expect(second, first);
  });

  test('OpenCV LMeDS fallback handles the VINS 8 to 14 track range', () {
    final full = _sceneWithOutliers();
    final correspondences = <VinsCorrespondence>[
      ...full.take(12),
      ...full.skip(50).take(2),
    ];

    final mask = vinsFundamentalRansacInlierMask(correspondences);

    expect(mask, hasLength(14));
    // OpenCV 5.0.0's FM_RANSAC dispatches this exact 14-point fixture to
    // LMeDS and returns 8 good-scene inliers and no injected mismatches.
    expect(mask.take(12).where((value) => value).length, 8);
    expect(mask.skip(12).where((value) => value).length, 0);
  });
}

// ── 接线契约:均值判据必须建立在 rejectWithF 筛过的存活点上 ──────────────
// 上游 VINS-Mono readImage() 顺序:LK 跟踪 → rejectWithF() → setMask/addPoints,
// 而 addFeatureCheckParallax 的均值算在筛完之后的点上。只搬均值不搬这一步,
// 就是把不变量的前提留在原地(2026-09-01 两次同类错误的第二次)。
void _wiringContract() {
  test('trackFrameNovelty 在算位移之前跑 rejectWithF', () {
    final source = File(
      'lib/official_capture/continuous_feature_tracks.dart',
    ).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

    // 必须限定在 trackFrameNovelty 之内 —— 文件里有两条累积路径,
    // 类内 advance() 那条**故意不接** RANSAC(位姿流 30–60Hz,主机实测
    // 每次 0.44–1.12ms,而治理器在那条路上用的是跟踪数不是均值)。
    final fnAt = source.indexOf('FrameTrackEvidence trackFrameNovelty(');
    expect(fnAt, greaterThanOrEqualTo(0));
    final ransacAt = source.indexOf('vinsFundamentalRansacInlierMask(', fnAt);
    final accumulateAt = source.indexOf('normalizedDisplacements.add(', fnAt);
    expect(ransacAt, greaterThanOrEqualTo(0), reason: '剔除步骤必须存在');
    expect(
      ransacAt,
      lessThan(accumulateAt),
      reason: '必须先剔除离群跟踪,再累积位移 —— 否则均值建立在含离群点的集合上',
    );
    // 上游门槛:forw_pts.size() >= 8
    expect(source, contains('tracked.length >= 8'));
    // 上游坐标口径:FOCAL_LENGTH = 460
    expect(source, contains('vinsFocalLength = 460.0'));
  });
}
