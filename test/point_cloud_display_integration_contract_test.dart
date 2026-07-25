import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Review renders the complete persisted point set', () {
    final source = File(
      'lib/ui/official_capture/sparse_cloud_view.dart',
    ).readAsStringSync();

    expect(source, contains('ReviewPointCloudPolicy.drawStrideFor(n)'));
    expect(source, isNot(contains('_maxDrawnPoints')));
  });

  test(
    'Capture sends a progressive display copy and keeps SfM source intact',
    () {
      final source = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();

      expect(source, contains('buildProgressivePointCloud'));
      expect(source, contains('snapshot.xyz'));
      expect(
        source,
        contains(
          'display-only: the source SfM snapshot and final PLY stay intact',
        ),
      );
    },
  );

  test(
    'iOS Capture renderer owns full buffers and only draws stable prefixes',
    () {
      final source = File(
        'ios/Runner/OfficialAetherARKitPlugin.swift',
      ).readAsStringSync();

      expect(source, contains('CapturePointCloudLodController'));
      expect(source, contains('fullPointCloudXyz'));
      expect(source, contains('fullPointCloudRgb'));
      expect(source, contains('prefix(renderCount * 3)'));
      expect(source, contains('ProcessInfo.processInfo.thermalState'));
      expect(source, contains('pointCloudLod.observeFrame'));
    },
  );
}
