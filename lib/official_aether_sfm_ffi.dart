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
// Symbol resolution is owned by OfficialAetherFfi, which opens only the
// independent PWOfficialSfm dynamic framework and never consults the
// self-developed process/static-library symbol table.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

import 'official_aether_ffi.dart'
    show OfficialAetherFfi, OfficialFfiResolutionError;

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

typedef _RunC =
    Int32 Function(
      Pointer<Utf8> dbPath,
      Pointer<Utf8> imagePath,
      Pointer<_SfmOptions> options,
      Pointer<Pointer<Void>> outSession,
      Pointer<Utf8> outJson,
      Int32 outCap,
    );
typedef _RunDart =
    int Function(
      Pointer<Utf8> dbPath,
      Pointer<Utf8> imagePath,
      Pointer<_SfmOptions> options,
      Pointer<Pointer<Void>> outSession,
      Pointer<Utf8> outJson,
      int outCap,
    );

typedef _GetPosesC =
    Int32 Function(
      Pointer<Void> session,
      Pointer<_SfmPose> outPoses,
      Int32 cap,
      Pointer<Int32> outCount,
    );
typedef _GetPosesDart =
    int Function(
      Pointer<Void> session,
      Pointer<_SfmPose> outPoses,
      int cap,
      Pointer<Int32> outCount,
    );

typedef _GetPreviewPointsC =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Float> outXyz,
      Int32 cap,
      Pointer<Int32> outCount,
    );
typedef _GetPreviewPointsDart =
    int Function(
      Pointer<Void> session,
      Pointer<Float> outXyz,
      int cap,
      Pointer<Int32> outCount,
    );

typedef _GetPointsC =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Pointer<_SfmPoint>> outPoints,
      Pointer<Int32> outCount,
    );
typedef _GetPointsDart =
    int Function(
      Pointer<Void> session,
      Pointer<Pointer<_SfmPoint>> outPoints,
      Pointer<Int32> outCount,
    );

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

typedef _GetPointsTrackedC =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Pointer<_SfmPoint>> outPoints,
      Pointer<Int32> outCount,
      Pointer<Pointer<Int32>> outObsOffsets,
      Pointer<Pointer<_SfmTrackObs>> outObs,
      Pointer<Int64> outObsCount,
    );
typedef _GetPointsTrackedDart =
    int Function(
      Pointer<Void> session,
      Pointer<Pointer<_SfmPoint>> outPoints,
      Pointer<Int32> outCount,
      Pointer<Pointer<Int32>> outObsOffsets,
      Pointer<Pointer<_SfmTrackObs>> outObs,
      Pointer<Int64> outObsCount,
    );

typedef _TrackObsFreeC =
    Void Function(Pointer<Int32> offsets, Pointer<_SfmTrackObs> obs);
typedef _TrackObsFreeDart =
    void Function(Pointer<Int32> offsets, Pointer<_SfmTrackObs> obs);

typedef _DebugLastC =
    Void Function(
      Pointer<Void>,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );
typedef _DebugLastDart =
    void Function(
      Pointer<Void>,
      Pointer<Double>,
      Pointer<Double>,
      Pointer<Int32>,
      Pointer<Int32>,
      Pointer<Int32>,
    );

typedef _CandidateStatsC =
    Void Function(Pointer<Void>, Pointer<Int64>, Pointer<Int64>);
typedef _CandidateStatsDart =
    void Function(Pointer<Void>, Pointer<Int64>, Pointer<Int64>);

// [MATCH-FAIL TELEMETRY 2026-07-11] aether_sfm_match_fail_stats — capture-time
// GPU matcher failure buckets + finalize starved-frame re-match counters.
// Param 3 (gpu_fail_by_rc) points at 8 int64 slots; the rest are scalars.
typedef _MatchFailStatsC =
    Void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );
typedef _MatchFailStatsDart =
    void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );

// [THERMAL-THROTTLE 2026-07-11] aether_sfm_set_thermal_state — platform push
// of the ProcessInfo thermal bucket (0..3); serious/critical halves the live
// match candidate window in add_frame (cap45 camera-freeze fix).
typedef _SetThermalStateC = Void Function(Pointer<Void>, Int32);
typedef _SetThermalStateDart = void Function(Pointer<Void>, int);

// [THERMAL-THROTTLE 2026-07-11] aether_sfm_thermal_throttle_stats — frames
// fed with the reduced live K this capture (telemetry).
typedef _ThermalThrottleStatsC = Void Function(Pointer<Void>, Pointer<Int64>);
typedef _ThermalThrottleStatsDart =
    void Function(Pointer<Void>, Pointer<Int64>);

// [P1-LIVE-REPAY 2026-07-11] aether_sfm_live_repay — capture-idle debt
// repayment: re-match up to max_pairs missing temporal-window pairs of
// starved frames through the add_frame matcher route (db-only; native
// refuses outright at thermal serious/critical). Returns pairs written
// this call (0 = nothing to do / refused), -1 on bad args.
typedef _LiveRepayC = Int32 Function(Pointer<Void>, Int32);
typedef _LiveRepayDart = int Function(Pointer<Void>, int);

