import 'package:official_capture_services/official_capture_services.dart';

void main() {
  const service = PhotoBundleService();
  final manifest = <String, Object?>{
    'schemaVersion': 'aether_photo_bundle_v1',
    'photosHighresDir': 'photos_highres',
    'previewsDir': 'previews',
    'colmapSparseDir': 'colmap/sparse/0',
    'frames': [_frame('a', 0, 0, 0, 0), _frame('b', 0.14, 0, 0.12, 0.02)],
  };

  final viewGraph = service.buildViewGraph(manifest);
  final report = service.validateBundle(manifest, viewGraph: viewGraph);
  if (viewGraph['edgeCount'] != 1 || report['status'] == 'fail') {
    throw StateError('photo bundle service smoke failed: $viewGraph $report');
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
