// aether_sfm_ffi.dart — Dart FFI binding for the on-device SfM C ABI
// (aether_cpp/include/aether_sfm_c.h).
//
// The native implementation (colmap::IncrementalPipeline over the three
// arm64-DEVICE-only static libs) is force-loaded into the Runner binary by the
// aether3d_ffi pod (see aether3d_ffi.podspec OTHER_LDFLAGS[sdk=iphoneos*]).
// On the iOS SIMULATOR there is no glomap/ceres/glog slice, so the pod links a
// stub archive that returns AETHER_SFM_ERR_UNSUPPORTED for every call. This
// Dart layer adds an explicit simulator guard so callers get a clear error
// instead of a confusing UNSUPPORTED result code at runtime.
//
// Symbol resolution: iOS statically links the archive into the process, so
// DynamicLibrary.process() is the lookup path (shared with AetherFfi).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

import 'aether_ffi.dart' show AetherFfi, FfiResolutionError;

/// Result codes from aether_sfm_c.h (kept in lock-step; append-only).
enum AetherSfmResult {
  ok,
  errInvalidArg,
  errDb,
  errExtract,
  errNoInitialPair,
  errNotRegistered,
  errInternal,
  errUnsupported,
}

AetherSfmResult _resultFromCode(int code) {
  if (code < 0 || code >= AetherSfmResult.values.length) {
    return AetherSfmResult.errInternal;
  }
  return AetherSfmResult.values[code];
}

/// A registered (or unregistered) camera pose for one frame.
class AetherSfmPose {
  final int frameId;
  final bool registered;

  /// CamFromWorld rotation quaternion [w, x, y, z].
  final List<double> quatWxyz;

  /// CamFromWorld translation [x, y, z].
  final List<double> translation;

  const AetherSfmPose({
    required this.frameId,
    required this.registered,
    required this.quatWxyz,
    required this.translation,
  });
}

/// A reconstructed 3D point with color.
class AetherSfmPoint {
  final double x, y, z;
  final int r, g, b;
  const AetherSfmPoint(this.x, this.y, this.z, this.r, this.g, this.b);
}

// ─── native typedefs ────────────────────────────────────────────────
final class _SfmOptions extends Struct {
  @Int32()
  external int maxFeatures;
  @Int32()
  external int imageWidth;
  @Int32()
  external int imageHeight;
  @Float()
  external double matchMaxRatio;
  @Int32()
  external int useGpuMatch;
  @Int32()
  external int kNeighbors;
}

final class _SfmPose extends Struct {
  @Int32()
  external int frameId;
  @Int32()
  external int registered;
  @Array(4)
  external Array<Double> qwxyz;
  @Array(3)
  external Array<Double> t;
}

final class _SfmPoint extends Struct {
  @Float()
  external double x;
  @Float()
  external double y;
  @Float()
  external double z;
  @Uint8()
  external int r;
  @Uint8()
  external int g;
  @Uint8()
  external int b;
  @Uint8()
  external int pad0;
  @Uint8()
  external int pad1;
}

typedef _OptionsDefaultC = Void Function(Pointer<_SfmOptions>);
typedef _OptionsDefaultDart = void Function(Pointer<_SfmOptions>);

typedef _RunC = Int32 Function(Pointer<Utf8> dbPath, Pointer<Utf8> imagePath,
    Pointer<_SfmOptions> options, Pointer<Pointer<Void>> outSession,
    Pointer<Utf8> outJson, Int32 outCap);
typedef _RunDart = int Function(Pointer<Utf8> dbPath, Pointer<Utf8> imagePath,
    Pointer<_SfmOptions> options, Pointer<Pointer<Void>> outSession,
    Pointer<Utf8> outJson, int outCap);

typedef _GetPosesC = Int32 Function(Pointer<Void> session,
    Pointer<_SfmPose> outPoses, Int32 cap, Pointer<Int32> outCount);
typedef _GetPosesDart = int Function(Pointer<Void> session,
    Pointer<_SfmPose> outPoses, int cap, Pointer<Int32> outCount);

typedef _GetPointsC = Int32 Function(Pointer<Void> session,
    Pointer<Pointer<_SfmPoint>> outPoints, Pointer<Int32> outCount);
typedef _GetPointsDart = int Function(Pointer<Void> session,
    Pointer<Pointer<_SfmPoint>> outPoints, Pointer<Int32> outCount);

typedef _PointsFreeC = Void Function(Pointer<_SfmPoint>);
typedef _PointsFreeDart = void Function(Pointer<_SfmPoint>);

typedef _SessionFreeC = Void Function(Pointer<Void>);
typedef _SessionFreeDart = void Function(Pointer<Void>);

/// Outcome of an on-device SfM solve, carrying the live native session so the
/// caller can read poses/points then must call [dispose].
class AetherSfmSolve {
  final Map<String, dynamic> summary;
  final Pointer<Void> _session;
  bool _disposed = false;

  AetherSfmSolve._(this.summary, this._session);

  /// Registered/unregistered camera poses (one per image in the model).
  List<AetherSfmPose> poses() {
    _checkLive();
    final countPtr = malloc<Int32>();
    try {
      // First call: count only.
      AetherSfm._getPoses(_session, nullptr, 0, countPtr);
      final n = countPtr.value;
      if (n <= 0) return const [];
      final buf = malloc<_SfmPose>(n);
      try {
        final rc = AetherSfm._getPoses(_session, buf, n, countPtr);
        if (_resultFromCode(rc) != AetherSfmResult.ok) return const [];
        final out = <AetherSfmPose>[];
        final written = countPtr.value < n ? countPtr.value : n;
        for (var i = 0; i < written; i++) {
          final p = buf[i];
          out.add(AetherSfmPose(
            frameId: p.frameId,
            registered: p.registered != 0,
            quatWxyz: [p.qwxyz[0], p.qwxyz[1], p.qwxyz[2], p.qwxyz[3]],
            translation: [p.t[0], p.t[1], p.t[2]],
          ));
        }
        return out;
      } finally {
        malloc.free(buf);
      }
    } finally {
      malloc.free(countPtr);
    }
  }

