import 'dart:convert';
import 'dart:io';

import 'package:aether_capture_services/aether_capture_services.dart';
import 'package:image/image.dart' as image;

Future<void> main() async {
  final bundleDir = await Directory.systemTemp.createTemp('aether_bundle_');
  try {
    Directory('${bundleDir.path}/photos_highres').createSync();
    Directory('${bundleDir.path}/previews').createSync();
    for (final id in ['a', 'b']) {
      final jpeg = _jpegFixture(id == 'a' ? 24 : 48);
      File('${bundleDir.path}/photos_highres/$id.jpg').writeAsBytesSync(jpeg);
      File('${bundleDir.path}/previews/$id.jpg').writeAsBytesSync(jpeg);
    }
    File('${bundleDir.path}/photo_bundle.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'previewsDir': 'previews',
        'frames': [_frame('a', 0, 0, 0, 0), _frame('b', 0.14, 0, 0.12, 0.02)],
      }),
    );

    final result = await const PhotoBundleDerivationService().deriveDirectory(
      bundleDir,
    );
    if (result.status == 'fail' ||
        result.frameCount != 2 ||
        result.edgeCount != 1 ||
        result.colmapFrameCount != 2) {
      throw StateError('unexpected derivation result: ${result.status}');
    }
    for (final relativePath in [
      'colmap/sparse/0/cameras.txt',
      'colmap/sparse/0/images.txt',
      'colmap/sparse/0/points3D.txt',
      'view_graph.json',
      'bundle_validation.json',
      'stages/capture_audit/arkit_sparse_pointcloud_audit.json',
      'stages/capture_audit/arkit_sparse_anchors_world.ply',
      'stages/capture_audit/arkit_camera_path_world.ply',
    ]) {
      if (!File('${bundleDir.path}/$relativePath').existsSync()) {
        throw StateError('missing derived artifact: $relativePath');
      }
    }
  } finally {
    await bundleDir.delete(recursive: true);
  }
}

Map<String, Object?> _frame(
  String id,
  double azimuth,
  double elevation,
  double x,
  double z,
) {
  return {
    'id': id,
    'highresFilename': '$id.jpg',
    'previewFilename': '$id.jpg',
    'timestamp': id == 'a' ? 1.0 : 2.0,
    'azimuth': azimuth,
    'elevation': elevation,
    'cameraRadiusM': 1.0,
    'radiusShellID': 'r_1.00_1.25m',
    'imageWidth': 4032,
    'imageHeight': 3024,
    'quality': {'score': 0.9, 'laplacianVariance': 500.0},
    'cameraTransform': [
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      0.0,
      0.0,
      0.0,
      1.0,
      0.0,
      x,
      0.0,
      z,
      1.0,
    ],
    'intrinsics': [2200.0, 2200.0, 2016.0, 1512.0],
  };
}

List<int> _jpegFixture(int seed) {
  final img = image.Image(width: 32, height: 24);
  for (var y = 0; y < img.height; y += 1) {
    for (var x = 0; x < img.width; x += 1) {
      img.setPixelRgb(x, y, (x * 3 + seed) % 255, (y * 5 + seed) % 255, 160);
    }
  }
  return image.encodeJpg(img, quality: 90);
}
