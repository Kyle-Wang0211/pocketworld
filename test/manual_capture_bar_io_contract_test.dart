import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manual capture bar performs no synchronous full-album file scan', () {
    final source = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final start = source.indexOf('class _ManualCaptureBar');
    final end = source.indexOf('class _AlbumThumbButton', start);

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final captureBar = source.substring(start, end);
    expect(captureBar, contains('projectPhotos.latestPath'));
    expect(captureBar, isNot(contains('File(')));
    expect(captureBar, isNot(contains('existsSync')));
    expect(captureBar, isNot(contains('lastModifiedSync')));
    expect(captureBar, isNot(contains('projectPhotos.paths')));
  });
}
