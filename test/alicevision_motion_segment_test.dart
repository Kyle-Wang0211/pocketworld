import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/alicevision_motion_segment.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';

FrameTrackEvidence _step(double pixels) => FrameTrackEvidence(
  seedTrackCount: 100,
  commonTrackCount: 80,
  commonTrackFraction: 0.8,
  medianPixelDisplacement: pixels,
  medianNormalizedDisplacement: pixels / 128,
  medianStepPixelDisplacement: pixels,
);

void main() {
  test('official 10 percent motion step is normalized by the short edge', () {
    final segment = AliceVisionMotionSegment(width: 128, height: 128);

    expect(segment.add(_step(4)), isFalse);
    expect(segment.add(_step(4)), isFalse);
    expect(segment.add(_step(4)), isFalse);
    expect(segment.accumulatedPixelMotion, 12);
    expect(segment.add(_step(4)), isTrue);
    expect(segment.accumulatedPixelMotion, 16);
  });

  test('track loss is reseeded evidence, never free motion credit', () {
    final segment = AliceVisionMotionSegment(width: 128, height: 128);
    const lost = FrameTrackEvidence(
      seedTrackCount: 100,
      commonTrackCount: 10,
      commonTrackFraction: 0.1,
      medianPixelDisplacement: 30,
      medianNormalizedDisplacement: 0.2,
      medianStepPixelDisplacement: double.nan,
    );

    expect(segment.add(lost), isFalse);
    expect(segment.accumulatedPixelMotion, 0);
  });

  test('a real photo resets the accumulated motion subsequence', () {
    final segment = AliceVisionMotionSegment(width: 128, height: 128);
    segment.add(_step(16));
    expect(segment.ready, isTrue);
    segment.reset();
    expect(segment.ready, isFalse);
    expect(segment.accumulatedPixelMotion, 0);
  });
}
