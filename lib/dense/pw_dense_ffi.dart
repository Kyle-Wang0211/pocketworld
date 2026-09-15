// pw_dense_ffi.dart — dart:ffi binding of the pwdense_* ABI (vendor/pw_dense/include/pwdense_c.h).
//
// Resolution follows official_aether_ffi.dart: open <Runner.app>/Frameworks/PWDense.framework/PWDense by path,
// probe `pwdense_options_default`, fail closed. The job runs on a worker isolate; progress arrives through a
// NativeCallable.isolateLocal (the C side needs a return value), exactly like _glb_norm_ffi_native.dart.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

const int pwDenseAbiVersion = 1;

final class PwDenseFrame {
  const PwDenseFrame({
    required this.frameId,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.imageW,
    required this.imageH,
    required this.qWxyz,
    required this.t,
    required this.jpegPath,
  });
  final int frameId;
  final double fx, fy, cx, cy, imageW, imageH;
  final List<double> qWxyz; // 4
  final List<double> t; // 3
  final String jpegPath;
}

/// The viewer's SelectionBox handed to C unchanged: centre, FULL side lengths, row-major local->world rotation.
final class PwDenseBox {
  const PwDenseBox({required this.cx, required this.cy, required this.cz, required this.sx, required this.sy, required this.sz, required this.rot});
  final double cx, cy, cz, sx, sy, sz;
  final List<double> rot; // 9
}

final class PwDenseStats {
  const PwDenseStats({
    required this.frames,
    required this.inferred,
    required this.images,
    required this.framesSelected,
    required this.boxFallback,
    required this.sessionMs,
    required this.imagesMs,
    required this.ortSessionMs,
    required this.inferMsMedian,
    required this.inferMsTotal,
    required this.fuseMs,
    required this.points,
    required this.finalFrac,
    required this.error,
  });
  final int frames, inferred, images, points, framesSelected;
  final bool boxFallback;
  final double sessionMs, imagesMs, ortSessionMs, inferMsMedian, inferMsTotal, fuseMs, finalFrac;
  final String error;
}

final class PwDenseResult {
  const PwDenseResult(this.code, this.stats);
  final int code; // 0 ok, 1 cancelled, 2 input, 3 model, 4 fusion, -1 unavailable
  final PwDenseStats stats;
  bool get ok => code == 0;
}

// ---- C structs (layout = pwdense_c.h) ----
final class _FrameRaw extends Struct {
  @Int32()
  external int frameId;
  @Double()
  external double fx;
  @Double()
  external double fy;
  @Double()
  external double cx;
  @Double()
  external double cy;
  @Double()
  external double imageW;
  @Double()
  external double imageH;
  @Array(4)
  external Array<Double> qWxyz;
  @Array(3)
  external Array<Double> t;
  external Pointer<Utf8> jpegPath;
}

final class _OptionsRaw extends Struct {
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int nsrc;
  @Int32()
  external int webgpu;
  external Pointer<Utf8> modelPath;
  external Pointer<Utf8> workDir;
  external Pointer<Utf8> outPly;
  @Uint64()
  external int noiseSeed;
  @Int32()
  external int hasBox;
  @Array(3)
  external Array<Double> boxCenter;
  @Array(3)
  external Array<Double> boxSize;
  @Array(9)
  external Array<Double> boxRot;
}

final class _StatsRaw extends Struct {
  @Int32()
  external int frames;
  @Int32()
  external int inferred;
  @Int32()
  external int images;
  @Int32()
  external int framesSelected;
  @Int32()
  external int boxFallback;
  @Double()
  external double sessionMs;
  @Double()
  external double imagesMs;
  @Double()
  external double ortSessionMs;
  @Double()
  external double inferMsMedian;
  @Double()
  external double inferMsTotal;
  @Double()
  external double fuseMs;
  @Uint64()
  external int points;
  @Double()
  external double photoFrac;
  @Double()
  external double geoFrac;
  @Double()
  external double finalFrac;
  @Array(256)
  external Array<Char> error;
}

typedef _ProgressFnNative = Int32 Function(Pointer<Utf8> phase, Int32 done, Int32 total, Pointer<Void> user);
typedef _AbiVersionC = Int32 Function();
typedef _AbiVersionD = int Function();
typedef _OptionsDefaultC = Int32 Function(Pointer<_OptionsRaw>);
typedef _OptionsDefaultD = int Function(Pointer<_OptionsRaw>);
typedef _DefaultModelPathC = Pointer<Utf8> Function();
typedef _DefaultModelPathD = Pointer<Utf8> Function();
typedef _RunC = Int32 Function(Pointer<_FrameRaw>, Int32, Pointer<Float>, Int32, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<Void>, Pointer<_StatsRaw>);
typedef _RunD = int Function(Pointer<_FrameRaw>, int, Pointer<Float>, int, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<Void>, Pointer<_StatsRaw>);

