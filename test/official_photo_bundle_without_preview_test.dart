import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:official_capture_services/official_capture_services.dart';

void main() {
  group('future official photo bundles', () {
    test('new manifest has no durable preview directory', () {
      final manifest = const PhotoBundleManifestService().buildManifest(
        frames: const <PhotoBundleFrameDraft>[],
      );

      expect(manifest, isNot(contains('previewsDir')));
    });

    test('validation does not require preview files', () {
      final manifest = _manifestWithoutPreviews();
      final validation = const PhotoBundleService().validateBundle(
        manifest,
        fileExists: (relativePath) =>
            relativePath == 'photos_highres/frame.jpg' ||
            relativePath.startsWith('colmap/sparse/0/'),
      );
      final checks = (validation['checks'] as List)
          .cast<Map<String, Object?>>();

      expect(
        checks.map((check) => check['id']),
        isNot(contains('preview_files')),
      );
      expect(validation['errors'], isNot(contains('missing preview files: 1')));
    });

    test('transport excludes preview directory', () {
      final transport = const PhotoBundlePipelinePolicyService()
          .buildTransportManifest(_manifestWithoutPreviews());
      final requiredEntries = (transport['requiredEntries'] as List)
          .cast<String>();

      expect(requiredEntries, isNot(contains('previews')));
    });

    test('derivation does not recreate previews', () async {
      final root = await Directory.systemTemp.createTemp(
        'official-no-preview-',
      );
      addTearDown(() => root.delete(recursive: true));
      final highres = Directory('${root.path}/photos_highres');
      await highres.create(recursive: true);
      final jpeg = image.encodeJpg(image.Image(width: 4, height: 4));
      await File('${highres.path}/frame.jpg').writeAsBytes(jpeg, flush: true);
      await File('${highres.path}/frame.json').writeAsString(
        jsonEncode({
          't': 200000,
          'image_w': 4,
          'image_h': 4,
          'extrinsic': _identityTransform,
          'intrinsics_fxfycxcy': [4.0, 4.0, 2.0, 2.0],
          'anchors_world': const <Object?>[],
        }),
        flush: true,
      );
      final manifestFile = File('${root.path}/official_photo_bundle.json');
      await manifestFile.writeAsString(
        jsonEncode(_manifestWithoutPreviews()),
        flush: true,
      );

      await const PhotoBundleDerivationService().deriveDirectory(root);

      final derivedManifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      expect(await Directory('${root.path}/previews').exists(), isFalse);
      expect(derivedManifest, isNot(contains('previewsDir')));
      final frames = (derivedManifest['frames'] as List).cast<Map>();
      expect(frames.single, isNot(contains('previewFilename')));
    });

    test('explicit legacy preview contract remains readable', () {
      final manifest = _manifestWithoutPreviews();
      manifest['previewsDir'] = 'previews';
      final frames = (manifest['frames'] as List).cast<Map<String, Object?>>();
      frames.single['previewFilename'] = 'frame-preview.jpg';

      final validation = const PhotoBundleService().validateBundle(
        manifest,
        fileExists: (relativePath) =>
            relativePath == 'photos_highres/frame.jpg' ||
            relativePath.startsWith('colmap/sparse/0/'),
      );
      final checks = (validation['checks'] as List)
          .cast<Map<String, Object?>>();
      final previewCheck = checks.singleWhere(
        (check) => check['id'] == 'preview_files',
      );
      final transport = const PhotoBundlePipelinePolicyService()
          .buildTransportManifest(manifest);

      expect(previewCheck['status'], 'fail');
      expect(
        (transport['requiredEntries'] as List).cast<String>(),
        contains('previews'),
      );
    });
  });
}

Map<String, Object?> _manifestWithoutPreviews() => {
  'schemaVersion': 'aether_photo_bundle_v1',
  'captureVersion': 3,
  'sourceKind': 'arkit_high_res_still',
  'photosHighresDir': 'photos_highres',
  'processingTier': 'high',
  'frames': [
    {
      'id': 'frame',
      'highresFilename': 'frame.jpg',
      'timestamp': 200000.0,
      'triggerTimestamp': 200000.0,
      'azimuth': 0.0,
      'elevation': 0.0,
      'captureKind': 'arkit_high_res_still',
      'poseSyncQuality': 'ar_session_high_res_frame',
      'imageWidth': 4,
      'imageHeight': 4,
      'quality': const <String, Object?>{},
      'cameraTransform': _identityTransform,
      'intrinsics': [4.0, 4.0, 2.0, 2.0],
    },
  ],
};

const List<double> _identityTransform = [
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
];
