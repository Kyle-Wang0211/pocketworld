import 'dart:typed_data';

import 'package:aether_capture_services/aether_capture_services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gray1024 still quality emits downstream weights', () {
    final plane = Uint8List(1024 * 1024);
    for (var y = 0; y < 1024; y += 1) {
      for (var x = 0; x < 1024; x += 1) {
        plane[y * 1024 + x] = (x ~/ 16).isEven ? 32 : 224;
      }
    }

    final quality = const PhotoBundleQualityService().evaluateLumaPlane(
      luma: plane,
      width: 1024,
      height: 1024,
      rowStride: 1024,
    );

    expect(quality.qualityPlaneWidth, 1024);
    expect(quality.qualityPlaneHeight, 1024);
    expect(quality.tenengradMean, greaterThan(0));
    expect(quality.centerRoiLaplacianVariance, greaterThan(0));
    expect(quality.viewGraphWeight, greaterThan(0));
    expect(quality.kWindowWeight, greaterThan(0));
    expect(quality.textureBestViewWeight, greaterThan(0));
  });

  test('gray1024 still quality rejects saturated frames', () {
    final plane = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 255);

    final quality = const PhotoBundleQualityService().evaluateLumaPlane(
      luma: plane,
      width: 1024,
      height: 1024,
      rowStride: 1024,
    );

    expect(quality.accepted, isFalse);
    expect(quality.overexposedRatio, 1);
    expect(quality.rejectReasons, contains('mean_luma_bright'));
  });
}
