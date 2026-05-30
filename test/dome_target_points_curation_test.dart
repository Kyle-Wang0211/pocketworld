import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/dome/captured_frame_sample.dart';
import 'package:pocketworld_flutter/capture/dome/dome_config.dart';
import 'package:pocketworld_flutter/capture/dome/dome_target_points.dart';

void main() {
  CapturedFrameSample sample({
    required int id,
    required double azimuth,
    required double timestamp,
    double sharpness = 900,
    double scaleReliability = 0.7,
    double cameraRadiusM = 1.0,
  }) {
    return CapturedFrameSample(
      timestamp: timestamp,
      azimuth: azimuth,
      elevation: 0,
      sharpness: sharpness,
      cameraRadiusM: cameraRadiusM,
      roiSharpness: sharpness,
      multiScaleSharpness252: sharpness,
      multiScaleSharpness512: sharpness,
      edgeBlockSharpness: sharpness,
      sharpnessConsensus: sharpness,
      motionScore: 0.1,
      exposureScore: 0.95,
      meanBrightness: 128,
      frameId: 'f$id',
      jpegPath: '/tmp/f$id.jpg',
      scaleAlignAnchorCount: 40,
      scaleAlignDepthSpanM: 0.35,
      scaleAlignReliabilityPrior: scaleReliability,
    );
  }

  test('curateForUpload can spend unused budget on sparse active cells', () {
    final points = DomeTargetPoints(
      config: const DomePointConfig(
        equatorAzCount: 1,
        elCount: 1,
        minElevationDeg: 0,
        maxElevationDeg: 0,
      ),
    );

    for (var i = 0; i < 8; i++) {
      points.ingest(sample(id: i, azimuth: i * 0.01, timestamp: i * 0.2));
    }

    final curated = points.curateForUpload(framesPerPoint: 5);
    expect(curated, hasLength(8));
    expect(curated.map((f) => f.cellRankInTopK), [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test('curateForUpload favors pose diversity over near-duplicates', () {
    final points = DomeTargetPoints(
      config: const DomePointConfig(
        equatorAzCount: 1,
        elCount: 1,
        minElevationDeg: 0,
        maxElevationDeg: 0,
      ),
    );

    for (var i = 0; i < 5; i++) {
      points.ingest(sample(id: i, azimuth: i * 0.001, timestamp: i * 0.05));
    }
    points.ingest(
      sample(id: 99, azimuth: 0.08, timestamp: 1.0, sharpness: 820),
    );

    final curated = points.curateForUpload(targetTotal: 2, framesPerPoint: 2);
    expect(curated, hasLength(2));
    expect(curated.map((f) => f.sample.frameId), contains('f99'));
  });

  test('session graph excludes isolated radius jumps from K=3 curation', () {
    final points = DomeTargetPoints(
      config: const DomePointConfig(
        equatorAzCount: 1,
        elCount: 1,
        minElevationDeg: 0,
        maxElevationDeg: 0,
      ),
    );

    for (var i = 0; i < 5; i++) {
      points.ingest(
        sample(
          id: i,
          azimuth: i * 0.012,
          timestamp: i * 0.25,
          cameraRadiusM: 1.0 + i * 0.03,
        ),
      );
    }
    points.ingest(
      sample(id: 99, azimuth: 0.04, timestamp: 2.0, cameraRadiusM: 5.0),
    );

    final curated = points.curateForUpload(targetTotal: 5, framesPerPoint: 5);
    expect(curated, hasLength(5));
    expect(curated.map((f) => f.sample.frameId), isNot(contains('f99')));
    expect(curated.every((f) => f.radiusShellId == 0), isTrue);
  });
}
