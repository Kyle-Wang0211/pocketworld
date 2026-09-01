import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';
import 'package:pocketworld_flutter/official_capture/official_actual_photo_gate.dart';

Uint8List _texture({required int shiftX}) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sx = x - shiftX;
      if (sx < 0 || sx >= side) continue;
      out[y * side + x] =
          ((sx * 37 + y * 19 + ((sx ~/ 8 + y ~/ 8).isEven ? 91 : 17)) & 0xff)
              .toInt();
    }
  }
  return out;
}

AcceptedPhotoRecord _record({required bool noveltyVerified}) => AcceptedPhotoRecord(
  transactionId: 'tx-1',
  generation: 1,
  frameId: 'f-1',
  jpegPath: '/tmp/a.jpg',
  previewPath: '/tmp/a_preview.jpg',
  automaticSelection: true,
  imageWidth: 4032,
  imageHeight: 3024,
  triggerTimestamp: 1.0,
  captureTimestamp: 1.5,
  cameraTransform: List<double>.filled(16, 0),
  intrinsics: const <double>[460, 460, 2016, 1512],
  captureKind: 'highres',
  poseSyncQuality: 'exact',
  trackingStateName: 'normal',
  gray128Base64: null,
  sample: const <String, Object?>{},
  quality: const <String, Object?>{},
  noveltyVerified: noveltyVerified,
);

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
  const intrinsics = <double>[460, 460, 2016, 1512];

  test('only an accepted actual still advances the actual-photo baseline', () {
    final gate = OfficialActualPhotoGate();
    final first = gate.evaluate(
      gray128: _texture(shiftX: 0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(first.decision, OfficialActualPhotoDecision.accept);
    expect(gate.acceptedCount, 0);
    gate.commitAccepted(
      transactionId: 'tx-1',
      gray128: _texture(shiftX: 0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
    );
    expect(gate.acceptedCount, 1);
    gate.commitAccepted(
      transactionId: 'tx-1',
      gray128: _texture(shiftX: 0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
    );
    expect(
      gate.acceptedCount,
      1,
      reason: 'projection replay is idempotent by transaction identity',
    );

    final duplicate = gate.evaluate(
      gray128: _texture(shiftX: 0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(duplicate.decision, OfficialActualPhotoDecision.rejectDuplicate);
    expect(gate.acceptedCount, 1);

    expect(gate.acceptedCount, 1);
  });

  test('blur and missing actual evidence fail closed without advancing', () {
    final gate = OfficialActualPhotoGate();
    expect(
      gate
          .evaluate(
            gray128: _texture(shiftX: 0),
            imageWidth: 4032,
            imageHeight: 3024,
            intrinsics: intrinsics,
            qualityAccepted: false,
          )
          .decision,
      OfficialActualPhotoDecision.rejectQuality,
    );
    expect(
      gate
          .evaluate(
            gray128: null,
            imageWidth: 4032,
            imageHeight: 3024,
            intrinsics: intrinsics,
            qualityAccepted: true,
          )
          .decision,
      OfficialActualPhotoDecision.rejectMissingEvidence,
    );
    expect(gate.acceptedCount, 0);
  });

  test(
    'a sharp actual photograph with healthy-seed VINS track loss is novel',
    () {
      final evidence = FrameTrackEvidence(
        seedTrackCount: 114,
        commonTrackCount: 19,
        commonTrackFraction: 19 / 114,
        medianPixelDisplacement: 26.8,
        medianNormalizedDisplacement: 0.21,
        captureNoveltyThresholdNormalized: _shutterBar,
      );

      expect(evidence.lostTrackedOverlap, isTrue);
      expect(officialActualPhotoTrackAccepted(evidence), isTrue);
    },
  );

  test('VINS estimator parallax is below the photographic shutter scale', () {
    final estimatorOnly = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 100,
      commonTrackFraction: 100 / 114,
      medianPixelDisplacement: 4,
      medianNormalizedDisplacement: 4 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    final photographic = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 100,
      commonTrackFraction: 100 / 114,
      medianPixelDisplacement: 14,
      medianNormalizedDisplacement: 14 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );

    expect(estimatorOnly.isVinsEstimatorKeyframeCandidate, isTrue);
    expect(officialActualPhotoTrackAccepted(estimatorOnly), isFalse);
    expect(officialActualPhotoTrackAccepted(photographic), isTrue);
  });

  group('a non-novel actual still is retained, not destroyed', () {
    // Provenance for the whole group: upstream VINS-Mono
    // FeatureManager::addFeatureCheckParallax() returns a MARGINALIZATION
    // STRATEGY, not a keep/discard verdict. Its false branch
    // (MARGIN_SECOND_NEW -> Estimator::slideWindowNew) keeps the new frame and
    // merges the dropped frame's IMU forward. Wiring that boolean to a delete
    // was this replication's one real divergence, and it destroyed 22 of 120
    // twelve-megapixel photos in the 2026-08-30 device telemetry, several less
    // than 1 px under the displacement bar.

    test('the record carries the verdict and defaults to novel when absent', () {
      final novel = _record(noveltyVerified: true);
      final retained = _record(noveltyVerified: false);

      expect(novel.noveltyVerified, isTrue);
      expect(retained.noveltyVerified, isFalse);
      expect(novel.toJson()['noveltyVerified'], isTrue);
      expect(retained.toJson()['noveltyVerified'], isFalse);

      // Round-trip, so a non-novel photo stays non-novel across a replay.
      expect(
        AcceptedPhotoRecord.fromJson(retained.toJson()).noveltyVerified,
        isFalse,
      );
      expect(retained.copyWith().noveltyVerified, isFalse);

      // Records written before the field existed could only be produced on the
      // accepting branch, so their absent value must read as novel.
      final legacy = Map<String, Object?>.from(novel.toJson())
        ..remove('noveltyVerified');
      expect(AcceptedPhotoRecord.fromJson(legacy).noveltyVerified, isTrue);

      // The verdict is part of identity: it is in canonicalJson, so a record
      // cannot silently change novelty under the immutability conflict check.
      expect(novel == retained, isFalse);
    });

    test('the duplicate verdict reaches the commit path, not the reject path', () {
      final source = File(
        'lib/official_capture/capture_session.dart',
      ).readAsStringSync();

      // The discard branch must exclude the duplicate verdict.
      expect(
        source,
        contains('if (!actualGate.accepted && !retainedAsNonNovel) {'),
        reason: 'a duplicate verdict must not enter the artifact-delete branch',
      );
      expect(
        source,
        contains('OfficialActualPhotoDecision.rejectDuplicate;'),
      );
      // ...and the commit must carry the verdict rather than assume novelty.
      expect(source, contains('noveltyVerified: actualGate.accepted,'));
      expect(
        source,
        isNot(contains('noveltyVerified: true,\n                    automaticSelection')),
      );
    });

    test('only a novel photo advances the gate baseline', () {
      final source = File(
        'lib/official_capture/capture_session.dart',
      ).readAsStringSync();
      final start = source.indexOf(
        'AcceptedPhotoProjection.actualPhotoGate: (record) {',
      );
      final end = source.indexOf('AcceptedPhotoProjection.geometry:', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final projection = source.substring(start, end);

      expect(projection, contains('if (!record.noveltyVerified) return;'));
      expect(
        projection.indexOf('if (!record.noveltyVerified) return;'),
        lessThan(projection.indexOf('_automaticActualPhotoGate.commitAccepted(')),
        reason:
            'advancing the baseline on every retained photo would reset the '
            'displacement measurement each shutter, so a slow pan could never '
            'accumulate past the bar',
      );
    });
  });

  test('the bar is the same real motion on either axis', () {
    // This is the whole point of moving the comparison out of grid pixels.
    // A real displacement equal to ten percent of the ORIGINAL short edge must
    // clear the bar exactly, whichever axis it happens along. Before the fix
    // the comparison was a raw count on a squashed square grid, so the same
    // real motion read 4/3 larger vertically and the bar was effectively 10.0%
    // of the short edge for vertical motion but 13.3% for horizontal.
    const originalWidth = 4032.0;
    const originalHeight = 3024.0;
    final realPixels = kOfficialCaptureMotionStepFraction * originalHeight;

    final gridDx = realPixels * 128.0 / originalWidth; // purely horizontal
    final gridDy = realPixels * 128.0 / originalHeight; // purely vertical

    // Normalized, both are the bar — to the last bit.
    expect(gridDx / _fx128, closeTo(_shutterBar, 1e-12));
    expect(gridDy / _fy128, closeTo(_shutterBar, 1e-12));

    // As raw grid pixels they are NOT equal, and that inequality was the bug.
    expect(gridDy / gridDx, closeTo(originalWidth / originalHeight, 1e-12));
    expect(gridDx, lessThan(gridDy));

    // The retired bar (gridSide * fraction) was calibrated for exactly one
    // axis: vertical motion of ten percent of the short edge lands on it to the
    // bit, while identical horizontal motion falls 25% short and was rejected.
    const retiredBar = 128.0 * kOfficialCaptureMotionStepFraction;
    expect(gridDy, closeTo(retiredBar, 1e-9));
    expect(gridDx, lessThan(retiredBar));
    expect(gridDx / retiredBar, closeTo(originalHeight / originalWidth, 1e-12));
  });

  test('the bar refuses to guess when the focals are unusable', () {
    for (final bad in <List<double>>[
      <double>[double.nan, _fy128],
      <double>[_fx128, double.infinity],
      <double>[0, _fy128],
      <double>[_fx128, -1],
    ]) {
      final bar = kOfficialCaptureNoveltyThreshold(
        gridWidth: 128,
        gridHeight: 128,
        focalXPixels: bad[0],
        focalYPixels: bad[1],
      );
      expect(bar.isNaN, isTrue);
      final evidence = FrameTrackEvidence(
        seedTrackCount: 114,
        commonTrackCount: 100,
        commonTrackFraction: 100 / 114,
        medianPixelDisplacement: 1000,
        medianNormalizedDisplacement: 10,
        captureNoveltyThresholdNormalized: bar,
      );
      expect(
        evidence.isCaptureNoveltyVerified,
        isFalse,
        reason: 'an unusable bar must fail closed, not admit everything',
      );
    }
  });
}
