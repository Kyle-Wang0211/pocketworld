// Mock ARPoseProvider — produces a smooth synthetic orbit around the
// origin so the dome view can be demo'd without any AR runtime.

import 'dart:async';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import 'ar_pose.dart';

class MockARPoseProvider implements ARPoseProvider {
  static const double _orbitRadius = 0.8;
  static const double _sweepDurationSeconds = 60;

  Timer? _timer;
  final _controller = StreamController<ARPose>.broadcast();
  final Stopwatch _clock = Stopwatch();
  ARPose? _lastPose;

  Vector3 _worldOrigin = Vector3.zero();
  double _worldYaw = 0;
  bool _hasOrigin = false;

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() {
    if (_timer != null) return _controller.stream;
    _clock.start();
    _timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _emit();
    });
    return _controller.stream;
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false; // mock has no real camera frames to save

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async {
    return ARFrameSaveResult(
      spec: spec,
      status: 'unsupported',
      message: 'mock has no real camera frames to save',
    );
  }

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
  }) async => null;

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async {
    final last = _lastPose;
    if (last == null) {
      _worldOrigin = Vector3.zero();
      _worldYaw = 0;
      _hasOrigin = true;
    } else {
      final forward = last.orientation.rotated(Vector3(0, 0, -1));
      _worldOrigin = last.position + forward.normalized() * distanceMeters;
      final relInitial = last.position - _worldOrigin;
      _worldYaw = math.atan2(relInitial.z, relInitial.x);
      _hasOrigin = true;
    }
    return ARLockResult(worldOrigin: _worldOrigin, worldYaw: _worldYaw);
  }

  void _emit() {
    final t = _clock.elapsedMilliseconds / 1000.0;
    final orbitAz = (t / _sweepDurationSeconds) * 2 * math.pi;
    final orbitEl = math.sin(t * 0.21) * (40.0 * math.pi / 180.0);

    final cx = _orbitRadius * math.cos(orbitEl) * math.sin(orbitAz);
    final cy = _orbitRadius * math.sin(orbitEl);
    final cz = _orbitRadius * math.cos(orbitEl) * math.cos(orbitAz);
    final position = Vector3(cx, cy, cz);

    final yaw = Quaternion.axisAngle(Vector3(0, 1, 0), orbitAz + math.pi);
    final pitch = Quaternion.axisAngle(Vector3(1, 0, 0), orbitEl);
    final orient = yaw * pitch;

    double azBased = 0, elBased = 0;
    if (_hasOrigin) {
      final relX = position.x - _worldOrigin.x;
      final relY = position.y - _worldOrigin.y;
      final relZ = position.z - _worldOrigin.z;
      final horizDist = math.sqrt(relX * relX + relZ * relZ);
      azBased = math.atan2(relZ, relX) - _worldYaw;
      elBased = math.atan2(relY, horizDist < 0.001 ? 0.001 : horizDist);
    } else {
      final forward = orient.rotated(Vector3(0, 0, -1));
      azBased = math.atan2(forward.x, forward.z);
      elBased = math.asin(forward.y.clamp(-1.0, 1.0));
    }

    final pose = ARPose(
      position: position,
      orientation: orient,
      azimuth: azBased,
      elevation: elBased,
      isTracking: true,
      timestamp: t,
      hasOrigin: _hasOrigin,
      worldOrigin: _worldOrigin.clone(),
      worldYaw: _worldYaw,
      extrinsic4x4: const <double>[],
      intrinsicFxFyCxCy: const <double>[],
      // Mock has no real tracker — synthesize a perpetually-healthy
      // trackingStateName so PoseDriftTracker can run uniformly across
      // platforms (Web, HarmonyOS, simulator) without a null-branch.
      trackingStateName: 'normal',
    );
    _lastPose = pose;
    if (!_controller.isClosed) _controller.add(pose);
  }
}
