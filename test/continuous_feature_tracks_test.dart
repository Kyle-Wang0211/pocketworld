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

Uint8List _panningWorldFrame({int shiftX = 0}) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final worldX = x - shiftX + 1024;
      final checker = (((worldX ~/ 8) + (y ~/ 8)) & 1) == 0 ? 35 : 220;
      final detail = ((worldX * 17 + y * 29 + (worldX * y) % 31) & 31) - 15;
      out[y * side + x] = (checker + detail).clamp(0, 255);
    }
  }
  return out;
}

Uint8List _piecewiseMotionFrame() {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sourceX = y < 80 ? x - 4 : x;
      final sourceY = y < 80 ? y : y - 8;
      final worldX = sourceX + 1024;
      final worldY = sourceY + 1024;
      final checker = (((worldX ~/ 8) + (worldY ~/ 8)) & 1) == 0 ? 35 : 220;
      final detail =
          ((worldX * 17 + worldY * 29 + (worldX * worldY) % 31) & 31) - 15;
      out[y * side + x] = (checker + detail).clamp(0, 255);
    }
  }
  return out;
}

Uint8List _smoothWorldFrame({int shiftX = 0}) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final worldX = x - shiftX + 600;
      final value =
          128 +
          48 * math.sin(worldX * 0.071) +
          41 * math.cos(y * 0.093) +
          29 * math.sin((worldX + y) * 0.041) +
          17 * math.cos((worldX - 2 * y) * 0.057);
      out[y * side + x] = value.round().clamp(0, 255);
    }
  }
  return out;
}

Uint8List _claheFixture() {
  const side = 32;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      out[y * side + x] = (x * 7 + y * 11 + (x * y) % 19) % 96 + 80;
    }
  }
  return out;
}

Uint8List _gfttFixture() {
  const side = 64;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      out[y * side + x] = (x * 7 + y * 11 + (x * y) % 19) % 96 + 80;
    }
  }
  return out;
}

/// The shutter bar for a 12 MP 4:3 frame on the 128x128 tracker grid.
/// fx = fy = 3230 px is a real iPhone main-camera intrinsic at 4032x3024;
/// the grid focals are that scaled per axis, exactly as the gate scales them.
const double _fx128 = 3230.0 * 128.0 / 4032.0;
const double _fy128 = 3230.0 * 128.0 / 3024.0;
final double _shutterBar = kOfficialCaptureNoveltyThreshold(
  gridWidth: 128,
  gridHeight: 128,
  focalXPixels: _fx128,
  focalYPixels: _fy128,
);

