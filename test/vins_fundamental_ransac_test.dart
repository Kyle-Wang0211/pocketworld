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
