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

  test(
    'loss of once-healthy capture tracks is an official keyframe signal',
    () {
      const evidence = FrameTrackEvidence(
        seedTrackCount: 114,
        commonTrackCount: 19,
        commonTrackFraction: 19 / 114,
        medianPixelDisplacement: 26.8,
        medianNormalizedDisplacement: 0.21,
      );

      expect(evidence.comparable, isFalse);
      expect(evidence.lostTrackedOverlap, isTrue);
      expect(evidence.isKeyframeCandidate, isTrue);
    },
  );

  test('featureless frames do not masquerade as track-loss keyframes', () {
    const evidence = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
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
