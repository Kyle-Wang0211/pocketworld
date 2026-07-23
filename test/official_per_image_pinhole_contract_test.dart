import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pocketWorld = Directory.current;
  final officialSource = File(
    '${pocketWorld.parent.path}/Aether3D-cross/'
    'aether_cpp/official_pipeline/src/official_aether_sfm_c.cc',
  );

  test('official route uses one fixed ARKit PINHOLE camera per image', () {
    expect(officialSource.existsSync(), isTrue);
    final source = officialSource.readAsStringSync();

    expect(source, contains('colmap::PinholeCameraModel::model_id'));
    expect(
      source,
      isNot(
        contains(
          'colmap::kInvalidCameraId, '
          'colmap::SimplePinholeCameraModel::model_id',
        ),
      ),
    );
    expect(source, contains('camera.SetFocalLengthX(fx);'));
    expect(source, contains('camera.SetFocalLengthY(fy);'));
    expect(source, contains('camera.SetPrincipalPointX(cx);'));
    expect(source, contains('camera.SetPrincipalPointY(cy);'));
    expect(source, contains('rec.camera_id = camera_id;'));
    expect(source, contains('rec.camera = camera;'));
    expect(source, contains('image.SetCameraId(camera_id);'));
    expect(source, contains('rimg.SetCameraId(rec.camera_id);'));
  });

  test('official geometry uses each image camera through COLMAP APIs', () {
    final source = officialSource.readAsStringSync();

    expect(source, contains('CopyNormalizedPoints(a.camera, a.points, xy_a);'));
    expect(source, contains('CopyNormalizedPoints(b.camera, b.points, xy_b);'));
    expect(
      source,
      contains(
        'colmap::EstimateTwoViewGeometry(\n'
        '      a.camera, a.points, b.camera, b.points',
      ),
    );
    expect(source, contains('prev.camera.CamFromImg(prev.points[i1])'));
    expect(source, contains('rec.camera.CamFromImg(rec.points[i2])'));
    expect(source, contains('prev.camera.ImgFromCam(X_prev)'));
    expect(source, contains('rec.camera.ImgFromCam(X_cur)'));
  });

  test('official BA fixes every per-image camera intrinsic block', () {
    final source = officialSource.readAsStringSync();

    expect(source, contains('SetAllCameraIntrinsicsConstant('));
    expect(
      source,
      contains('config.SetConstantCamIntrinsics(image.CameraId());'),
    );
  });
}
