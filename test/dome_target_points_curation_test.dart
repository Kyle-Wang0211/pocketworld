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
    bool withJpeg = true,
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
      jpegPath: withJpeg ? '/tmp/f$id.jpg' : null,
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

  test('late JPEG commit stamps by frame identity, never a reused slot', () {
    final points = DomeTargetPoints(
      config: const DomePointConfig(
        equatorAzCount: 1,
        elCount: 1,
        minElevationDeg: 0,
        maxElevationDeg: 0,
      ),
    );

    // The default per-cell buffer holds 12 frames. The thirteenth forced
    // capture reuses a slot while f0 is still waiting for native publication.
    for (var i = 0; i < 13; i++) {
      final admitted = points.forceAdmit(
        sample(id: i, azimuth: 0, timestamp: 0, withJpeg: false),
      );
      expect(admitted, isNotNull);
    }

    expect(
      points.stampJpegPathForFrame(frameId: 'f0', jpegPath: '/tmp/f0.jpg'),
      isFalse,
      reason: 'An evicted job must not stamp its old slot onto a newer frame.',
    );
    expect(
      points.stampJpegPathForFrame(frameId: 'f12', jpegPath: '/tmp/f12.jpg'),
      isTrue,
    );
    expect(points.retainedJpegPaths, ['/tmp/f12.jpg']);
  });
}
