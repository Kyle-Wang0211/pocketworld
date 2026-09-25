// xrchain_native.dart —— 台架 XRSLAM → SfM 重建链的 dart:ffi 绑定(ios/Runner/PwXrReconChain.swift 的 @_cdecl)。
// 只进台架。符号不在(旧包 / 模拟器 / 单测)时 [XrChainNative.available] 为 false,各调用返回空。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _BeginN = ffi.Int32 Function(ffi.Double, ffi.Double);
typedef _BeginD = int Function(double, double);
typedef _VoidN = ffi.Void Function();
typedef _VoidD = void Function();
typedef _SubmitN = ffi.Int32 Function(ffi.Int64, ffi.Double, ffi.Double, ffi.Pointer<ffi.Double>);
typedef _SubmitD = int Function(int, double, double, ffi.Pointer<ffi.Double>);
typedef _TakeN = ffi.Int32 Function(ffi.Pointer<ffi.Double>, ffi.Int32);
typedef _TakeD = int Function(ffi.Pointer<ffi.Double>, int);
typedef _DrainN = ffi.Void Function(ffi.Pointer<ffi.Double>);
typedef _DrainD = void Function(ffi.Pointer<ffi.Double>);
typedef _CloseN = ffi.Int32 Function();
typedef _CloseD = int Function();
typedef _StatsN = ffi.Void Function(ffi.Pointer<ffi.Int64>, ffi.Int32);
typedef _StatsD = void Function(ffi.Pointer<ffi.Int64>, int);

/// pw_xrchain_take_result_host 摊平的 double 个数。
const int kXrChainResultDoubles = 32;

/// 一张照片的链路结果(PwXrChainPhotoResult 原样)。
class XrChainPhotoResult {
  XrChainPhotoResult._(List<double> d)
      : photoId = d[0].toInt(),
        tPhoto = d[1],
        submittedAt = d[2],
        resolvedAt = d[3],
        tState = d[4],
        extrapolationSeconds = d[5],
        cameraQxyzw = <double>[d[6], d[7], d[8], d[9]],
        cameraCenter = <double>[d[10], d[11], d[12]],
        bodyQxyzw = <double>[d[13], d[14], d[15], d[16]],
        bodyP = <double>[d[17], d[18], d[19]],
        propagatedT = d[20],
        frameId = d[21].toInt(),
        source = d[22].toInt(),
        trusted = d[23] != 0,
        reasonBits = d[24].toInt(),
        engineStateAtPhoto = d[25].toInt(),
        stateKind = d[26].toInt(),
        propagateStatus = d[27].toInt(),
        imuSamples = d[28].toInt(),
        hasPose = d[29] != 0;

  final int photoId;
  final double tPhoto;
  final double submittedAt;
  final double resolvedAt;
  final double tState;
  final double extrapolationSeconds;
  final List<double> cameraQxyzw;
  final List<double> cameraCenter;
  final List<double> bodyQxyzw;
  final List<double> bodyP;
  final double propagatedT;
  final int frameId;
  final int source;
  final bool trusted;
  final int reasonBits;
  final int engineStateAtPhoto;
  final int stateKind;
  final int propagateStatus;
  final int imuSamples;
  final bool hasPose;

  /// 拍照时刻 → 结果可用,毫秒(= 离线「等定稿」口径)。
  double get waitMs => (resolvedAt - tPhoto) * 1000;

  /// 提交 → 结果可用,毫秒。
  double get submitToResolveMs => (resolvedAt - submittedAt) * 1000;
}

class XrChainSubmit {
  const XrChainSubmit(this.rc, this.tPhoto, this.halfExposure, this.offset, this.now);
  final int rc;
  final double tPhoto;
  final double halfExposure;
  final double offset;
  final double now;
}

class XrChainDrainState {
  const XrChainDrainState(this.liveFrames, this.liveImu, this.engineFrames, this.pendingPhotos,
      this.framesNoted, this.framesSkipped);
  final int liveFrames;
  final int liveImu;
  final int engineFrames;
  final int pendingPhotos;
  final int framesNoted;
  final int framesSkipped;

