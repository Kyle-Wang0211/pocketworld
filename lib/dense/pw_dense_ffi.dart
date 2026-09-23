// pw_dense_ffi.dart — dart:ffi binding of the pwdense_* ABI (vendor/pw_dense/include/pwdense_c.h).
//
// Resolution follows official_aether_ffi.dart: open <Runner.app>/Frameworks/PWDense.framework/PWDense by path,
// probe `pwdense_options_default`, fail closed. The job runs on a worker isolate; progress arrives through a
// NativeCallable.isolateLocal (the C side needs a return value), exactly like _glb_norm_ffi_native.dart.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// ABI versions this binding can drive. v2 (2026-09-15) added `pwdense_run2` — the same job plus a per-reference-
/// frame chunk callback. v3 (2026-09-16) added `pwdense_run3` over `pwdense_frame_v3_t`, which carries an optional
/// raw NV12 source per frame. Both are looked up optionally: on an older framework the symbol does not exist, the
/// lookup fails, [PwDenseFfi.hasChunkApi] / [PwDenseFfi.hasRun3] are false and the job falls back to
/// `pwdense_run2` / `pwdense_run`, so the app works with any of the three frameworks.
const int pwDenseAbiVersionMin = 1;
const int pwDenseAbiVersionMax = 3;

/// `pwdense_frame_v3_t.nv12_matrix` for the PWVA/HEVC decoder's output — pinned by the host probe
/// (openspec dense-lossless-speedup-v1 task 2.1); 0 = BT.601 full range, 1 = BT.709 full range.
const int kPwvaNv12Matrix = 1; // BT.709 full range: host probe 2026-09-16 (nv12_matrix_probe: m1 vs Apple decode mean<=0.03/max 1; Apple tags ITU_R_709_2)

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
    this.nv12Path,
    this.nv12Width,
    this.nv12Height,
  });
  final int frameId;
  final double fx, fy, cx, cy, imageW, imageH;
  final List<double> qWxyz; // 4
  final List<double> t; // 3

  /// Materialised JPEG. May be empty when [nv12Path] is set — the C side then gets NULL here.
  final String jpegPath;

  /// [v3] Raw full-range 4:2:0 bi-planar file (Y plane then interleaved CbCr, tightly packed) exactly as the
  /// PWVA/HEVC decoder hands it out. null = this frame is a JPEG source (the v1/v2 behaviour).
  final String? nv12Path;
  final int? nv12Width, nv12Height;

  /// True when this frame must go through `pwdense_run3`; a v1/v2 framework cannot consume it.
  bool get hasNv12 => nv12Path != null && nv12Path!.isNotEmpty;
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

/// [v3] pwdense_frame_v3_t — the 11 v2 members in the same order, then the NV12 tail. sizeOf == 144 on every
/// 64-bit ABI we ship (int32 + 4 pad, six doubles 8..55, q[4] 56, t[3] 88, jpeg_path 112, nv12_path 120,
/// nv12_width 128, nv12_height 132, nv12_matrix 136, reserved0 140). Pinned by test/dense/pw_dense_frame_v3_test.
final class _FrameRawV3 extends Struct {
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
  external Pointer<Utf8> nv12Path;
  @Int32()
  external int nv12Width;
  @Int32()
  external int nv12Height;
  @Int32()
  external int nv12Matrix;
  @Int32()
  external int reserved0;
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
// [v2] per-reference-frame delivery: xyz = n*3 floats, rgb = n*3 bytes, valid only during the call.
typedef _ChunkFnNative = Int32 Function(Int32 frameIndex, Pointer<Float> xyz, Pointer<Uint8> rgb, Int32 nPoints,
    Pointer<Void> user);
typedef _Run2C = Int32 Function(Pointer<_FrameRaw>, Int32, Pointer<Float>, Int32, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<NativeFunction<_ChunkFnNative>>, Pointer<Void>,
    Pointer<_StatsRaw>);
typedef _Run2D = int Function(Pointer<_FrameRaw>, int, Pointer<Float>, int, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<NativeFunction<_ChunkFnNative>>, Pointer<Void>,
    Pointer<_StatsRaw>);
// [v3] exactly run2's signature over pwdense_frame_v3_t frames.
typedef _Run3C = Int32 Function(Pointer<_FrameRawV3>, Int32, Pointer<Float>, Int32, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<NativeFunction<_ChunkFnNative>>, Pointer<Void>,
    Pointer<_StatsRaw>);
typedef _Run3D = int Function(Pointer<_FrameRawV3>, int, Pointer<Float>, int, Pointer<_OptionsRaw>,
    Pointer<NativeFunction<_ProgressFnNative>>, Pointer<NativeFunction<_ChunkFnNative>>, Pointer<Void>,
    Pointer<_StatsRaw>);

class PwDenseFfi {
  PwDenseFfi._(DynamicLibrary lib)
      : _abiVersion = lib.lookupFunction<_AbiVersionC, _AbiVersionD>('pwdense_abi_version'),
        _available = lib.lookupFunction<_AbiVersionC, _AbiVersionD>('pwdense_available'),
        _optionsDefault = lib.lookupFunction<_OptionsDefaultC, _OptionsDefaultD>('pwdense_options_default'),
        _defaultModelPath = lib.lookupFunction<_DefaultModelPathC, _DefaultModelPathD>('pwdense_default_model_path'),
        _run = lib.lookupFunction<_RunC, _RunD>('pwdense_run'),
        _run2 = _tryLookupRun2(lib),
        _run3 = _tryLookupRun3(lib);

