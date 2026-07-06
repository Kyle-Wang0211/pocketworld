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
import 'dart:typed_data';
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

/// `aether_sfm_finalize_status_t` from aether_sfm_c.h (kept in lock-step).
enum AetherSfmFinalizeStatus {
  idle, // 0 — finalize_async not started
  localReady, // 1 — local recon live; global BA refining in background
  refined, // 2 — global BA done; refined recon atomically swapped in
  error, // 3 — background refinement failed
}

AetherSfmFinalizeStatus aetherSfmFinalizeStatusFromCode(int code) {
  if (code < 0 || code >= AetherSfmFinalizeStatus.values.length) {
    return AetherSfmFinalizeStatus.error;
  }
  return AetherSfmFinalizeStatus.values[code];
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
  // MUST mirror aether_sfm_c.h field-for-field: the C struct has a 7th
  // field `use_gpu_extract`. Omitting it made malloc<_SfmOptions>() 4 bytes
  // short, so aether_sfm_options_default() wrote past the allocation
  // (latent heap overflow on the batch path — fixed alongside streaming).
  @Int32()
  external int useGpuExtract;
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

// aether_sfm_track_obs_t — one 2D observation of a 3D point (the frame it
// was DETECTED in + the keypoint position in that frame's fed pixel space).
final class _SfmTrackObs extends Struct {
  @Int32()
  external int frameId;
  @Float()
  external double x;
  @Float()
  external double y;
}

typedef _GetPointsTrackedC = Int32 Function(
    Pointer<Void> session,
    Pointer<Pointer<_SfmPoint>> outPoints,
    Pointer<Int32> outCount,
    Pointer<Pointer<Int32>> outObsOffsets,
    Pointer<Pointer<_SfmTrackObs>> outObs,
    Pointer<Int64> outObsCount);
typedef _GetPointsTrackedDart = int Function(
    Pointer<Void> session,
    Pointer<Pointer<_SfmPoint>> outPoints,
    Pointer<Int32> outCount,
    Pointer<Pointer<Int32>> outObsOffsets,
    Pointer<Pointer<_SfmTrackObs>> outObs,
    Pointer<Int64> outObsCount);

typedef _TrackObsFreeC = Void Function(
    Pointer<Int32> offsets, Pointer<_SfmTrackObs> obs);
typedef _TrackObsFreeDart = void Function(
    Pointer<Int32> offsets, Pointer<_SfmTrackObs> obs);

typedef _SessionFreeC = Void Function(Pointer<Void>);
typedef _SessionFreeDart = void Function(Pointer<Void>);

// ─── streaming surface (aether_sfm_create / add_frame / finalize_async) ───
typedef _CreateC = Int32 Function(Pointer<Utf8> dbPath,
    Pointer<_SfmOptions> options, Pointer<Pointer<Void>> outSession);
typedef _CreateDart = int Function(Pointer<Utf8> dbPath,
    Pointer<_SfmOptions> options, Pointer<Pointer<Void>> outSession);

typedef _AddFrameC = Int32 Function(
    Pointer<Void> session,
    Pointer<Uint8> gray,
    Int32 width,
    Int32 height,
    Float fx,
    Float fy,
    Float cx,
    Float cy,
    Pointer<Double> poseQwxyz, // may be nullptr
    Pointer<Double> poseT, // may be nullptr
    Pointer<Int32> outFrameId);
typedef _AddFrameDart = int Function(
    Pointer<Void> session,
    Pointer<Uint8> gray,
    int width,
    int height,
    double fx,
    double fy,
    double cx,
    double cy,
    Pointer<Double> poseQwxyz,
    Pointer<Double> poseT,
    Pointer<Int32> outFrameId);

typedef _FinalizeAsyncC = Int32 Function(
    Pointer<Void> session, Pointer<Utf8> outJson, Int32 outCap);
typedef _FinalizeAsyncDart = int Function(
    Pointer<Void> session, Pointer<Utf8> outJson, int outCap);

typedef _FinalizeStatusC = Int32 Function(Pointer<Void> session);
typedef _FinalizeStatusDart = int Function(Pointer<Void> session);

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

  // Symbol names: pwsfm_* — the vendored COLMAP-4.0.4 archive compiles the
  // ABI with -fvisibility=hidden, so the raw aether_sfm_* symbols are
  // localized in the Runner link and invisible to dlsym. The pod's export
  // shim (vendor/aether_ffi/src/pwsfm_export_shim.c) re-exports 1:1
  // forwarders with default visibility under the pwsfm_ prefix; signatures
  // are identical to aether_sfm_c.h.
  static final _OptionsDefaultDart _optionsDefault =
      _lib.lookupFunction<_OptionsDefaultC, _OptionsDefaultDart>(
          'pwsfm_options_default');
  static final _RunDart _run =
      _lib.lookupFunction<_RunC, _RunDart>('pwsfm_run');
  static final _GetPosesDart _getPoses =
      _lib.lookupFunction<_GetPosesC, _GetPosesDart>('pwsfm_get_poses');
  static final _GetPointsDart _getPoints =
      _lib.lookupFunction<_GetPointsC, _GetPointsDart>('pwsfm_get_points');
  static final _PointsFreeDart _pointsFree =
      _lib.lookupFunction<_PointsFreeC, _PointsFreeDart>('pwsfm_points_free');
  static final _GetPointsTrackedDart _getPointsTracked =
      _lib.lookupFunction<_GetPointsTrackedC, _GetPointsTrackedDart>(
          'pwsfm_get_points_tracked');
  static final _TrackObsFreeDart _trackObsFree =
      _lib.lookupFunction<_TrackObsFreeC, _TrackObsFreeDart>(
          'pwsfm_track_obs_free');
  static final _SessionFreeDart _sessionFree =
      _lib.lookupFunction<_SessionFreeC, _SessionFreeDart>('pwsfm_free');

  // Streaming surface. Bound lazily like the batch fns; the shim exists on
  // device AND simulator (sim guards finalize_async/status to UNSUPPORTED),
  // so lookup never throws asymmetrically.
  static final _CreateDart _create =
      _lib.lookupFunction<_CreateC, _CreateDart>('pwsfm_create');
  static final _AddFrameDart _addFrame =
      _lib.lookupFunction<_AddFrameC, _AddFrameDart>('pwsfm_add_frame');
  static final _FinalizeAsyncDart _finalizeAsync =
      _lib.lookupFunction<_FinalizeAsyncC, _FinalizeAsyncDart>(
          'pwsfm_finalize_async');
  static final _FinalizeStatusDart _finalizeStatus =
      _lib.lookupFunction<_FinalizeStatusC, _FinalizeStatusDart>(
          'pwsfm_finalize_status');

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

/// Outcome of one [AetherSfmStreamSession.addFrame] call.
class AetherSfmAddFrameResult {
  final AetherSfmResult result;
  final int frameId; // -1 unless result == ok
  const AetherSfmAddFrameResult(this.result, this.frameId);
}

/// Sparse cloud packed for cheap isolate transfer / rendering:
/// [xyz] is 3 floats per point, [rgb] 3 bytes per point (may be all zeros —
/// on-device extract_colors is off; render with a uniform tint then).
class AetherSfmPointsPacked {
  final Float32List xyz;
  final Uint8List rgb;
  const AetherSfmPointsPacked(this.xyz, this.rgb);
  int get count => xyz.length ~/ 3;
}

/// [AetherSfmPointsPacked] plus per-point track observations, all read from
/// ONE native Reconstruction snapshot (point order and observation runs are
/// mutually consistent even across the async LOCAL→REFINED swap).
///
/// Observations for point i: indices obsOffsets[i]..obsOffsets[i+1] into
/// [obsFrameIds] / [obsXY] (2 floats per obs, fed-frame pixel coords). Track
/// membership is a visibility proof — the COLMAP-faithful colorizer samples
/// each point's OWN detection frames at these keypoint coords instead of
/// reprojecting into globally-picked frames (which silently sampled occluder
/// colors — the striped-color bug).
class AetherSfmPointsTracked {
  final Float32List xyz;
  final Uint8List rgb;
  final Int32List obsOffsets; // count+1 entries
  final Int32List obsFrameIds; // obsCount entries
  final Float32List obsXY; // 2*obsCount entries
  const AetherSfmPointsTracked(
      this.xyz, this.rgb, this.obsOffsets, this.obsFrameIds, this.obsXY);
  int get count => xyz.length ~/ 3;
  int get obsCount => obsFrameIds.length;
}

/// Streaming on-device SfM session (aether_sfm_create → add_frame* →
/// finalize_async → poll finalize_status → getters → free).
///
/// EVERY method here performs a BLOCKING native call — `addFrame` is
/// ~0.5-0.7 s on an A16 and `finalizeAsync`'s synchronous phase (incremental
/// register + local BA) is minutes-scale. This class must therefore only be
/// used from a dedicated background isolate (see SfmLiveRecon), NEVER from
/// the UI isolate. It is deliberately free of any isolate/queue logic so the
/// contract stays 1:1 with aether_sfm_c.h.
class AetherSfmStreamSession {
  final Pointer<Void> _session;
  bool _disposed = false;

  AetherSfmStreamSession._(this._session);

  /// Opens a session backed by a private sqlite db at [dbPath] (temp dir —
  /// `aether_sfm_free` drops the file). [imageWidth]/[imageHeight] MUST equal
  /// the dimensions of every gray buffer later passed to [addFrame]; the
  /// per-frame intrinsics reference the same size.
  ///
  /// Two operating tiers (2026-07-05, user-directed switch to research):
  ///  • LIVE tier (former default): 2048 features / K=6 — the ≤2s/frame
  ///    streaming budget config.
  ///  • RESEARCH tier (current): 8192 features / K=12 at full-resolution
  ///    feed — the desktop K=12 viewer operating point, enabled by the
  ///    tiled-GEMM Metal matcher (pwsfm_gpu_match.mm; mutual cross-check,
  ///    bench 11568² @ 119 ms on A16). CPU extraction is now the slow leg
  ///    (~5-15 s/frame full-res) so live drop-rate rises — dropped frames
  ///    only skip the preview, never the delivered JPEGs.
  /// match_max_ratio stays 0.7 in both tiers.
  static const int researchMaxFeatures = 8192;
  static const int researchKNeighbors = 12;
  static const int liveMaxFeatures = 2048;
  static const int liveKNeighbors = 6;

  static AetherSfmStreamSession create(
    String dbPath, {
    required int imageWidth,
    required int imageHeight,
    int maxFeatures = researchMaxFeatures,
    int kNeighbors = researchKNeighbors,
  }) {
    if (!AetherSfm.isSupported) {
      throw UnsupportedError(
          'On-device SfM is unavailable on the iOS simulator (arm64 device '
          'only). Run on a physical device.');
    }
    final dbPtr = dbPath.toNativeUtf8();
    final optPtr = malloc<_SfmOptions>();
    final sessPtr = malloc<Pointer<Void>>();
    try {
      AetherSfm._optionsDefault(optPtr);
      optPtr.ref
        ..maxFeatures = maxFeatures
        ..imageWidth = imageWidth
        ..imageHeight = imageHeight
        ..matchMaxRatio = 0.7
        ..kNeighbors = kNeighbors
        ..useGpuMatch = 1
        ..useGpuExtract = 1;
      sessPtr.value = nullptr;
      final rc = AetherSfm._create(dbPtr, optPtr, sessPtr);
      final result = _resultFromCode(rc);
      if (result != AetherSfmResult.ok || sessPtr.value == nullptr) {
        throw StateError('aether_sfm_create failed: ${result.name} (rc=$rc)');
      }
      return AetherSfmStreamSession._(sessPtr.value);
    } finally {
      malloc.free(dbPtr);
      malloc.free(optPtr);
      malloc.free(sessPtr);
    }
  }

  /// Feeds one keyframe. [gray] is row-major top-down 8-bit grayscale of
  /// exactly the session's imageWidth x imageHeight; [fx]/[fy]/[cx]/[cy] are
  /// intrinsics at that SAME size. [quatWxyz] + [translation] are the
  /// optional CamFromWorld (world→camera) ARKit pose prior — stored, unused
  /// by the v1 solver, but forward the values whenever available.
  ///
  /// The gray buffer is consumed synchronously inside the call (native copies
  /// what it needs); the malloc'd copy is freed before returning.
  AetherSfmAddFrameResult addFrame(
    Uint8List gray,
    int width,
    int height, {
    required double fx,
    required double fy,
    required double cx,
    required double cy,
    List<double>? quatWxyz,
    List<double>? translation,
  }) {
    _checkLive();
    final n = width * height;
    final grayPtr = malloc<Uint8>(n);
    final idPtr = malloc<Int32>();
    Pointer<Double> qPtr = nullptr;
    Pointer<Double> tPtr = nullptr;
    try {
      grayPtr.asTypedList(n).setRange(0, n, gray);
      if (quatWxyz != null && quatWxyz.length == 4) {
        qPtr = malloc<Double>(4);
        qPtr.asTypedList(4).setAll(0, quatWxyz);
      }
      if (translation != null && translation.length == 3) {
        tPtr = malloc<Double>(3);
        tPtr.asTypedList(3).setAll(0, translation);
      }
      idPtr.value = -1;
      final rc = AetherSfm._addFrame(_session, grayPtr, width, height, fx, fy,
          cx, cy, qPtr, tPtr, idPtr);
      final result = _resultFromCode(rc);
      return AetherSfmAddFrameResult(
          result, result == AetherSfmResult.ok ? idPtr.value : -1);
    } finally {
      malloc.free(grayPtr);
      malloc.free(idPtr);
      if (qPtr != nullptr) malloc.free(qPtr);
      if (tPtr != nullptr) malloc.free(tPtr);
    }
  }

  /// Two-phase finalize. BLOCKS through phase 1 (incremental register +
  /// local BA — minutes-scale, frame-count dependent); on OK the LOCAL
  /// reconstruction is immediately readable via [posesPacked]/[pointsPacked]
  /// and the background global-BA thread is running (poll [finalizeStatus]
  /// for refined/error). Returns the LOCAL summary
  /// {solve_ms, n_registered, n_points3d, reproj_px} plus rc/result.
  Map<String, dynamic> finalizeAsync() {
    _checkLive();
    const cap = 4096;
    final jsonPtr = malloc.allocate<Uint8>(cap).cast<Utf8>();
    try {
      final rc = AetherSfm._finalizeAsync(_session, jsonPtr, cap);
      final json = jsonPtr.toDartString();
      Map<String, dynamic> summary;
      try {
        summary = jsonDecode(json) as Map<String, dynamic>;
      } catch (_) {
        summary = {'raw': json};
      }
      summary['rc'] = rc;
      summary['result'] = _resultFromCode(rc).name;
      return summary;
    } finally {
      malloc.free(jsonPtr);
    }
  }

  /// Lock-free status poll of the background refinement.
  AetherSfmFinalizeStatus finalizeStatus() {
    _checkLive();
    return aetherSfmFinalizeStatusFromCode(
        AetherSfm._finalizeStatus(_session));
  }

  /// Camera poses packed 9 doubles per frame:
  /// [frameId, registered(0/1), qw, qx, qy, qz, tx, ty, tz] — CamFromWorld.
  Float64List posesPacked() {
    _checkLive();
    final countPtr = malloc<Int32>();
    try {
      AetherSfm._getPoses(_session, nullptr, 0, countPtr);
      final n = countPtr.value;
      if (n <= 0) return Float64List(0);
      final buf = malloc<_SfmPose>(n);
      try {
        final rc = AetherSfm._getPoses(_session, buf, n, countPtr);
        if (_resultFromCode(rc) != AetherSfmResult.ok) return Float64List(0);
        final written = countPtr.value < n ? countPtr.value : n;
        final out = Float64List(written * 9);
        for (var i = 0; i < written; i++) {
          final p = buf[i];
          final o = i * 9;
          out[o] = p.frameId.toDouble();
          out[o + 1] = p.registered != 0 ? 1 : 0;
          out[o + 2] = p.qwxyz[0];
          out[o + 3] = p.qwxyz[1];
          out[o + 4] = p.qwxyz[2];
          out[o + 5] = p.qwxyz[3];
          out[o + 6] = p.t[0];
          out[o + 7] = p.t[1];
          out[o + 8] = p.t[2];
        }
        return out;
      } finally {
        malloc.free(buf);
      }
    } finally {
      malloc.free(countPtr);
    }
  }

  /// FULL sparse cloud (never downsampled here — any thinning is a
  /// render-time concern; export/delivery paths must keep every point).
  AetherSfmPointsPacked pointsPacked() {
    _checkLive();
    final countPtr = malloc<Int32>();
    final outPtr = malloc<Pointer<_SfmPoint>>();
    try {
      final rc = AetherSfm._getPoints(_session, outPtr, countPtr);
      if (_resultFromCode(rc) != AetherSfmResult.ok) {
        return AetherSfmPointsPacked(Float32List(0), Uint8List(0));
      }
      final n = countPtr.value;
      final arr = outPtr.value;
      if (n <= 0 || arr == nullptr) {
        return AetherSfmPointsPacked(Float32List(0), Uint8List(0));
      }
      try {
        final xyz = Float32List(n * 3);
        final rgb = Uint8List(n * 3);
        for (var i = 0; i < n; i++) {
          final p = arr[i];
          final o = i * 3;
          xyz[o] = p.x;
          xyz[o + 1] = p.y;
          xyz[o + 2] = p.z;
          rgb[o] = p.r;
          rgb[o + 1] = p.g;
          rgb[o + 2] = p.b;
        }
        return AetherSfmPointsPacked(xyz, rgb);
      } finally {
        AetherSfm._pointsFree(arr); // lib-malloc'd; ONLY the lib may free
      }
    } finally {
      malloc.free(countPtr);
      malloc.free(outPtr);
    }
  }

  /// FULL sparse cloud + per-point track observations from one atomic
  /// snapshot (see [AetherSfmPointsTracked]). Falls back to empty lists on
  /// any non-OK result.
  AetherSfmPointsTracked pointsTracked() {
    _checkLive();
    final countPtr = malloc<Int32>();
    final outPtr = malloc<Pointer<_SfmPoint>>();
    final offsPtr = malloc<Pointer<Int32>>();
    final obsPtr = malloc<Pointer<_SfmTrackObs>>();
    final obsCountPtr = malloc<Int64>();
    try {
      final rc = AetherSfm._getPointsTracked(
          _session, outPtr, countPtr, offsPtr, obsPtr, obsCountPtr);
      if (_resultFromCode(rc) != AetherSfmResult.ok) {
        return AetherSfmPointsTracked(Float32List(0), Uint8List(0),
            Int32List(1), Int32List(0), Float32List(0));
      }
      final n = countPtr.value;
      final arr = outPtr.value;
      final offs = offsPtr.value;
      final obs = obsPtr.value;
      final m = obsCountPtr.value;
      if (n <= 0 || arr == nullptr || offs == nullptr) {
        if (arr != nullptr) AetherSfm._pointsFree(arr);
        if (offs != nullptr || obs != nullptr) {
          AetherSfm._trackObsFree(offs, obs);
        }
        return AetherSfmPointsTracked(Float32List(0), Uint8List(0),
            Int32List(1), Int32List(0), Float32List(0));
      }
      try {
        final xyz = Float32List(n * 3);
        final rgb = Uint8List(n * 3);
        for (var i = 0; i < n; i++) {
          final p = arr[i];
          final o = i * 3;
          xyz[o] = p.x;
          xyz[o + 1] = p.y;
          xyz[o + 2] = p.z;
          rgb[o] = p.r;
          rgb[o + 1] = p.g;
          rgb[o + 2] = p.b;
        }
        final obsOffsets = Int32List(n + 1);
        obsOffsets.setAll(0, offs.asTypedList(n + 1));
        final obsFrameIds = Int32List(m);
        final obsXY = Float32List(m * 2);
        for (var j = 0; j < m; j++) {
          final t = obs[j];
          obsFrameIds[j] = t.frameId;
          obsXY[j * 2] = t.x;
          obsXY[j * 2 + 1] = t.y;
        }
        return AetherSfmPointsTracked(xyz, rgb, obsOffsets, obsFrameIds, obsXY);
      } finally {
        AetherSfm._pointsFree(arr); // lib-malloc'd; ONLY the lib may free
        AetherSfm._trackObsFree(offs, obs);
      }
    } finally {
      malloc.free(countPtr);
      malloc.free(outPtr);
      malloc.free(offsPtr);
      malloc.free(obsPtr);
      malloc.free(obsCountPtr);
    }
  }

  /// Frees the native session: drops the sqlite db and JOINS the background
  /// global-BA thread (may block if refinement is still running).
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_session != nullptr) AetherSfm._sessionFree(_session);
  }

  void _checkLive() {
    if (_disposed) {
      throw StateError('AetherSfmStreamSession already disposed');
    }
  }
}