  /// 喂料 worker 与引擎 worker 都空了(引擎符号不在时 engineFrames = −1,按「不知道」算没空)。
  bool get drained => liveFrames == 0 && liveImu == 0 && engineFrames == 0;
}

abstract final class XrChainNative {
  static bool _looked = false;
  static _BeginD? _begin;
  static _VoidD? _end;
  static _SubmitD? _submit;
  static _TakeD? _take;
  static _DrainD? _drain;
  static _CloseD? _close;
  static _StatsD? _stats;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    try {
      final ffi.DynamicLibrary l = ffi.DynamicLibrary.process();
      _begin = l.lookupFunction<_BeginN, _BeginD>('pw_xrchain_begin');
      _end = l.lookupFunction<_VoidN, _VoidD>('pw_xrchain_end');
      _submit = l.lookupFunction<_SubmitN, _SubmitD>('pw_xrchain_submit_photo_host');
      _take = l.lookupFunction<_TakeN, _TakeD>('pw_xrchain_take_result_host');
      _drain = l.lookupFunction<_DrainN, _DrainD>('pw_xrchain_drain_state');
      _close = l.lookupFunction<_CloseN, _CloseD>('pw_xrchain_close_host');
      _stats = l.lookupFunction<_StatsN, _StatsD>('pw_xrchain_stats_host');
    } catch (_) {
      _begin = null;
    }
  }

  static bool get available {
    _lookup();
    return _begin != null;
  }

  static int begin({required double timeoutSeconds, required double maxExtrapolationSeconds}) {
    _lookup();
    return _begin?.call(timeoutSeconds, maxExtrapolationSeconds) ?? -99;
  }

  static void end() {
    _lookup();
    _end?.call();
  }

  static XrChainSubmit? submit(int requestId, double ptsSeconds, double exposureSeconds) {
    _lookup();
    final _SubmitD? f = _submit;
    if (f == null) return null;
    final ffi.Pointer<ffi.Double> out = calloc<ffi.Double>(4);
    try {
      final int rc = f(requestId, ptsSeconds, exposureSeconds, out);
      return XrChainSubmit(rc, out[0], out[1], out[2], out[3]);
    } finally {
      calloc.free(out);
    }
  }

  static List<XrChainPhotoResult> takeAll() {
    _lookup();
    final _TakeD? f = _take;
    if (f == null) return const <XrChainPhotoResult>[];
    final ffi.Pointer<ffi.Double> out = calloc<ffi.Double>(kXrChainResultDoubles);
    final List<XrChainPhotoResult> got = <XrChainPhotoResult>[];
    try {
      while (f(out, kXrChainResultDoubles) == 1) {
        got.add(XrChainPhotoResult._(<double>[for (int i = 0; i < kXrChainResultDoubles; i++) out[i]]));
      }
    } finally {
      calloc.free(out);
    }
    return got;
  }

  static XrChainDrainState? drainState() {
    _lookup();
    final _DrainD? f = _drain;
    if (f == null) return null;
    final ffi.Pointer<ffi.Double> out = calloc<ffi.Double>(6);
    try {
      f(out);
      return XrChainDrainState(out[0].toInt(), out[1].toInt(), out[2].toInt(), out[3].toInt(),
          out[4].toInt(), out[5].toInt());
    } finally {
      calloc.free(out);
    }
  }

  static int close() {
    _lookup();
    return _close?.call() ?? -99;
  }

  static List<int> stats() {
    _lookup();
    final _StatsD? f = _stats;
    if (f == null) return const <int>[];
    final ffi.Pointer<ffi.Int64> out = calloc<ffi.Int64>(14);
    try {
      f(out, 14);
      return <int>[for (int i = 0; i < 14; i++) out[i]];
    } finally {
      calloc.free(out);
    }
  }
}
