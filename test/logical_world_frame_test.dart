import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/logical_world_frame.dart';
import 'package:vector_math/vector_math_64.dart';

Matrix4 _rigid({
  double tx = 0,
  double ty = 0,
  double tz = 0,
  double yawRadians = 0,
}) {
  final Matrix4 result = Matrix4.identity();
  result.setRotation(Matrix3.rotationY(yawRadians));
  result.setTranslationRaw(tx, ty, tz);
  return result;
}

void _expectMatrixClose(Matrix4 actual, Matrix4 expected) {
  for (var i = 0; i < 16; i++) {
    expect(actual.storage[i], closeTo(expected.storage[i], 1e-9), reason: '$i');
  }
}

void main() {
  test('keeps camera in the lock-time logical map after a 6DoF rebase', () {
    final Matrix4 lockAnchor = _rigid(tx: 1, ty: -2, tz: 3, yawRadians: 0.3);
    final Matrix4 logicalCamera = _rigid(
      tx: 2,
      ty: 1,
      tz: -4,
      yawRadians: -0.2,
    );
    final Matrix4 platformRebase = _rigid(
      tx: 5,
      ty: -1,
      tz: 2,
      yawRadians: 0.6,
    );
    final Matrix4 currentAnchor = platformRebase * lockAnchor;
    final Matrix4 rawCurrentCamera = platformRebase * logicalCamera;

    final LogicalWorldFrame frame = LogicalWorldFrame.lock(lockAnchor.storage);
    final LogicalWorldUpdate update = frame.update(currentAnchor.storage);

    _expectMatrixClose(
      update.logicalWorldFromPlatformWorld,
      platformRebase.clone()..invert(),
    );
    _expectMatrixClose(update.platformWorldFromLogicalWorld, platformRebase);
    _expectMatrixClose(
      update.toLogicalWorld(rawCurrentCamera.storage),
      logicalCamera,
    );
  });

  test('uses exact anchor motion without a relocalization threshold', () {
    final LogicalWorldFrame frame = LogicalWorldFrame.lock(
      Matrix4.identity().storage,
    );
    final LogicalWorldUpdate update = frame.update(
      _rigid(tx: 0.000001, yawRadians: 0.000001).storage,
    );

    expect(update.changed, isTrue);
    expect(
      update.platformWorldFromLogicalWorld.storage[12],
      closeTo(0.000001, 1e-12),
    );
  });

  test('rejects non-rigid anchor input instead of inventing a correction', () {
    final LogicalWorldFrame frame = LogicalWorldFrame.lock(
      Matrix4.identity().storage,
    );
    final List<double> scaled = Matrix4.identity().storage.toList();
    scaled[0] = 2;

    expect(() => frame.update(scaled), throwsFormatException);
  });
}