class PwDenseFfi {
  PwDenseFfi._(DynamicLibrary lib)
      : _abiVersion = lib.lookupFunction<_AbiVersionC, _AbiVersionD>('pwdense_abi_version'),
        _available = lib.lookupFunction<_AbiVersionC, _AbiVersionD>('pwdense_available'),
        _optionsDefault = lib.lookupFunction<_OptionsDefaultC, _OptionsDefaultD>('pwdense_options_default'),
        _defaultModelPath = lib.lookupFunction<_DefaultModelPathC, _DefaultModelPathD>('pwdense_default_model_path'),
        _run = lib.lookupFunction<_RunC, _RunD>('pwdense_run');

  final _AbiVersionD _abiVersion;
  final _AbiVersionD _available;
  final _OptionsDefaultD _optionsDefault;
  final _DefaultModelPathD _defaultModelPath;
  final _RunD _run;

  int abiVersion() => _abiVersion();
  int available() => _available();
  String defaultModelPath() {
    final p = _defaultModelPath();
    return p == nullptr ? '' : p.toDartString();
  }

  static PwDenseFfi? _cached;
  static String? lastError;

  static List<String> _candidatePaths() {
    final out = <String>[];
    final env = Platform.environment['PW_DENSE_FRAMEWORK'] ?? '';
    if (env.isNotEmpty) out.add(env);
    final exeDir = File(Platform.resolvedExecutable).absolute.parent;
    out.add('${exeDir.path}/Frameworks/PWDense.framework/PWDense'); // iOS
    out.add('${exeDir.parent.path}/Frameworks/PWDense.framework/PWDense'); // macOS
    return out;
  }

  /// Opens the framework; null (with [lastError]) when it is absent, the ABI version differs, or the slice is
  /// the simulator stub (pwdense_available() == 0).
  static PwDenseFfi? tryResolve() {
    if (_cached != null) return _cached;
    for (final p in _candidatePaths()) {
      if (!File(p).existsSync()) continue;
      try {
        final lib = DynamicLibrary.open(p);
        final ffi = PwDenseFfi._(lib);
        if (ffi.abiVersion() != pwDenseAbiVersion) {
          lastError = 'PWDense ABI ${ffi.abiVersion()} != $pwDenseAbiVersion';
          return null;
        }
        if (ffi.available() == 0) {
          lastError = 'PWDense stub slice (simulator)';
          return null;
        }
        _cached = ffi;
        return ffi;
      } catch (e) {
        lastError = 'open $p: $e';
      }
    }
    lastError ??= 'no PWDense.framework candidate exists';
    return null;
  }
}

/// Progress event as delivered to the caller's isolate.
final class PwDenseProgress {
  const PwDenseProgress(this.phase, this.done, this.total);
  final String phase;
  final int done, total;
}

final class _JobArgs {
  const _JobArgs(this.frames, this.pointsXyz, this.workDir, this.outPly, this.webgpu, this.progressPort, this.box);
  final List<PwDenseFrame> frames;
  final List<double> pointsXyz; // flat N*3
  final String workDir, outPly;
  final bool webgpu;
  final SendPort? progressPort;
  final PwDenseBox? box;
}

/// Runs the dense job on a worker isolate. [onProgress] is invoked on the calling isolate.
Future<PwDenseResult> runPwDenseJob({
  required List<PwDenseFrame> frames,
  required List<double> pointsXyz,
  required String workDir,
  required String outPly,
  bool webgpu = true,
  PwDenseBox? box,
  void Function(PwDenseProgress p)? onProgress,
}) async {
  ReceivePort? progressPort;
  if (onProgress != null) {
    progressPort = ReceivePort();
    progressPort.listen((msg) {
      if (msg is List && msg.length == 3) onProgress(PwDenseProgress(msg[0] as String, msg[1] as int, msg[2] as int));
    });
  }
  try {
    return await Isolate.run(() => _runInIsolate(_JobArgs(frames, pointsXyz, workDir, outPly, webgpu, progressPort?.sendPort, box)));
  } finally {
    progressPort?.close();
  }
}