  /// Reconstructed colored 3D points (full cloud, no downsampling).
  List<AetherSfmPoint> points() {
    _checkLive();
    final countPtr = malloc<Int32>();
    final outPtr = malloc<Pointer<_SfmPoint>>();
    try {
      final rc = AetherSfm._getPoints(_session, outPtr, countPtr);
      if (_resultFromCode(rc) != AetherSfmResult.ok) return const [];
      final n = countPtr.value;
      final arr = outPtr.value;
      if (n <= 0 || arr == nullptr) return const [];
      try {
        final out = <AetherSfmPoint>[];
        for (var i = 0; i < n; i++) {
          final p = arr[i];
          out.add(AetherSfmPoint(p.x, p.y, p.z, p.r, p.g, p.b));
        }
        return out;
      } finally {
        AetherSfm._pointsFree(arr); // lib-malloc'd; lib frees
      }
    } finally {
      malloc.free(countPtr);
      malloc.free(outPtr);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_session != nullptr) AetherSfm._sessionFree(_session);
  }

  void _checkLive() {
    if (_disposed) {
      throw StateError('AetherSfmSolve already disposed');
    }
  }
}

/// On-device Structure-from-Motion (colmap incremental pipeline).
class AetherSfm {
  AetherSfm._();

  /// True on the iOS simulator, where the native SfM impl is unavailable
  /// (no arm64-simulator slice for glomap/ceres/glog). Callers should gate
  /// the feature on this and surface a "device only" message.
  static bool get isSupported {
    if (!Platform.isIOS) {
      // macOS/desktop CI may load a dylib with the symbols; assume supported
      // there and let the call return UNSUPPORTED if not.
      return true;
    }
    // Heuristic: the iOS simulator reports a simulator device. dart:io exposes
    // this via the SIMULATOR_DEVICE_NAME env on the host running the sim.
    final env = Platform.environment;
    final isSim = env.containsKey('SIMULATOR_DEVICE_NAME') ||
        env.containsKey('SIMULATOR_UDID');
    return !isSim;
  }

  static DynamicLibrary get _lib => AetherFfi.resolveLibraryForBindings();

  static final _OptionsDefaultDart _optionsDefault =
      _lib.lookupFunction<_OptionsDefaultC, _OptionsDefaultDart>(
          'aether_sfm_options_default');
  static final _RunDart _run =
      _lib.lookupFunction<_RunC, _RunDart>('aether_sfm_run');
  static final _GetPosesDart _getPoses =
      _lib.lookupFunction<_GetPosesC, _GetPosesDart>('aether_sfm_get_poses');
  static final _GetPointsDart _getPoints =
      _lib.lookupFunction<_GetPointsC, _GetPointsDart>('aether_sfm_get_points');
  static final _PointsFreeDart _pointsFree =
      _lib.lookupFunction<_PointsFreeC, _PointsFreeDart>(
          'aether_sfm_points_free');
  static final _SessionFreeDart _sessionFree =
      _lib.lookupFunction<_SessionFreeC, _SessionFreeDart>('aether_sfm_free');

  /// Runs the validated incremental SfM pipeline over a prebuilt COLMAP sqlite
  /// db + image dir. Returns an [AetherSfmSolve] whose [AetherSfmSolve.dispose]
  /// MUST be called to free the native session.
  ///
  /// Throws [FfiResolutionError] if symbols are missing (force_load failure).
  /// Throws [UnsupportedError] on the iOS simulator (no native impl slice).
  static AetherSfmSolve run(
    String dbPath,
    String imagePath, {
    int maxFeatures = 2048,
    double matchMaxRatio = 0.7,
    bool useGpuMatch = false,
    int kNeighbors = 6,
  }) {
    if (!isSupported) {
      throw UnsupportedError(
          'On-device SfM is unavailable on the iOS simulator (arm64 device '
          'only). Run on a physical device.');
    }
    final dbPtr = dbPath.toNativeUtf8();
    final imgPtr = imagePath.toNativeUtf8();
    final optPtr = malloc<_SfmOptions>();
    final sessPtr = malloc<Pointer<Void>>();
    const cap = 4096;
    final jsonPtr = malloc.allocate<Uint8>(cap).cast<Utf8>();
    try {
      _optionsDefault(optPtr);
      optPtr.ref
        ..maxFeatures = maxFeatures
        ..matchMaxRatio = matchMaxRatio
        ..useGpuMatch = useGpuMatch ? 1 : 0
        ..kNeighbors = kNeighbors;
      sessPtr.value = nullptr;
      final rc = _run(dbPtr, imgPtr, optPtr, sessPtr, jsonPtr, cap);
      final json = jsonPtr.toDartString();
      Map<String, dynamic> summary;
      try {
        summary = jsonDecode(json) as Map<String, dynamic>;
      } catch (_) {
        summary = {'raw': json};
      }
      summary['rc'] = rc;
      final result = _resultFromCode(rc);
      summary['result'] = result.name;
      return AetherSfmSolve._(summary, sessPtr.value);
    } finally {
      malloc.free(dbPtr);
      malloc.free(imgPtr);
      malloc.free(optPtr);
      malloc.free(sessPtr);
      malloc.free(jsonPtr);
    }
  }
}
