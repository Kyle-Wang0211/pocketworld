import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/cloud_capture_uploader.dart';

void main() {
  test('prepares frame manifest with per-file SHA256 checksums', () async {
    final root = await Directory.systemTemp.createTemp('cloud_capture_test_');
    try {
      final photosDir = Directory('${root.path}/photos')
        ..createSync(recursive: true);
      final image = File('${photosDir.path}/cell_0_slot_0.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final metadata = File('${photosDir.path}/cell_0_slot_0.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'timestamp': 1.25,
            'pose_source': 'arkit',
          }),
        );
      final manifest = File('${root.path}/capture_manifest.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'schema': 'pocketworld.capture_manifest.v1',
            'capture_id': 'cap_test',
            'created_at': '2026-05-21T08:00:00.000Z',
            'photos_dir': photosDir.path,
            'photo_count': 1,
            'frames': <Object?>[
              <String, Object?>{
                'image_path': image.path,
                'metadata_path': metadata.path,
                'image_file': 'cell_0_slot_0.jpg',
                'metadata_file': 'cell_0_slot_0.json',
              },
            ],
          }),
        );

      final prepared = await const CloudCaptureManifestPreparer().prepare(
        captureManifestFile: manifest,
        photosDir: photosDir,
      );

      expect(prepared.clientCaptureId, 'cap_test');
      expect(prepared.frameCount, 1);
      expect(prepared.totalBytes, image.lengthSync() + metadata.lengthSync());
      expect(prepared.localManifestSha256, await sha256ForFile(manifest));
      expect(prepared.frames.single.imageSha256, await sha256ForFile(image));
      expect(
        prepared.frames.single.metadataSha256,
        await sha256ForFile(metadata),
      );

      final cloudFrame = prepared.frames.single.toCloudJson(
        imageStoragePath: 'u/s/frames/cell_0_slot_0.jpg',
        metadataStoragePath: 'u/s/frames/cell_0_slot_0.json',
      );
      final cloudManifest = prepared.toCloudJson(
        userId: 'u',
        scanId: 's',
        cloudManifestPath: 'u/s/manifest/capture_manifest.json',
        uploadedAt: DateTime.utc(2026, 5, 21, 8),
        cloudFrames: <Map<String, Object?>>[cloudFrame],
      );

      expect(cloudManifest['schema'], 'pocketworld.cloud_capture_manifest.v1');
      expect(cloudManifest['frame_count'], 1);
      expect(
        cloudManifest['client_manifest'],
        containsPair('sha256', prepared.localManifestSha256),
      );
      expect(
        ((cloudManifest['frames'] as List).single
            as Map<String, Object?>)['image'],
        containsPair('storage_path', 'u/s/frames/cell_0_slot_0.jpg'),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('rejects missing metadata sidecar', () async {
    final root = await Directory.systemTemp.createTemp('cloud_capture_test_');
    try {
      final photosDir = Directory('${root.path}/photos')
        ..createSync(recursive: true);
      final image = File('${photosDir.path}/cell_0_slot_0.jpg')
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      final manifest = File('${root.path}/capture_manifest.json')
        ..writeAsStringSync(
          jsonEncode(<String, Object?>{
            'capture_id': 'cap_test',
            'created_at': '2026-05-21T08:00:00.000Z',
            'frames': <Object?>[
              <String, Object?>{
                'image_path': image.path,
                'metadata_path': '${photosDir.path}/cell_0_slot_0.json',
              },
            ],
          }),
        );

      await expectLater(
        const CloudCaptureManifestPreparer().prepare(
          captureManifestFile: manifest,
          photosDir: photosDir,
        ),
        throwsA(isA<CloudCaptureUploadException>()),
      );
    } finally {
      await root.delete(recursive: true);
    }
  });
}
