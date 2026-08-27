import 'package:vector_math/vector_math_64.dart';

/// Cross-platform adapter that preserves the lock-time map coordinates when a
/// platform AR runtime rebases its own world frame.
///
/// This does not estimate motion or classify relocalization. It applies the
/// same map-frame invariant as XRSLAM's official AR demo: objects stay in one
/// map and the camera is expressed in that map.
class LogicalWorldFrame {
  LogicalWorldFrame._(this._lockPlatformWorldFromAnchor);

  factory LogicalWorldFrame.lock(List<double> platformWorldFromAnchor) {
    return LogicalWorldFrame._(_readRigid(platformWorldFromAnchor));
  }

  final Matrix4 _lockPlatformWorldFromAnchor;

  LogicalWorldUpdate update(List<double> currentPlatformWorldFromAnchor) {
    final Matrix4 current = _readRigid(currentPlatformWorldFromAnchor);
    final Matrix4 currentInverse = current.clone()..invert();
    final Matrix4 lockInverse = _lockPlatformWorldFromAnchor.clone()..invert();
    final Matrix4 logicalFromPlatform =
        _lockPlatformWorldFromAnchor * currentInverse;
    final Matrix4 platformFromLogical = current * lockInverse;
    final bool changed = !_sameStorage(
      current.storage,
      _lockPlatformWorldFromAnchor.storage,
    );
    return LogicalWorldUpdate._(
      logicalWorldFromPlatformWorld: logicalFromPlatform,
      platformWorldFromLogicalWorld: platformFromLogical,
      changed: changed,
    );
  }
}

class LogicalWorldUpdate {
  const LogicalWorldUpdate._({
    required this.logicalWorldFromPlatformWorld,
    required this.platformWorldFromLogicalWorld,
    required this.changed,
  });

  final Matrix4 logicalWorldFromPlatformWorld;
  final Matrix4 platformWorldFromLogicalWorld;
  final bool changed;

  Matrix4 toLogicalWorld(List<double> platformWorldFromValue) {
    return logicalWorldFromPlatformWorld * _readRigid(platformWorldFromValue);
  }

  Vector3 pointToLogicalWorld(Vector3 platformWorldPoint) {
    return logicalWorldFromPlatformWorld.transform3(platformWorldPoint.clone());
  }
}

bool _sameStorage(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Matrix4 _readRigid(List<double> values) {
  if (values.length != 16 || values.any((double value) => !value.isFinite)) {
    throw const FormatException('Expected 16 finite matrix values');
  }
  final Matrix4 matrix = Matrix4.fromList(values);
  const double tolerance = 1e-4;
  if (matrix.storage[3].abs() > tolerance ||
      matrix.storage[7].abs() > tolerance ||
      matrix.storage[11].abs() > tolerance ||
      (matrix.storage[15] - 1).abs() > tolerance) {
    throw const FormatException('Expected an affine rigid transform');
  }

  final Vector3 x = Vector3(
    matrix.storage[0],
    matrix.storage[1],
    matrix.storage[2],
  );
  final Vector3 y = Vector3(
    matrix.storage[4],
    matrix.storage[5],
    matrix.storage[6],
  );
  final Vector3 z = Vector3(
    matrix.storage[8],
    matrix.storage[9],
    matrix.storage[10],
  );
  final bool orthonormal =
      (x.length - 1).abs() <= tolerance &&
      (y.length - 1).abs() <= tolerance &&
      (z.length - 1).abs() <= tolerance &&
      x.dot(y).abs() <= tolerance &&
      x.dot(z).abs() <= tolerance &&
      y.dot(z).abs() <= tolerance &&
      (x.cross(y).dot(z) - 1).abs() <= tolerance;
  if (!orthonormal) {
    throw const FormatException('Expected a proper rigid transform');
  }
  return matrix;
}