  /// `pwdense_run2` only exists on the v2 framework; on v1 the lookup throws ArgumentError and we keep null.
  static _Run2D? _tryLookupRun2(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_Run2C, _Run2D>('pwdense_run2');
    } catch (_) {
      return null;
    }
  }

  /// `pwdense_run3` only exists on the v3 framework; same optional lookup as run2.
  static _Run3D? _tryLookupRun3(DynamicLibrary lib) {
    try {
      return lib.lookupFunction<_Run3C, _Run3D>('pwdense_run3');
    } catch (_) {
      return null;
    }
  }

  final _AbiVersionD _abiVersion;
  final _AbiVersionD _available;
  final _OptionsDefaultD _optionsDefault;
  final _DefaultModelPathD _defaultModelPath;
  final _RunD _run;
  final _Run2D? _run2;
  final _Run3D? _run3;

  int abiVersion() => _abiVersion();

  /// True when the framework exports `pwdense_run2`, i.e. progressive chunks can be delivered.
  bool get hasChunkApi => _run2 != null || _run3 != null;

  /// True when the framework exports `pwdense_run3`, i.e. a frame may be fed as raw NV12 instead of a JPEG.
  bool get hasRun3 => _run3 != null;
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
        final abi = ffi.abiVersion();
        if (abi < pwDenseAbiVersionMin || abi > pwDenseAbiVersionMax) {
          lastError = 'PWDense ABI $abi outside [$pwDenseAbiVersionMin, $pwDenseAbiVersionMax]';
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

/// One reference frame's fused contribution, already copied out of the native buffers (which are only valid
/// during the C call) and moved across the isolate boundary. [xyz] is n*3 floats, [rgb] n*3 bytes, in the sparse
/// PLY's world frame and already box-filtered — the same bytes that frame contributes to the output PLY.
final class PwDenseChunk {
  const PwDenseChunk(this.frameIndex, this.xyz, this.rgb);
  final int frameIndex;
  final Float32List xyz;
  final Uint8List rgb;
  int get pointCount => xyz.length ~/ 3;
}

/// Tag distinguishing a chunk message from a progress message on the shared port.
const String _kChunkTag = 'chunk';

/// Decodes one worker message into a chunk; null when the message is not one (progress messages are
/// `[phase, done, total]` and share the port). Chunk shape: `['chunk', frameIndex, xyz, rgb]` with both
/// payloads [TransferableTypedData] — the bytes were copied inside the native callback before it returned.
PwDenseChunk? decodePwDenseChunkMessage(Object? msg) {
  if (msg is! List || msg.length != 4 || msg[0] != _kChunkTag) return null;
  final frameIndex = msg[1];
  final xyz = msg[2];
  final rgb = msg[3];
  if (frameIndex is! int || xyz is! TransferableTypedData || rgb is! TransferableTypedData) return null;
  return PwDenseChunk(frameIndex, xyz.materialize().asFloat32List(), rgb.materialize().asUint8List());
}

final class _JobArgs {
  const _JobArgs(this.frames, this.pointsXyz, this.workDir, this.outPly, this.webgpu, this.progressPort, this.box,
      this.wantChunks);
  final List<PwDenseFrame> frames;
  final List<double> pointsXyz; // flat N*3
  final String workDir, outPly;
  final bool webgpu;

  /// Carries both progress and chunk messages (see [decodePwDenseChunkMessage]).
  final SendPort? progressPort;
  final PwDenseBox? box;
  final bool wantChunks;
}

/// Runs the dense job on a worker isolate. [onProgress] and [onChunk] are invoked on the calling isolate.
/// [onChunk] needs the v2 framework (`pwdense_run2`); on v1 the job still runs, just without chunks.
Future<PwDenseResult> runPwDenseJob({
  required List<PwDenseFrame> frames,
  required List<double> pointsXyz,
  required String workDir,
  required String outPly,
  bool webgpu = true,
  PwDenseBox? box,
  void Function(PwDenseProgress p)? onProgress,
  void Function(PwDenseChunk c)? onChunk,
}) async {
  ReceivePort? progressPort;
  if (onProgress != null || onChunk != null) {
    progressPort = ReceivePort();
    progressPort.listen((msg) {
      final chunk = decodePwDenseChunkMessage(msg);
      if (chunk != null) {
        onChunk?.call(chunk);
        return;
      }
      if (onProgress != null && msg is List && msg.length == 3) {
        onProgress(PwDenseProgress(msg[0] as String, msg[1] as int, msg[2] as int));
      }
    });
  }
  final args =
      _JobArgs(frames, pointsXyz, workDir, outPly, webgpu, progressPort?.sendPort, box, onChunk != null);
  try {
    return await _spawn(args);
  } finally {
    progressPort?.close();
  }
}

/// The isolate entry closure is created HERE, in a scope that holds nothing but [args]. Dart closures share one
/// context per enclosing scope: created inside [runPwDenseJob] the closure would drag the ReceivePort and the
/// `onProgress` callback along and `Isolate.run` refuses to send it ("object is unsendable — _ReceivePortImpl",
/// build 160 on the phone). `test/dense/pw_dense_ffi_isolate_test.dart` pins this.
Future<PwDenseResult> _spawn(_JobArgs args) => Isolate.run(() => _runInIsolate(args));

PwDenseResult _runInIsolate(_JobArgs a) {
  final ffi = PwDenseFfi.tryResolve();
  if (ffi == null) {
    return PwDenseResult(-1, _emptyStats(PwDenseFfi.lastError ?? 'PWDense unavailable'));
  }
  final n = a.frames.length;
  // v3 framework -> pwdense_frame_v3_t for every frame (a JPEG frame is just one with nv12_path == NULL);
  // v1/v2 framework -> the unchanged pwdense_frame_t. An NV12 frame cannot be expressed there, and the launcher
  // never builds one without run3 — if it ever does, fail loudly rather than silently feeding a wrong struct.
  final run3 = ffi._run3;
  if (run3 == null) {
    for (final f in a.frames) {
      if (f.hasNv12) {
        throw StateError('frame ${f.frameId} 是 NV12 源,但 PWDense 框架没有 pwdense_run3(ABI < 3)');
      }
    }
  }
  final strings = <Pointer<Utf8>>[];
  final framesPtr = run3 == null ? calloc<_FrameRaw>(n) : nullptr;
  final framesV3Ptr = run3 == null ? nullptr : calloc<_FrameRawV3>(n);
  for (var i = 0; i < n; i++) {
    final f = a.frames[i];
    if (run3 == null) {
      _fillFrameV2(framesPtr[i], f, strings);
    } else {
      _fillFrameV3(framesV3Ptr[i], f, strings);
    }
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
  // [v2] chunk callback. The native buffers die with the call, so every chunk is COPIED here and handed to the
  // main isolate as TransferableTypedData. Registered only when the caller asked for chunks AND the framework
  // exports pwdense_run2 — on a v1 framework we run pwdense_run and no chunk ever arrives.
  final run2 = ffi._run2;
  NativeCallable<_ChunkFnNative>? chunkCb;
  if (port != null && a.wantChunks && (run2 != null || run3 != null)) {
    chunkCb = NativeCallable<_ChunkFnNative>.isolateLocal(
      (int frameIndex, Pointer<Float> xyz, Pointer<Uint8> rgb, int nPoints, Pointer<Void> user) {
        final cnt = nPoints > 0 && xyz != nullptr && rgb != nullptr ? nPoints : 0;
        final xyzCopy = cnt == 0 ? Float32List(0) : Float32List.fromList(xyz.asTypedList(cnt * 3));
        final rgbCopy = cnt == 0 ? Uint8List(0) : Uint8List.fromList(rgb.asTypedList(cnt * 3));
        port.send(<Object>[
          _kChunkTag,
          frameIndex,
          TransferableTypedData.fromList(<TypedData>[xyzCopy]),
          TransferableTypedData.fromList(<TypedData>[rgbCopy]),
        ]);
        return 0; // no cancellation from the chunk path
      },
      exceptionalReturn: 0,
    );
  }
  int code;
  try {
    if (run3 != null) {
      code = run3(framesV3Ptr, n, ptsPtr, np, opts, cbPtr,
          chunkCb == null ? nullptr : chunkCb.nativeFunction, nullptr, stats);
    } else if (chunkCb != null) {
      code = run2!(framesPtr, n, ptsPtr, np, opts, cbPtr, chunkCb.nativeFunction, nullptr, stats);
    } else {
      code = ffi._run(framesPtr, n, ptsPtr, np, opts, cbPtr, nullptr, stats);
    }
  } finally {
    cb?.close();
    chunkCb?.close();
  }
  final st = _readStats(stats.ref);
  for (final s in strings) {
    calloc.free(s);
  }
  if (framesPtr != nullptr) calloc.free(framesPtr);
  if (framesV3Ptr != nullptr) calloc.free(framesV3Ptr);
  calloc.free(ptsPtr);
  calloc.free(workDirC);
  calloc.free(outPlyC);
  calloc.free(opts);
  calloc.free(stats);
  return PwDenseResult(code, st);
}

/// pwdense_frame_t (v1/v2). jpeg_path is always written, exactly as before.
void _fillFrameV2(_FrameRaw r, PwDenseFrame f, List<Pointer<Utf8>> strings) {
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

/// pwdense_frame_v3_t. The first 11 members are filled exactly like v2; an empty [PwDenseFrame.jpegPath] becomes
/// NULL (allowed only because nv12_path is then set), and nv12_matrix is [kPwvaNv12Matrix] whenever there is an
/// NV12 source. reserved0 is always 0 (the header says it must be).
void _fillFrameV3(_FrameRawV3 r, PwDenseFrame f, List<Pointer<Utf8>> strings) {
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
  if (f.jpegPath.isEmpty) {
    r.jpegPath = nullptr;
  } else {
    final s = f.jpegPath.toNativeUtf8();
    strings.add(s);
    r.jpegPath = s;
  }
  final nv = f.nv12Path;
  if (nv == null || nv.isEmpty) {
    r.nv12Path = nullptr;
    r.nv12Width = 0;
    r.nv12Height = 0;
    r.nv12Matrix = 0;
  } else {
    final s = nv.toNativeUtf8();
    strings.add(s);
    r.nv12Path = s;
    r.nv12Width = f.nv12Width ?? 0;
    r.nv12Height = f.nv12Height ?? 0;
    r.nv12Matrix = kPwvaNv12Matrix;
  }
  r.reserved0 = 0;
}

/// Test hook (test/dense/pw_dense_frame_v3_test.dart): marshals one frame into native memory exactly as the job
/// does, copies the raw struct bytes out, reads back what the two `char*` members point at (NULL -> null), then
/// frees everything. The test decodes [bytes] at the offsets pwdense_c.h dictates — that is the layout gate.
({int structSize, Uint8List bytes, String? jpegPath, String? nv12Path}) debugMarshalPwDenseFrameV3(PwDenseFrame f) {
  final p = calloc<_FrameRawV3>();
  final strings = <Pointer<Utf8>>[];
  try {
    _fillFrameV3(p.ref, f, strings);
    final size = sizeOf<_FrameRawV3>();
    final bytes = Uint8List.fromList(p.cast<Uint8>().asTypedList(size));
    final jp = p.ref.jpegPath;
    final np = p.ref.nv12Path;
    return (
      structSize: size,
      bytes: bytes,
      jpegPath: jp == nullptr ? null : jp.toDartString(),
      nv12Path: np == nullptr ? null : np.toDartString(),
    );
  } finally {
    for (final s in strings) {
      calloc.free(s);
    }
    calloc.free(p);
  }
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