void main() {
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
        principalXPixels: 64,
        principalYPixels: 64,
      );
    }

    expect(evidence, isNotNull);
    expect(evidence!.vinsClaheApplied, isTrue);
    expect(evidence.commonTrackCount, greaterThanOrEqualTo(20));
    expect(evidence.medianPixelDisplacement, closeTo(12, 1.5));
    expect(evidence.hasEnoughNovelty, isTrue);
  });

  test('VINS 21x21 maxLevel=3 LK survives one 18-pixel preview jump', () {
    final tracks = ContinuousFeatureTracks();
    tracks.setReference(gray: _smoothWorldFrame(), width: 128, height: 128);

    final evidence = tracks.advance(
      gray: _smoothWorldFrame(shiftX: 18),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
    );

    expect(evidence, isNotNull);
    expect(evidence!.commonTrackCount, greaterThanOrEqualTo(20));
    expect(evidence.medianPixelDisplacement, closeTo(18, 2));
  });

  test('VINS CLAHE 3.0 8x8 port matches OpenCV fixture receipt', () {
    final output = vinsClaheGray(_claheFixture(), width: 32, height: 32);

    expect(output.fold<int>(0, (sum, value) => sum + value), 150295);
    const coordinates = <(int, int)>[
      (0, 0),
      (1, 1),
      (3, 3),
      (4, 4),
      (7, 7),
      (8, 8),
      (15, 15),
      (16, 16),
      (23, 23),
      (31, 31),
      (5, 17),
      (21, 9),
    ];
    expect(
      <int>[
        for (final coordinate in coordinates)
          output[coordinate.$2 * 32 + coordinate.$1],
      ],
      <int>[16, 80, 206, 235, 150, 152, 249, 60, 147, 255, 123, 197],
    );
  });

  test('VINS goodFeaturesToTrack port matches OpenCV selection semantics', () {
    final equalized = vinsClaheGray(_gfttFixture(), width: 64, height: 64);
    final points = vinsGoodFeaturesToTrack(
      equalized,
      width: 64,
      height: 64,
      maximumCorners: 150,
      minimumDistance: 4,
    );

    // SIMD float accumulation may retain one threshold-edge candidate on a
    // different CPU, but the leading local maxima must be the same set.
    expect(points.length, inInclusiveRange(93, 94));
    expect(points.take(12).toSet(), <(int, int)>{
      (26, 43),
      (16, 32),
      (9, 55),
      (47, 57),
      (11, 19),
      (57, 16),
      (32, 40),
      (43, 42),
      (25, 18),
      (31, 58),
      (33, 22),
      (35, 12),
    });
  });

  test(
    'VINS liftProjective consumes transported off-centre principal point',
    () {
      final projected = vinsLiftProjectiveToSyntheticPixel(
        x: 45,
        y: 38,
        width: 128,
        height: 128,
        focalXPixels: 100,
        focalYPixels: 120,
        principalXPixels: 60,
        principalYPixels: 62,
      );

      expect(projected.$1, closeTo(-5, 1e-12));
      expect(projected.$2, closeTo(-28, 1e-12));
    },
  );

  test(
    'VINS front end replenishes features while preserving old track ages',
    () {
      final tracks = ContinuousFeatureTracks();
      expect(
        tracks.setReference(
          gray: _panningWorldFrame(),
          width: 128,
          height: 128,
        ),
        isTrue,
      );

      FrameTrackEvidence? evidence;
      var sawReplenishment = false;
      for (var shift = 1; shift <= 24; shift++) {
        evidence = tracks.advance(
          gray: _panningWorldFrame(shiftX: shift),
          width: 128,
          height: 128,
          focalXPixels: 128,
          focalYPixels: 128,
          principalXPixels: 64,
          principalYPixels: 64,
        );
        sawReplenishment =
            sawReplenishment || (evidence?.vinsReplenishedTrackCount ?? 0) > 0;
      }

      expect(evidence, isNotNull);
      expect(sawReplenishment, isTrue);
      expect(evidence!.vinsActiveTrackCount, greaterThanOrEqualTo(120));
      expect(evidence.vinsLongestTrackAge, greaterThanOrEqualTo(20));
      expect(evidence.vinsOccupiedGridFraction, greaterThanOrEqualTo(0.5));
    },
  );

  test('VINS keyframe predicate consumes mean normalized step parallax', () {
    final tracks = ContinuousFeatureTracks();
    tracks.setReference(gray: _panningWorldFrame(), width: 128, height: 128);

    final twoPixelStep = tracks.advance(
      gray: _panningWorldFrame(shiftX: 2),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
    );
    final fivePixelStep = tracks.advance(
      gray: _panningWorldFrame(shiftX: 5),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
    );

    expect(twoPixelStep, isNotNull);
    expect(
      twoPixelStep!.vinsMeanStepNormalizedParallax,
      closeTo(2 / 128, 0.004),
    );
    expect(twoPixelStep.isVinsEstimatorKeyframeCandidate, isFalse);
    expect(fivePixelStep, isNotNull);
    expect(
      fivePixelStep!.vinsMeanStepNormalizedParallax,
      closeTo(3 / 128, 0.004),
    );
    expect(fivePixelStep.isVinsEstimatorKeyframeCandidate, isTrue);
  });

  test('VINS F-RANSAC removes tracks inconsistent with dominant geometry', () {
    final tracks = ContinuousFeatureTracks();
    tracks.setReference(gray: _panningWorldFrame(), width: 128, height: 128);

    final evidence = tracks.advance(
      gray: _piecewiseMotionFrame(),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
    );

    expect(evidence, isNotNull);
    expect(evidence!.vinsGeometricInputCount, greaterThanOrEqualTo(40));
    expect(
      evidence.vinsGeometricInlierCount,
      lessThan(evidence.vinsGeometricInputCount - 5),
    );
    expect(evidence.vinsGeometricInlierFraction, inInclusiveRange(0.5, 0.97));
  });

  test('actual-photo one-shot comparison also rejects geometric outliers', () {
    final evidence = trackFrameNovelty(
      previousGray: _panningWorldFrame(),
      currentGray: _piecewiseMotionFrame(),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
    );

    expect(evidence.vinsClaheApplied, isTrue);
    expect(evidence.vinsGeometricInputCount, greaterThanOrEqualTo(40));
    expect(
      evidence.vinsGeometricInlierCount,
      lessThan(evidence.vinsGeometricInputCount - 5),
    );
    expect(evidence.vinsGeometricInlierFraction, inInclusiveRange(0.5, 0.97));
  });

  test('VINS under-20 remains estimator metadata but not shutter evidence', () {
    final evidence = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 19,
      commonTrackFraction: 19 / 114,
      medianPixelDisplacement: 26.8,
      medianNormalizedDisplacement: 0.21,
      captureNoveltyThresholdNormalized: _shutterBar,
    );

    expect(evidence.comparable, isFalse);
    expect(evidence.lostTrackedOverlap, isTrue);
    expect(evidence.isVinsEstimatorKeyframeCandidate, isTrue);
    expect(evidence.isCaptureNoveltyVerified, isFalse);
  });

  test('featureless frames do not masquerade as track-loss keyframes', () {
    final evidence = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      captureNoveltyThresholdNormalized: _shutterBar,
    );

    expect(evidence.lostTrackedOverlap, isFalse);
    expect(evidence.isVinsEstimatorKeyframeCandidate, isFalse);
    expect(evidence.isCaptureNoveltyVerified, isFalse);
  });

  test('official-normalized LK evidence rejects a one-pixel duplicate', () {
    final evidence = trackFrameNovelty(
      previousGray: _texturedFrame(),
      currentGray: _texturedFrame(shiftX: 1),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
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
      principalXPixels: 64,
      principalYPixels: 64,
    );

    expect(evidence.comparable, isTrue);
    expect(evidence.commonTrackCount, greaterThanOrEqualTo(20));
    expect(
      evidence.medianNormalizedDisplacement,
      greaterThanOrEqualTo(10 / 460),
    );
    expect(evidence.hasEnoughNovelty, isTrue);
    expect(
      evidence.isCaptureNoveltyVerified,
      isFalse,
      reason: 'VINS estimator parallax is not a consumer-camera shutter gate',
    );
  });

  test('ten percent of the short edge verifies photographic novelty', () {
    final evidence = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 14,
      medianNormalizedDisplacement: 14 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );

    expect(evidence.comparable, isTrue);
    expect(evidence.medianPixelDisplacement, greaterThanOrEqualTo(12.8));
    expect(evidence.isCaptureNoveltyVerified, isTrue);
  });

  test('flat frames are explicitly incomparable rather than guessed new', () {
    final evidence = trackFrameNovelty(
      previousGray: Uint8List(128 * 128)..fillRange(0, 128 * 128, 128),
      currentGray: Uint8List(128 * 128)..fillRange(0, 128 * 128, 128),
      width: 128,
      height: 128,
      focalXPixels: 128,
      focalYPixels: 128,
      principalXPixels: 64,
      principalYPixels: 64,
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
        principalXPixels: 64,
        principalYPixels: 64,
      );
    }
    watch.stop();
    expect(watch.elapsedMilliseconds / 3, lessThan(100));
  });
}
