import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

void main() {
  // 2026-09-01 修正单位错误:此前是 [460, 460, ...] 配 4032 的图宽,等于
  // 2·atan(2016/460) = 154° 的视场角 —— 没有这种镜头。那个 460 是从 VINS 的
  // FOCAL_LENGTH 抄来的,但它是虚拟归一化焦距,不是 4032 图上的像素焦距。
  //
  // 这个错误会让任何按「归一化后乘 460」口径工作的步骤(rejectWithF)拿到
  // 6.3 倍偏严的阈值。改成 iPhone 12MP 的实测量级:fx≈3200 → 约 65° 视场。
  const intrinsics = <double>[3200, 3200, 2016, 1512];

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
    expect(gate.acceptedCount, 1);

    final duplicate = gate.evaluate(
      gray128: _texture(shiftX: 0),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(duplicate.decision, OfficialActualPhotoDecision.rejectDuplicate);
    expect(gate.acceptedCount, 1);

    final novel = gate.evaluate(
      gray128: _texture(shiftX: 12),
      imageWidth: 4032,
      imageHeight: 3024,
      intrinsics: intrinsics,
      qualityAccepted: true,
    );
    expect(novel.trackEvidence, isNotNull);
    expect(
      novel.trackEvidence!.commonTrackCount,
      greaterThanOrEqualTo(kOfficialMinimumCommonTracks),
    );
    expect(novel.decision, OfficialActualPhotoDecision.accept);
    expect(gate.acceptedCount, 2);
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

  test('an actual still that loses tracks is not admitted as novelty', () {
    const evidence = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 19,
      commonTrackFraction: 19 / 114,
      medianPixelDisplacement: 26.8,
      medianNormalizedDisplacement: 0.21,
      meanNormalizedDisplacement: 0.21,
    );

    expect(officialActualPhotoTrackAccepted(evidence), isFalse);
  });
}
