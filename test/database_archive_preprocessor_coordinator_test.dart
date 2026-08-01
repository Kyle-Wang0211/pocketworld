import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_preprocessor.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_coordinator.dart';

void main() {
  test(
    'production activity cancels SQLite preprocessing immediately',
    () async {
      final preprocessor = _CountingPreprocessor();
      final coordinator = PhotoArchiveCoordinator(
        codec: _UnsupportedPhotoCodec(),
        databasePreprocessor: preprocessor,
      );

      final lease = coordinator.beginCaptureActivity();

      expect(preprocessor.cancelCalls, 1);
      await lease.close();
    },
  );

  test('system interruption cancels SQLite preprocessing immediately', () {
    final preprocessor = _CountingPreprocessor();
    final coordinator = PhotoArchiveCoordinator(
      codec: _UnsupportedPhotoCodec(),
      databasePreprocessor: preprocessor,
    );

    coordinator.requestSystemInterruption();

    expect(preprocessor.cancelCalls, 1);
  });
}

class _CountingPreprocessor implements DatabaseArchivePreprocessor {
  int cancelCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> transformTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) async {}

  @override
  Future<void> restoreTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) async {}

  @override
  void requestCancellation() => cancelCalls++;
}

class _UnsupportedPhotoCodec implements PhotoArchiveCodec {
  @override
  bool get isSupported => false;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) {
    throw UnsupportedError('not used');
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) {
    throw UnsupportedError('not used');
  }

  @override
  void requestCancellation() {}
}