// [P1 2026-07-11] aether_sfm_repair_stats — finalize-speedup package
// counters: idle repay (live_repay), rc=7 backoff-retry, enrich time budget.
typedef _RepairStatsC =
    Void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );
typedef _RepairStatsDart =
    void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );

typedef _StreamStatsC =
    Void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );
typedef _StreamStatsDart =
    void Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
      Pointer<Int64>,
    );

typedef _SessionFreeC = Void Function(Pointer<Void>);
typedef _SessionFreeDart = void Function(Pointer<Void>);

// ─── streaming surface (aether_sfm_create / add_frame / finalize_async) ───
typedef _CreateC =
    Int32 Function(
      Pointer<Utf8> dbPath,
      Pointer<_SfmOptions> options,
      Pointer<Pointer<Void>> outSession,
    );
typedef _CreateDart =
    int Function(
      Pointer<Utf8> dbPath,
      Pointer<_SfmOptions> options,
      Pointer<Pointer<Void>> outSession,
    );

typedef _AddFrameC =
    Int32 Function(
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
      Pointer<Int32> outFrameId,
    );
typedef _AddFrameDart =
    int Function(
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
      Pointer<Int32> outFrameId,
    );

typedef _AddJpegFrameC =
    Int32 Function(
      Pointer<Void> session,
      Pointer<Utf8> jpegPath,
      Double captureTimestamp,
      Float fx,
      Float fy,
      Float cx,
      Float cy,
      Pointer<Double> poseQwxyz, // may be nullptr
      Pointer<Double> poseT, // may be nullptr
      Pointer<Int32> outFrameId,
    );
typedef _AddJpegFrameDart =
    int Function(
      Pointer<Void> session,
      Pointer<Utf8> jpegPath,
      double captureTimestamp,
      double fx,
      double fy,
      double cx,
      double cy,
      Pointer<Double> poseQwxyz,
      Pointer<Double> poseT,
      Pointer<Int32> outFrameId,
    );

typedef _FinalizeAsyncC =
    Int32 Function(Pointer<Void> session, Pointer<Utf8> outJson, Int32 outCap);
typedef _FinalizeAsyncDart =
    int Function(Pointer<Void> session, Pointer<Utf8> outJson, int outCap);

// [REMOVE-FRAME 2026-07-20] 删照片 → 撤回该帧的重建贡献。
// (session, frame_id, out_json, cap) → 结果码;out_json 带
// {removed_obs, deleted_points, cleared_pairs, n_registered, n_points3d}。
typedef _RemoveFrameC =
    Int32 Function(
      Pointer<Void> session,
      Int32 frameId,
      Pointer<Utf8> outJson,
      Int32 outCap,
    );
typedef _RemoveFrameDart =
    int Function(
      Pointer<Void> session,
      int frameId,
      Pointer<Utf8> outJson,
      int outCap,
    );

typedef _FinalizeStatusC = Int32 Function(Pointer<Void> session);
typedef _FinalizeStatusDart = int Function(Pointer<Void> session);