PwDenseResult _runInIsolate(_JobArgs a) {
  final ffi = PwDenseFfi.tryResolve();
  if (ffi == null) {
    return PwDenseResult(-1, _emptyStats(PwDenseFfi.lastError ?? 'PWDense unavailable'));
  }
  final n = a.frames.length;
  final framesPtr = calloc<_FrameRaw>(n);
  final strings = <Pointer<Utf8>>[];
  for (var i = 0; i < n; i++) {
    final f = a.frames[i];
    final r = framesPtr[i];
    r.frameId = f.frameId;
    r.fx = f.fx;
    r.fy = f.fy;
    r.cx = f.cx;
    r.cy = f.cy;
    r.imageW = f.imageW;
    r.imageH = f.imageH;
    for (var k = 0; k < 4; k++) {
      r.qWxyz[k] = f.qWxyz[k];
    }
    for (var k = 0; k < 3; k++) {
      r.t[k] = f.t[k];
    }
    final s = f.jpegPath.toNativeUtf8();
    strings.add(s);
    r.jpegPath = s;
  }
  final np = a.pointsXyz.length ~/ 3;
  final ptsPtr = calloc<Float>(np * 3);
  ptsPtr.asTypedList(np * 3).setAll(0, a.pointsXyz);
  final opts = calloc<_OptionsRaw>();
  ffi._optionsDefault(opts);
  final workDirC = a.workDir.toNativeUtf8();
  final outPlyC = a.outPly.toNativeUtf8();
  opts.ref.workDir = workDirC;
  opts.ref.outPly = outPlyC;
  opts.ref.webgpu = a.webgpu ? 1 : 0;
  opts.ref.modelPath = nullptr; // -> pwdense_default_model_path() (the model shipped inside PWDense.framework)
  final box = a.box;
  if (box != null) {
    opts.ref.hasBox = 1;
    opts.ref.boxCenter[0] = box.cx;
    opts.ref.boxCenter[1] = box.cy;
    opts.ref.boxCenter[2] = box.cz;
    opts.ref.boxSize[0] = box.sx;
    opts.ref.boxSize[1] = box.sy;
    opts.ref.boxSize[2] = box.sz;
    for (var k = 0; k < 9; k++) {
      opts.ref.boxRot[k] = box.rot[k];
    }
  }
  final stats = calloc<_StatsRaw>();

  NativeCallable<_ProgressFnNative>? cb;
  Pointer<NativeFunction<_ProgressFnNative>> cbPtr = nullptr;
  final port = a.progressPort;
  if (port != null) {
    cb = NativeCallable<_ProgressFnNative>.isolateLocal(
      (Pointer<Utf8> phase, int done, int total, Pointer<Void> user) {
        port.send(<Object>[phase == nullptr ? '' : phase.toDartString(), done, total]);
        return 0; // no cancellation in v1
      },
      exceptionalReturn: 0,
    );
    cbPtr = cb.nativeFunction;
  }
  int code;
  try {
    code = ffi._run(framesPtr, n, ptsPtr, np, opts, cbPtr, nullptr, stats);
  } finally {
    cb?.close();
  }
  final st = _readStats(stats.ref);
  for (final s in strings) {
    calloc.free(s);
  }
  calloc.free(framesPtr);
  calloc.free(ptsPtr);
  calloc.free(workDirC);
  calloc.free(outPlyC);
  calloc.free(opts);
  calloc.free(stats);
  return PwDenseResult(code, st);
}

PwDenseStats _emptyStats(String error) => PwDenseStats(
      frames: 0, inferred: 0, images: 0, framesSelected: 0, boxFallback: false, sessionMs: 0, imagesMs: 0, ortSessionMs: 0, inferMsMedian: 0,
      inferMsTotal: 0, fuseMs: 0, points: 0, finalFrac: 0, error: error);

PwDenseStats _readStats(_StatsRaw r) {
  final bytes = <int>[];
  for (var i = 0; i < 256; i++) {
    final c = r.error[i];
    if (c == 0) break;
    bytes.add(c & 0xff);
  }
  return PwDenseStats(
    frames: r.frames,
    inferred: r.inferred,
    images: r.images,
    framesSelected: r.framesSelected,
    boxFallback: r.boxFallback != 0,
    sessionMs: r.sessionMs,
    imagesMs: r.imagesMs,
    ortSessionMs: r.ortSessionMs,
    inferMsMedian: r.inferMsMedian,
    inferMsTotal: r.inferMsTotal,
    fuseMs: r.fuseMs,
    points: r.points,
    finalFrac: r.finalFrac,
    error: String.fromCharCodes(bytes),
  );
}
