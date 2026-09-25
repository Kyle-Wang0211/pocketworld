import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_card_state.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync(
      'official_project_photo_album_test_',
    );
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('commits each verified 12MP photo exactly once', () {
    final album = OfficialProjectPhotoAlbum();
    final first = File('${tempDir.path}/first.jpg')..writeAsBytesSync(<int>[1]);
    final second = File('${tempDir.path}/second.jpg')
      ..writeAsBytesSync(<int>[2]);

    expect(
      album.commitVerified(
        jpegPath: first.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
    );
    expect(
      album.commitVerified(
        jpegPath: first.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isFalse,
    );
    expect(
      album.commitVerified(
        jpegPath: second.path,
        captureTimestamp: 11,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
    );

    expect(album.count, 2);
    expect(album.paths, <String>[first.path, second.path]);
  });

  test('latest path follows commit, delete, and clear in O(1) read state', () {
    final album = OfficialProjectPhotoAlbum();
    final first = File('${tempDir.path}/latest-first.jpg')
      ..writeAsBytesSync(<int>[1]);
    final second = File('${tempDir.path}/latest-second.jpg')
      ..writeAsBytesSync(<int>[2]);

    expect(album.latestPath, isNull);
    expect(
      album.commitVerified(
        jpegPath: first.path,
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
    );
    expect(album.latestPath, first.path);
    expect(
      album.commitVerified(
        jpegPath: second.path,
        captureTimestamp: 11,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isTrue,
    );
    expect(album.latestPath, second.path);

    expect(album.remove(second.path), isTrue);
    expect(album.latestPath, first.path);
    album.clear();
    expect(album.latestPath, isNull);
  });

  // [ENTRY-ANY-4X3 2026-09-25] 原名「non-12MP」:判据改为任意 4:3、长边 >= 1920;
  // 1920x1440 现在合法,改用 16:9 / 长边不足 / 竖向三种不合判据的尺寸。
  test('never commits a missing or rule-violating file', () {
    final album = OfficialProjectPhotoAlbum();
    final preview = File('${tempDir.path}/preview.jpg')
      ..writeAsBytesSync(<int>[1]);

    expect(
      album.commitVerified(
        jpegPath: '${tempDir.path}/missing.jpg',
        captureTimestamp: 10,
        imageWidth: 4032,
        imageHeight: 3024,
      ),
      isFalse,
    );
    for (final (w, h) in const [(1920, 1080), (1440, 1080), (3024, 4032)]) {
      expect(
        album.commitVerified(
          jpegPath: preview.path,
          captureTimestamp: 10,
          imageWidth: w,
          imageHeight: h,
        ),
        isFalse,
        reason: '${w}x$h',
      );
    }
    expect(album.count, 0);
  });

  test('commits any 4:3 photo with long side >= 1920 (ENTRY-ANY-4X3)', () {
    final album = OfficialProjectPhotoAlbum();
    var i = 0;
    for (final (w, h) in const [(1920, 1440), (3264, 2448), (8064, 6048)]) {
      final f = File('${tempDir.path}/p${i++}.jpg')..writeAsBytesSync(<int>[1]);
      expect(
        album.commitVerified(
          jpegPath: f.path,
          captureTimestamp: 10.0 + i,
          imageWidth: w,
          imageHeight: h,
        ),
        isTrue,
        reason: '${w}x$h',
      );
    }
    expect(album.count, 3);
  });

  test('background lifecycle does not alter the project count', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    album.commitVerified(
      jpegPath: photo.path,
      captureTimestamp: 10,
      imageWidth: 4032,
      imageHeight: 3024,
    );

    // No lifecycle method is needed: the album belongs to the capture route,
    // not to a widget rebuild or the ring-buffer curation store.
    expect(album.count, 1);
    expect(album.paths, <String>[photo.path]);
  });

  test('deleting a project photo updates the single source of truth', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    album.commitVerified(
      jpegPath: photo.path,
      captureTimestamp: 10,
      imageWidth: 4032,
      imageHeight: 3024,
    );

    expect(album.remove(photo.path), isTrue);
    expect(album.count, 0);
    expect(album.paths, isEmpty);
  });

  test('analysis status never changes project membership or count', () {
    final album = OfficialProjectPhotoAlbum();
    final photo = File('${tempDir.path}/photo.jpg')..writeAsBytesSync(<int>[1]);
    album.commitVerified(
      jpegPath: photo.path,
      captureTimestamp: 10,
      imageWidth: 4032,
      imageHeight: 3024,
    );

    expect(album.photos.single.analysisState, PhotoCardSfmState.pending);
    expect(
      album.updateAnalysisState(photo.path, PhotoCardSfmState.disconnected),
      isTrue,
    );

    expect(album.count, 1);
    expect(album.paths, <String>[photo.path]);
    expect(album.photos.single.analysisState, PhotoCardSfmState.disconnected);
  });

  test('warns only after 20 analyzed photos and over 20 percent are red', () {
    final album = OfficialProjectPhotoAlbum();
    for (var i = 0; i < 20; i++) {
      final photo = File('${tempDir.path}/photo_$i.jpg')
        ..writeAsBytesSync(<int>[i]);
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: i.toDouble(),
        imageWidth: 4032,
        imageHeight: 3024,
      );
      album.updateAnalysisState(
        photo.path,
        i < 4 ? PhotoCardSfmState.disconnected : PhotoCardSfmState.registered,
      );
    }

    expect(album.analyzedCount, 20);
    expect(album.disconnectedCount, 4);
    expect(album.disconnectedRatio, 0.2);
    expect(album.shouldWarnDisconnected, isFalse);

    album.updateAnalysisState(
      '${tempDir.path}/photo_4.jpg',
      PhotoCardSfmState.disconnected,
    );
    expect(album.disconnectedCount, 5);
    expect(album.disconnectedRatio, 0.25);
    expect(album.shouldWarnDisconnected, isTrue);
  });

  test('pending photos do not enter the disconnected warning denominator', () {
    final album = OfficialProjectPhotoAlbum();
    for (var i = 0; i < 24; i++) {
      final photo = File('${tempDir.path}/photo_$i.jpg')
        ..writeAsBytesSync(<int>[i]);
      album.commitVerified(
        jpegPath: photo.path,
        captureTimestamp: i.toDouble(),
        imageWidth: 4032,
        imageHeight: 3024,
      );
      if (i < 19) {
        album.updateAnalysisState(
          photo.path,
          i < 5 ? PhotoCardSfmState.disconnected : PhotoCardSfmState.registered,
        );
      }
    }

    expect(album.count, 24);
    expect(album.analyzedCount, 19);
    expect(album.shouldWarnDisconnected, isFalse);
  });
}