typedef _GlobalRefineC = Int32 Function(Pointer<Void> session);
typedef _GlobalRefineDart = int Function(Pointer<Void> session);

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
          out.add(
            AetherSfmPose(
              frameId: p.frameId,
              registered: p.registered != 0,
              quatWxyz: [p.qwxyz[0], p.qwxyz[1], p.qwxyz[2], p.qwxyz[3]],
              translation: [p.t[0], p.t[1], p.t[2]],
            ),
          );
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
    final isSim =
        env.containsKey('SIMULATOR_DEVICE_NAME') ||
        env.containsKey('SIMULATOR_UDID');
    return !isSim;
  }

  static DynamicLibrary get _lib =>
      OfficialAetherFfi.resolveLibraryForBindings();

  // Symbol names: pwofficial_* — the vendored COLMAP-4.0.4 archive compiles the
  // ABI with -fvisibility=hidden, so the raw aether_sfm_* symbols are
  // localized in the Runner link and invisible to dlsym. The pod's export
  // PWOfficialSfm's export shim re-exports 1:1
  // forwarders with default visibility under the pwofficial_ prefix; signatures
  // are identical to aether_sfm_c.h.
  static final _OptionsDefaultDart _optionsDefault = _lib
      .lookupFunction<_OptionsDefaultC, _OptionsDefaultDart>(
        'pwofficial_options_default',
      );
  static final _RunDart _run = _lib.lookupFunction<_RunC, _RunDart>(
    'pwofficial_run',
  );
  static final _GetPosesDart _getPoses = _lib
      .lookupFunction<_GetPosesC, _GetPosesDart>('pwofficial_get_poses');
  static final _GetPreviewPointsDart _getPreviewPoints = _lib
      .lookupFunction<_GetPreviewPointsC, _GetPreviewPointsDart>(
        'pwofficial_get_preview_points',
      );
  static final _GetPointsDart _getPoints = _lib
      .lookupFunction<_GetPointsC, _GetPointsDart>('pwofficial_get_points');
  static final _PointsFreeDart _pointsFree = _lib
      .lookupFunction<_PointsFreeC, _PointsFreeDart>('pwofficial_points_free');
  static final _GetPointsTrackedDart _getPointsTracked = _lib
      .lookupFunction<_GetPointsTrackedC, _GetPointsTrackedDart>(
        'pwofficial_get_points_tracked',
      );
  // Same ABI as _getPointsTracked, but reads the LIVE streaming local-BA
  // reconstruction — lets the worker true-color the streaming cloud through the
  // identical colorize path (track observations → full-res bilinear sample).
  static final _GetPointsTrackedDart _getPreviewTracked = _lib
      .lookupFunction<_GetPointsTrackedC, _GetPointsTrackedDart>(
        'pwofficial_get_preview_tracked',
      );
  static final _TrackObsFreeDart _trackObsFree = _lib
      .lookupFunction<_TrackObsFreeC, _TrackObsFreeDart>(
        'pwofficial_track_obs_free',
      );
  static final _DebugLastDart _debugLast = _lib
      .lookupFunction<_DebugLastC, _DebugLastDart>('pwofficial_debug_last');
  static final _StreamStatsDart _streamStats = _lib
      .lookupFunction<_StreamStatsC, _StreamStatsDart>(
        'pwofficial_stream_stats',
      );
  static final _CandidateStatsDart _candidateStats = _lib
      .lookupFunction<_CandidateStatsC, _CandidateStatsDart>(
        'pwofficial_candidate_stats',
      );
  static final _MatchFailStatsDart _matchFailStats = _lib
      .lookupFunction<_MatchFailStatsC, _MatchFailStatsDart>(
        'pwofficial_match_fail_stats',
      );
  static final _SetThermalStateDart _setThermalState = _lib
      .lookupFunction<_SetThermalStateC, _SetThermalStateDart>(
        'pwofficial_set_thermal_state',
      );
  static final _ThermalThrottleStatsDart _thermalThrottleStats = _lib
      .lookupFunction<_ThermalThrottleStatsC, _ThermalThrottleStatsDart>(
        'pwofficial_thermal_throttle_stats',
      );
  static final _LiveRepayDart _liveRepay = _lib
      .lookupFunction<_LiveRepayC, _LiveRepayDart>('pwofficial_live_repay');
  static final _RepairStatsDart _repairStats = _lib
      .lookupFunction<_RepairStatsC, _RepairStatsDart>(
        'pwofficial_repair_stats',
      );
  static final _GlobalRefineDart _globalRefine = _lib
      .lookupFunction<_GlobalRefineC, _GlobalRefineDart>(
        'pwofficial_global_refine',
      );
  static final _SessionFreeDart _sessionFree = _lib
      .lookupFunction<_SessionFreeC, _SessionFreeDart>('pwofficial_free');

  // Streaming surface. Bound lazily like the batch fns; the shim exists on
  // device AND simulator (sim guards finalize_async/status to UNSUPPORTED),
  // so lookup never throws asymmetrically.
  static final _CreateDart _create = _lib.lookupFunction<_CreateC, _CreateDart>(
    'pwofficial_create',
  );
  static final _AddFrameDart _addFrame = _lib
      .lookupFunction<_AddFrameC, _AddFrameDart>('pwofficial_add_frame');
  static final _AddJpegFrameDart _addJpegFrame = _lib
      .lookupFunction<_AddJpegFrameC, _AddJpegFrameDart>(
        'pwofficial_add_jpeg_frame',
      );
  static final _FinalizeAsyncDart _finalizeAsync = _lib
      .lookupFunction<_FinalizeAsyncC, _FinalizeAsyncDart>(
        'pwofficial_finalize_async',
      );
  static final _RemoveFrameDart _removeFrame = _lib
      .lookupFunction<_RemoveFrameC, _RemoveFrameDart>(
        'pwofficial_remove_frame',
      );
  static final _FinalizeStatusDart _finalizeStatus = _lib
      .lookupFunction<_FinalizeStatusC, _FinalizeStatusDart>(
        'pwofficial_finalize_status',
      );
  // [L1-ARBITRATE 2026-07-12] lazily bound like the rest; an OLD vendored .a
  // lacking the shim symbol throws on first use — callers catch (same
  // contract as repairStats).
  /// Runs the validated incremental SfM pipeline over a prebuilt COLMAP sqlite
  /// db + image dir. Returns an [AetherSfmSolve] whose [AetherSfmSolve.dispose]
  /// MUST be called to free the native session.
  ///
  /// Throws [OfficialFfiResolutionError] if the independent framework or ABI
  /// symbols are missing.
  /// Throws [UnsupportedError] on the iOS simulator (no native impl slice).
  static AetherSfmSolve run(
    String dbPath,
    String imagePath, {
    int maxFeatures = 2048,
    double matchMaxRatio = 0.8,
    bool useGpuMatch = false,
    int kNeighbors = 6,
  }) {
    if (!isSupported) {
      throw UnsupportedError(
        'On-device SfM is unavailable on the iOS simulator (arm64 device '
        'only). Run on a physical device.',
      );
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
    this.xyz,
    this.rgb,
    this.obsOffsets,
    this.obsFrameIds,
    this.obsXY,
  );
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
  ///    feed — the desktop K12/K20 viewer operating point, enabled by the
  ///    tiled-GEMM Metal matcher (pwofficial_gpu_match.mm; mutual cross-check,
  ///    bench 11568² @ 119 ms on A16). CPU extraction is now the slow leg
  ///    (~5-15 s/frame full-res) so live drop-rate rises — dropped frames
  ///    only skip the preview, never the delivered JPEGs.
  /// match_max_ratio stays 0.8 in both tiers.
  static const int researchMaxFeatures = 8192;
  static const int researchKNeighbors = 12;
  static const int liveMaxFeatures = 2048;
  static const int liveKNeighbors = 6;
  static const double defaultMatchMaxRatio = 0.8;

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
        'only). Run on a physical device.',
      );
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
        ..matchMaxRatio = defaultMatchMaxRatio
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
  /// optional CamFromWorld (world→camera) ARKit pose prior. Native uses it for
  /// the ARKit-world live preview/local-BA path; authoritative finalize still
  /// estimates its own SfM camera poses from image matches.
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
      final rc = AetherSfm._addFrame(
        _session,
        grayPtr,
        width,
        height,
        fx,
        fy,
        cx,
        cy,
        qPtr,
        tPtr,
        idPtr,
      );
      final result = _resultFromCode(rc);
      return AetherSfmAddFrameResult(
        result,
        result == AetherSfmResult.ok ? idPtr.value : -1,
      );
    } finally {
      malloc.free(grayPtr);
      malloc.free(idPtr);
      if (qPtr != nullptr) malloc.free(qPtr);
      if (tPtr != nullptr) malloc.free(tPtr);
    }
  }

  /// Feeds one keyframe by handing the original JPEG path to the independent
  /// official native runtime. The native boundary decodes at the file's exact
  /// dimensions and performs no crop, resize, or histogram normalization.
  AetherSfmAddFrameResult addJpegFrame(
    String jpegPath, {
    required double captureTimestamp,
    required double fx,
    required double fy,
    required double cx,
    required double cy,
    List<double>? quatWxyz,
    List<double>? translation,
  }) {
    _checkLive();
    final pathPtr = jpegPath.toNativeUtf8();
    final idPtr = malloc<Int32>();
    Pointer<Double> qPtr = nullptr;
    Pointer<Double> tPtr = nullptr;
    try {
      if (quatWxyz != null && quatWxyz.length == 4) {
        qPtr = malloc<Double>(4);
        qPtr.asTypedList(4).setAll(0, quatWxyz);
      }
      if (translation != null && translation.length == 3) {
        tPtr = malloc<Double>(3);
        tPtr.asTypedList(3).setAll(0, translation);
      }
      idPtr.value = -1;
      final rc = AetherSfm._addJpegFrame(
        _session,
        pathPtr,
        captureTimestamp,
        fx,
        fy,
        cx,
        cy,
        qPtr,
        tPtr,
        idPtr,
      );
      final result = _resultFromCode(rc);
      return AetherSfmAddFrameResult(
        result,
        result == AetherSfmResult.ok ? idPtr.value : -1,
      );
    } finally {
      malloc.free(pathPtr);
      malloc.free(idPtr);
      if (qPtr != nullptr) malloc.free(qPtr);
      if (tPtr != nullptr) malloc.free(tPtr);
    }
  }

  /// Per-frame timing breakdown of the LAST [addFrame] (perf diagnostics):
  /// extraction ms, matching ms, candidate count, and how many pairs matched
  /// on GPU vs CPU. extractMs > ~2000 ⇒ GPU DSP-SIFT fell back to CPU;
  /// cpuMatches > 0 ⇒ the GPU GEMM matcher fell back per pair.
  ({
    double extractMs,
    double matchMs,
    int nCand,
    int gpuMatches,
    int cpuMatches,
  })
  debugLast() {
    _checkLive();
    final e = malloc<Double>(), m = malloc<Double>();
    final nc = malloc<Int32>(), gm = malloc<Int32>(), cm = malloc<Int32>();
    try {
      e.value = 0;
      m.value = 0;
      nc.value = 0;
      gm.value = 0;
      cm.value = 0;
      AetherSfm._debugLast(_session, e, m, nc, gm, cm);
      return (
        extractMs: e.value,
        matchMs: m.value,
        nCand: nc.value,
        gpuMatches: gm.value,
        cpuMatches: cm.value,
      );
    } finally {
      malloc.free(e);
      malloc.free(m);
      malloc.free(nc);
      malloc.free(gm);
      malloc.free(cm);
    }
  }

  /// Cumulative streaming-quality counters over the whole capture — which
  /// floater filter did what. tvgPairs/rawPairs = grow/create pairs taken from
  /// the geometric (TVG RANSAC) inliers vs raw-fallback; growAccepted/Rejected =
  /// track-growth observations kept vs gated; mergeAccepted/Rejected =
  /// conservative live track merges that passed/failed the full-track reproj
  /// precheck; reprojFiltered/triFiltered = observations culled by the post-BA
  /// reprojection and multi-view triangulation-angle filters.
  ({
    int tvgPairs,
    int rawPairs,
    int growAccepted,
    int growRejected,
    int reprojFiltered,
    int triFiltered,
    int growRejectCheirality,
    int growRejectReproj,
    int createRejectCheirality,
    int createRejectTriAngle,
    int createRejectReproj,
    int alreadyAssigned,
    int mergeNeeded,
    int mergeAccepted,
    int mergeRejected,
    int spatialConsidered,
    int spatialAttempted,
    int spatialWritten,
    int spatialInliers,
    int spatialAnchorAttempted,
    int spatialAnchorPassed,
    int spatialRegionsConfirmed,
    int spatialExpandedAttempted,
    int spatialGuidedPairs,
    int spatialGuidedInliers,
    int spatialQuadraticAttempted,
    int spatialQuadraticWritten,
    int spatialBudgetSkipped,
    int temporalDetailPairs,
    int temporalDetailMatches,
    int temporalDetailCreated,
    int temporalDetailGrown,
    int temporalDetailRejectCheirality,
    int temporalDetailRejectReproj,
    int temporalDetailRejectTriAngle,
    int temporalDetailConflicts,
  })
  streamStats() {
    _checkLive();
    final tvg = malloc<Int64>(), raw = malloc<Int64>();
    final ga = malloc<Int64>(), gr = malloc<Int64>();
    final rf = malloc<Int64>(), tf = malloc<Int64>();
    final grc = malloc<Int64>(), grr = malloc<Int64>();
    final cch = malloc<Int64>(), cta = malloc<Int64>(), crp = malloc<Int64>();
    final asg = malloc<Int64>(), merge = malloc<Int64>();
    final mergeA = malloc<Int64>(), mergeR = malloc<Int64>();
    final spc = malloc<Int64>(), spa = malloc<Int64>();
    final spw = malloc<Int64>(), spi = malloc<Int64>();
    final saa = malloc<Int64>(), sap = malloc<Int64>();
    final src = malloc<Int64>(), sea = malloc<Int64>();
    final sgp = malloc<Int64>(), sgi = malloc<Int64>();
    final sqa = malloc<Int64>(), sqw = malloc<Int64>();
    final sbs = malloc<Int64>();
    final tdp = malloc<Int64>(), tdm = malloc<Int64>();
    final tdc = malloc<Int64>(), tdg = malloc<Int64>();
    final tdch = malloc<Int64>(), tdrp = malloc<Int64>();
    final tdta = malloc<Int64>(), tdcf = malloc<Int64>();
    try {
      for (final p in [
        tvg,
        raw,
        ga,
        gr,
        rf,
        tf,
        grc,
        grr,
        cch,
        cta,
        crp,
        asg,
        merge,
        mergeA,
        mergeR,
        spc,
        spa,
        spw,
        spi,
        saa,
        sap,
        src,
        sea,
        sgp,
        sgi,
        sqa,
        sqw,
        sbs,
        tdp,
        tdm,
        tdc,
        tdg,
        tdch,
        tdrp,
        tdta,
        tdcf,
      ]) {
        p.value = 0;
      }
      AetherSfm._streamStats(
        _session,
        tvg,
        raw,
        ga,
        gr,
        rf,
        tf,
        grc,
        grr,
        cch,
        cta,
        crp,
        asg,
        merge,
        mergeA,
        mergeR,
        spc,
        spa,
        spw,
        spi,
        saa,
        sap,
        src,
        sea,
        sgp,
        sgi,
        sqa,
        sqw,
        sbs,
        tdp,
        tdm,
        tdc,
        tdg,
        tdch,
        tdrp,
        tdta,
        tdcf,
      );
      return (
        tvgPairs: tvg.value,
        rawPairs: raw.value,
        growAccepted: ga.value,
        growRejected: gr.value,
        reprojFiltered: rf.value,
        triFiltered: tf.value,
        growRejectCheirality: grc.value,
        growRejectReproj: grr.value,
        createRejectCheirality: cch.value,
        createRejectTriAngle: cta.value,
        createRejectReproj: crp.value,
        alreadyAssigned: asg.value,
        mergeNeeded: merge.value,
        mergeAccepted: mergeA.value,
        mergeRejected: mergeR.value,
        spatialConsidered: spc.value,
        spatialAttempted: spa.value,
        spatialWritten: spw.value,
        spatialInliers: spi.value,
        spatialAnchorAttempted: saa.value,
        spatialAnchorPassed: sap.value,
        spatialRegionsConfirmed: src.value,
        spatialExpandedAttempted: sea.value,
        spatialGuidedPairs: sgp.value,
        spatialGuidedInliers: sgi.value,
        spatialQuadraticAttempted: sqa.value,
        spatialQuadraticWritten: sqw.value,
        spatialBudgetSkipped: sbs.value,
        temporalDetailPairs: tdp.value,
        temporalDetailMatches: tdm.value,
        temporalDetailCreated: tdc.value,
        temporalDetailGrown: tdg.value,
        temporalDetailRejectCheirality: tdch.value,
        temporalDetailRejectReproj: tdrp.value,
        temporalDetailRejectTriAngle: tdta.value,
        temporalDetailConflicts: tdcf.value,
      );
    } finally {
      for (final p in [
        tvg,
        raw,
        ga,
        gr,
        rf,
        tf,
        grc,
        grr,
        cch,
        cta,
        crp,
        asg,
        merge,
        mergeA,
        mergeR,
        spc,
        spa,
        spw,
        spi,
        saa,
        sap,
        src,
        sea,
        sgp,
        sgi,
        sqa,
        sqw,
        sbs,
        tdp,
        tdm,
        tdc,
        tdg,
        tdch,
        tdrp,
        tdta,
        tdcf,
      ]) {
        malloc.free(p);
      }
    }
  }

  /// [SPATIAL-FIRST 2026-07-11] Capture-time candidate-selection attribution:
  /// how many add_frame match candidates came from the spatial K-NN ∩
  /// view-angle rule vs the temporal fill / no-pose fallback. Their sum is the
  /// total match pairs attempted this capture (budget: K per frame).
  ({int spatialFirstPairs, int temporalFallbackPairs}) candidateStats() {
    _checkLive();
    final sp = malloc<Int64>(), tf = malloc<Int64>();
    try {
      sp.value = 0;
      tf.value = 0;
      AetherSfm._candidateStats(_session, sp, tf);
      return (spatialFirstPairs: sp.value, temporalFallbackPairs: tf.value);
    } finally {
      malloc.free(sp);
      malloc.free(tf);
    }
  }

  /// [MATCH-FAIL TELEMETRY 2026-07-11] Capture-time GPU matcher failure
  /// accounting (total / rc buckets / longest consecutive-fail streak) +
  /// finalize starved-frame re-match counters. rc buckets follow the
  /// pwofficial_gpu_match return codes (1=bad args, 2=Metal unavailable,
  /// 5/6=buffer alloc, 7=command-buffer error; bucket 0 = out-of-range rc).
  /// The rematch_* counters are only final after finalize phase 2 (REFINED) —
  /// the starved-frame re-match runs on the enrichment thread.
  ({
    int gpuFailTotal,
    List<int> gpuFailByRc,
    int gpuFailMaxStreak,
    int rematchStarvedFrames,
    int rematchCandidates,
    int rematchAttempted,
    int rematchWritten,
    int rematchInliers,
    int rematchFailed,
  })
  matchFailStats() {
    _checkLive();
    final total = malloc<Int64>();
    final byRc = malloc<Int64>(8);
    final streak = malloc<Int64>();
    final starved = malloc<Int64>();
    final cand = malloc<Int64>();
    final att = malloc<Int64>();
    final wr = malloc<Int64>();
    final inl = malloc<Int64>();
    final fail = malloc<Int64>();
    try {
      total.value = 0;
      for (var i = 0; i < 8; i++) {
        byRc[i] = 0;
      }
      streak.value = 0;
      starved.value = 0;
      cand.value = 0;
      att.value = 0;
      wr.value = 0;
      inl.value = 0;
      fail.value = 0;
      AetherSfm._matchFailStats(
        _session,
        total,
        byRc,
        streak,
        starved,
        cand,
        att,
        wr,
        inl,
        fail,
      );
      return (
        gpuFailTotal: total.value,
        gpuFailByRc: List<int>.generate(8, (i) => byRc[i]),
        gpuFailMaxStreak: streak.value,
        rematchStarvedFrames: starved.value,
        rematchCandidates: cand.value,
        rematchAttempted: att.value,
        rematchWritten: wr.value,
        rematchInliers: inl.value,
        rematchFailed: fail.value,
      );
    } finally {
      malloc.free(total);
      malloc.free(byRc);
      malloc.free(streak);
      malloc.free(starved);
      malloc.free(cand);
      malloc.free(att);
      malloc.free(wr);
      malloc.free(inl);
      malloc.free(fail);
    }
  }

  /// [THERMAL-THROTTLE 2026-07-11] Pushes the current ProcessInfo thermal
  /// bucket (0 nominal · 1 fair · 2 serious · 3 critical) into the native
  /// session. Call right before [addFrame]: state >= 2 halves the live match
  /// candidate window (12→6) so the Metal matcher yields GPU time to the
  /// camera pipeline (cap45 freeze fix). Throttled frames are re-matched to
  /// the full window at finalize — delivered quality is unchanged.
  void setThermalState(int state) {
    _checkLive();
    AetherSfm._setThermalState(_session, state);
  }

  /// [THERMAL-THROTTLE 2026-07-11] Frames fed with the reduced live K this
  /// capture (0 = throttle never engaged). Telemetry only.
  int thermalThrottledFrames() {
    _checkLive();
    final p = malloc<Int64>();
    try {
      p.value = 0;
      AetherSfm._thermalThrottleStats(_session, p);
      return p.value;
    } finally {
      malloc.free(p);
    }
  }

  /// [P1-LIVE-REPAY 2026-07-11] Capture-idle debt repayment: re-matches up to
  /// [maxPairs] missing temporal-window pairs of currently starved frames
  /// (GPU matcher failures / thermal-throttled frames) through the same
  /// matcher route and db-write sequence as addFrame. db-only — the live
  /// preview recon is untouched; the delivered model is identical whether a
  /// pair was repaid live or by the finalize starved-frame re-match (which
  /// remains the safety net). Thermal gating lives native-side (PHASE-A
  /// 2026-07-12): critical (3) refuses outright; serious (2) repays a small
  /// clamped budget only when the recent GPU history is clean (no rc=7) and
  /// aborts on the first struggling pair; nominal/fair (0/1) take the full
  /// [maxPairs]. Each missing pair is attempted at most once per session.
  /// MUST be called from the same worker isolate as [addFrame], only when the
  /// frame queue has slack. Returns pairs written this call (0 = nothing to do
  /// / refused); throws on bad args (-1).
  int liveRepay({int maxPairs = 4}) {
    _checkLive();
    final rc = AetherSfm._liveRepay(_session, maxPairs);
    if (rc < 0) {
      throw StateError('pwofficial_live_repay rejected args (rc=$rc)');
    }
    return rc;
  }

  /// [P1 2026-07-11] Finalize-speedup package counters: idle repay
  /// ([liveRepay]), rc=7 backoff-retry, and the finalize enrichment time
  /// budget. Same threading contract as [streamStats]; the gpu_retry/enrich
  /// counters are only final after finalize phase 2 (REFINED).
  ({
    int repayCalls,
    int repayAttempted,
    int repayWritten,
    int repayInliers,
    int repayFailed,
    int repaySkippedThermal,
    int gpuRetryAttempts,
    int gpuRetryRecovered,
    int enrichBudgetStopped,
  })
  repairStats() {
    _checkLive();
    final calls = malloc<Int64>();
    final att = malloc<Int64>();
    final wr = malloc<Int64>();
    final inl = malloc<Int64>();
    final fail = malloc<Int64>();
    final therm = malloc<Int64>();
    final retryAtt = malloc<Int64>();
    final retryRec = malloc<Int64>();
    final budget = malloc<Int64>();
    try {
      calls.value = 0;
      att.value = 0;
      wr.value = 0;
      inl.value = 0;
      fail.value = 0;
      therm.value = 0;
      retryAtt.value = 0;
      retryRec.value = 0;
      budget.value = 0;
      AetherSfm._repairStats(
        _session,
        calls,
        att,
        wr,
        inl,
        fail,
        therm,
        retryAtt,
        retryRec,
        budget,
      );
      return (
        repayCalls: calls.value,
        repayAttempted: att.value,
        repayWritten: wr.value,
        repayInliers: inl.value,
        repayFailed: fail.value,
        repaySkippedThermal: therm.value,
        gpuRetryAttempts: retryAtt.value,
        gpuRetryRecovered: retryRec.value,
        enrichBudgetStopped: budget.value,
      );
    } finally {
      malloc.free(calls);
      malloc.free(att);
      malloc.free(wr);
      malloc.free(inl);
      malloc.free(fail);
      malloc.free(therm);
      malloc.free(retryAtt);
      malloc.free(retryRec);
      malloc.free(budget);
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
    return aetherSfmFinalizeStatusFromCode(AetherSfm._finalizeStatus(_session));
  }

  /// [L1-ARBITRATE 2026-07-12] Ghost-layer L1 CasDiffMVS 1-bit arbitration —
  /// file-driven over the session's run_dir: consumes the AETHER_GHOST_MASK=1
  /// finalize-tail sidecars + the l1_depth_*.bin maps written by the platform
  /// CoreML runner (runCasDiffMVSL1), rewrites ghost_mask.bin with the
  /// rescued/confirmed bits (5/6) and returns the stats JSON. Call AFTER
  /// REFINED and after the runner replied. Safe on this worker isolate — the
  /// native side reads files only, never the reconstruction. Returns null
  /// when the inputs are absent (mask/plan never written, runner never ran,
  /// or the vendored archive predates the symbol) — treat as a no-op.
  /// [REMOVE-FRAME 2026-07-20] 撤回一帧的**全部重建贡献** —— 用户删照片时调用。
  ///
  /// 用户签决:"照片删了,那数据也必须删了"(拍虚 / 有人经过的照片产生的不良
  /// 点云本来就该被纠正)。这推翻了 07-13 的旧语义「删照片≠删数据」。
  ///
  /// native 侧每一步都是 COLMAP 现成操作,零自创:
  ///   · `ObservationManager::DeRegisterFrame` —— 撤该帧全部观测、删 track 掉到
  ///     2 元以下的 3D 点(DeleteObservation 的文档行为)、维护 correspondence
  ///     graph 可见计数、注销该帧;
  ///   · `Database::DeleteMatches` / `DeleteTwoViewGeometry` —— 把该图在 db 里
  ///     孤立,任何 db 驱动的重建(断点续跑 / refine 失败的 full-rerun 兜底)
  ///     都无法再注册它(COLMAP 没有"删单张图",孤立是官方等价做法)。
  ///
  /// **幸存点的坐标不会立即修正** —— 它们仍是"含被删帧"时三角化出来的值。
  /// 修正发生在 finalize 的 phase-2 全局 BA(现有路径,无需额外调用):少了那帧
  /// 的约束,位置重新收敛。用户可见效果 = 删照片瞬间"只被它看到的点"消失,
  /// 点"完成"时其余点轻微归位。此取舍已由用户签决。
  ///
  /// 返回 stats JSON;null = 撤回失败或旧 archive 无该符号(视作 no-op)。
  Map<String, dynamic>? removeFrame(int frameId) {
    _checkLive();
    const cap = 512;
    final jsonPtr = malloc.allocate<Uint8>(cap).cast<Utf8>();
    try {
      final rc = AetherSfm._removeFrame(_session, frameId, jsonPtr, cap);
      if (_resultFromCode(rc) != AetherSfmResult.ok) return null;
      return jsonDecode(jsonPtr.toDartString()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    } finally {
      malloc.free(jsonPtr);
    }
  }

  /// Rough live-preview cloud (throwaway) triangulated DURING capture from the
  /// per-frame matches + ARKit poses — available WITHOUT finalize, for the
  /// instant capture-end region selector. Flat [x,y,z, ...] in ARKit world
  /// coords; empty until enough matched frames accumulate. NOT the model.
  Float32List previewPoints() {
    _checkLive();
    final countPtr = malloc<Int32>();
    try {
      AetherSfm._getPreviewPoints(_session, nullptr, 0, countPtr);
      final n = countPtr.value;
      if (n <= 0) return Float32List(0);
      final buf = malloc<Float>(n * 3);
      try {
        final rc = AetherSfm._getPreviewPoints(_session, buf, n, countPtr);
        if (_resultFromCode(rc) != AetherSfmResult.ok) return Float32List(0);
        final written = countPtr.value < n ? countPtr.value : n;
        final out = Float32List(written * 3);
        for (var i = 0; i < written * 3; i++) {
          out[i] = buf[i];
        }
        return out;
      } finally {
        malloc.free(buf);
      }
    } finally {
      malloc.free(countPtr);
    }
  }

  /// Camera poses packed 9 doubles per frame:
  /// [frameId, registered(0/1), qw, qx, qy, qz, tx, ty, tz] — CamFromWorld.
  Float64List posesPacked() {
    _checkLive();
    final countPtr = malloc<Int32>();
    countPtr.value =
        0; // get_poses returns before writing count when not registered
    try {
      final szrc = AetherSfm._getPoses(_session, nullptr, 0, countPtr);
      final n = countPtr.value;
      if (_resultFromCode(szrc) != AetherSfmResult.ok || n <= 0) {
        return Float64List(0);
      }
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
  AetherSfmPointsTracked pointsTracked() =>
      _trackedFrom(AetherSfm._getPointsTracked);

  /// One-shot two-stage GLOBAL bundle adjustment over the live streaming
  /// reconstruction, run at 完成 to COLLAPSE the double-wall drift the per-frame
  /// windowed BA leaves behind. Refines the live cloud IN PLACE and republishes
  /// the preview snapshot, so a subsequent [previewTracked] returns the
  /// collapsed (single-surface) cloud. Observation-capped → cost is bounded and
  /// decoupled from frame count (seconds at any capture size). Returns the
  /// result code (OK on success; the windowed cloud is untouched on failure).
  /// BLOCKS for the refine duration — MUST be called on the capture worker
  /// isolate (never the UI isolate), ideally under the background umbrella.
  AetherSfmResult globalRefine() {
    _checkLive();
    return _resultFromCode(AetherSfm._globalRefine(_session));
  }

  /// Same shape as [pointsTracked] but reads the LIVE streaming local-BA
  /// reconstruction (built incrementally during capture) instead of the
  /// finalize output — so the streaming cloud can be true-colored through the
  /// identical colorize path. Must be called on the capture worker isolate.
  AetherSfmPointsTracked previewTracked() =>
      _trackedFrom(AetherSfm._getPreviewTracked);

  AetherSfmPointsTracked _trackedFrom(_GetPointsTrackedDart getter) {
    _checkLive();
    final countPtr = malloc<Int32>();
    final outPtr = malloc<Pointer<_SfmPoint>>();
    final offsPtr = malloc<Pointer<Int32>>();
    final obsPtr = malloc<Pointer<_SfmTrackObs>>();
    final obsCountPtr = malloc<Int64>();
    try {
      final rc = getter(
        _session,
        outPtr,
        countPtr,
        offsPtr,
        obsPtr,
        obsCountPtr,
      );
      if (_resultFromCode(rc) != AetherSfmResult.ok) {
        return AetherSfmPointsTracked(
          Float32List(0),
          Uint8List(0),
          Int32List(1),
          Int32List(0),
          Float32List(0),
        );
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
        return AetherSfmPointsTracked(
          Float32List(0),
          Uint8List(0),
          Int32List(1),
          Int32List(0),
          Float32List(0),
        );
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
