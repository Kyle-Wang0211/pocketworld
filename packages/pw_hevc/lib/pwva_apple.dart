/// pwva_apple — Apple 平台(iOS/macOS)的 HEVC 编解码接口实现
///
/// Dart FFI → VideoToolbox 纯 C API(经 pw_vt_encoder.c / pw_vt_decoder.c
/// 同步适配)。零 Swift、零 Objective-C。iOS 与 macOS 共用同一份原生源码,
/// 这使得 Mac 上验证的行为与手机 App 内的行为来自同一实现。
library pwva_apple;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'pwva.dart';

typedef _EncCreateC = Pointer<Void> Function(Int32, Int32, Int32, Double, Int64);
typedef _EncCreateD = Pointer<Void> Function(int, int, int, double, int);
typedef _EncodeC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    Int64, Int64, Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _EncodeD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint8>,
    int, int, Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _VoidPtrC = Void Function(Pointer<Void>);
typedef _VoidPtrD = void Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Uint8>);
typedef _FreeD = void Function(Pointer<Uint8>);
typedef _EncPbC = Int32 Function(Pointer<Void>, Pointer<Void>, Int64, Int64,
    Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _EncPbD = int Function(Pointer<Void>, Pointer<Void>, int, int,
    Pointer<Pointer<Uint8>>, Pointer<Int64>, Pointer<Int32>);
typedef _JpegC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);
typedef _JpegD = Pointer<Void> Function(Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>);
typedef _DecCreateC = Pointer<Void> Function(Int32, Int32, Pointer<Uint8>, Int64);
typedef _DecCreateD = Pointer<Void> Function(int, int, Pointer<Uint8>, int);
typedef _DecodeC = Int32 Function(
    Pointer<Void>, Pointer<Uint8>, Int64, Pointer<Uint8>, Pointer<Uint8>);
typedef _DecodeD = int Function(
    Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint8>, Pointer<Uint8>);

DynamicLibrary _open(String name) {
  if (Platform.isMacOS) {
    final candidates = [
      if (Platform.environment['PW_HEVC_NATIVE_DIR'] != null)
        '${Platform.environment['PW_HEVC_NATIVE_DIR']}/lib$name.dylib',
      '${Directory.current.path}/native/lib$name.dylib',
      '${File(Platform.script.toFilePath()).parent.parent.path}/native/lib$name.dylib',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return DynamicLibrary.open(path);
    }
    return DynamicLibrary.open('lib$name.dylib');
  }
  // iOS: 静态链接进 App 二进制
  return DynamicLibrary.process();
}

/// 探测 JPEG 尺寸(不解码全图元数据即可,但这里直接解一次拿准确值)。
({int width, int height}) probeJpegSize(String path) {
  final lib = _open('pw_jpeg_cvpb');
  final toPb = lib.lookupFunction<_JpegC, _JpegD>('pw_jpeg_to_bgra_cvpb');
  final release = lib.lookupFunction<_VoidPtrC, _VoidPtrD>('pw_cvpb_release');
  final w = calloc<Int32>();
  final h = calloc<Int32>();
  final p = path.toNativeUtf8();
  final pb = toPb(p, w, h);
  calloc.free(p);
  if (pb == nullptr) throw StateError('JPEG 解码失败: ' + path);
  final result = (width: w.value, height: h.value);
  release(pb);
  calloc.free(w);
  calloc.free(h);
  return result;
}

typedef _Nv12JpegC = Int32 Function(
    Pointer<Uint8>, Pointer<Uint8>, Int32, Int32, Double, Pointer<Utf8>);
typedef _Nv12JpegD = int Function(
    Pointer<Uint8>, Pointer<Uint8>, int, int, double, Pointer<Utf8>);

/// NV12 平面写成 JPEG 文件(PWVA 物化路径)。像素级重编码,不等同源字节。
void writeNv12JpegFile(Uint8List y, Uint8List uv,
    {required int width,
    required int height,
    required String path,
    double quality = 0.95}) {
  final lib = _open('pw_nv12_jpeg');
  final encode =
      lib.lookupFunction<_Nv12JpegC, _Nv12JpegD>('pw_nv12_to_jpeg_file');
  final yPtr = calloc<Uint8>(y.length);
  final uvPtr = calloc<Uint8>(uv.length);
  final pathPtr = path.toNativeUtf8();
  try {
    yPtr.asTypedList(y.length).setAll(0, y);
    uvPtr.asTypedList(uv.length).setAll(0, uv);
    final st = encode(yPtr, uvPtr, width, height, quality, pathPtr);
    if (st != 0) throw StateError('NV12→JPEG 写出失败 st=$st: $path');
  } finally {
    calloc.free(yPtr);
    calloc.free(uvPtr);
    calloc.free(pathPtr);
  }
}

class AppleHevcEncoder implements HevcFrameEncoder {
  final Pointer<Void> _handle;
  final int _ySize;
  final _EncodeD _encode;
  final _FreeD _free;
  final _VoidPtrD _destroy;
  final Pointer<Uint8> _y;
  final Pointer<Uint8> _uv;
  final Pointer<Pointer<Uint8>> _out;
  final Pointer<Int64> _len;
  final Pointer<Int32> _key;

  factory AppleHevcEncoder(
      {required int width,
      required int height,
      required int gop,
      double quality = 0.65,
      int averageBitrate = 0}) {
    final lib = _open('pw_vt_encoder');
    final create = lib.lookupFunction<_EncCreateC, _EncCreateD>('pw_vt_create');
    final handle = create(width, height, gop, quality, averageBitrate);
    if (handle == nullptr) {
      throw StateError('VideoToolbox HEVC 编码器创建失败 (${width}x$height)');
    }
    return AppleHevcEncoder._(
      handle,
      width * height,
      lib.lookupFunction<_EncodeC, _EncodeD>('pw_vt_encode_nv12'),
      lib.lookupFunction<_FreeC, _FreeD>('pw_vt_free'),
      lib.lookupFunction<_VoidPtrC, _VoidPtrD>('pw_vt_destroy'),
    );
  }

  AppleHevcEncoder._(this._handle, this._ySize, this._encode, this._free,
      this._destroy)
      : _y = calloc<Uint8>(_ySize),
        _uv = calloc<Uint8>(_ySize ~/ 2),
        _out = calloc<Pointer<Uint8>>(),
        _len = calloc<Int64>(),
        _key = calloc<Int32>();

  @override
  EncodedFrame encodeNv12(Uint8List y, Uint8List uv,
      {required int ptsMs, required int durationMs}) {
    _y.asTypedList(_ySize).setAll(0, y);
    _uv.asTypedList(_ySize ~/ 2).setAll(0, uv);
    final st = _encode(_handle, _y, _uv, ptsMs, durationMs, _out, _len, _key);
    if (st != 0) throw StateError('编码失败 OSStatus=$st');
    final bytes = Uint8List.fromList(_out.value.asTypedList(_len.value));
    final keyframe = _key.value == 1;
    _free(_out.value);
    return EncodedFrame(bytes, keyframe);
  }

  /// 生产转码路径:JPEG 文件 → BGRA CVPixelBuffer(ImageIO 硬解)→ 零拷贝编码。
  EncodedFrame encodeJpegFile(String path,
      {required int ptsMs, required int durationMs}) {
    final jpegLib = _open('pw_jpeg_cvpb');
    final toPb = jpegLib.lookupFunction<_JpegC, _JpegD>('pw_jpeg_to_bgra_cvpb');
    final releasePb =
        jpegLib.lookupFunction<_VoidPtrC, _VoidPtrD>('pw_cvpb_release');
    final encPb = _open('pw_vt_encoder')
        .lookupFunction<_EncPbC, _EncPbD>('pw_vt_encode_cvpb');
    final w = calloc<Int32>();
    final h = calloc<Int32>();
    final cPath = path.toNativeUtf8();
    final pb = toPb(cPath, w, h);
    calloc.free(cPath);
    calloc.free(w);
    calloc.free(h);
    if (pb == nullptr) throw StateError('JPEG 解码失败: ' + path);
    try {
      final st = encPb(_handle, pb, ptsMs, durationMs, _out, _len, _key);
      if (st != 0) throw StateError('编码失败 OSStatus=' + st.toString());
      final bytes = Uint8List.fromList(_out.value.asTypedList(_len.value));
      final keyframe = _key.value == 1;
      _free(_out.value);
      return EncodedFrame(bytes, keyframe);
    } finally {
      releasePb(pb);
    }
  }

  @override
  void dispose() {
    _destroy(_handle);
    calloc.free(_y);
    calloc.free(_uv);
    calloc.free(_out);
    calloc.free(_len);
    calloc.free(_key);
  }
}

class AppleHevcDecoder implements HevcFrameDecoder {
  final Pointer<Void> _handle;
  final int _ySize;
  final _DecodeD _decode;
  final _VoidPtrD _destroy;
  final Pointer<Uint8> _y;
  final Pointer<Uint8> _uv;

  factory AppleHevcDecoder(
      {required int width,
      required int height,
      required Uint8List keyframeAu}) {
    final lib = _open('pw_vt_decoder');
    final create =
        lib.lookupFunction<_DecCreateC, _DecCreateD>('pw_vt_dec_create');
    final auPtr = calloc<Uint8>(keyframeAu.length);
    auPtr.asTypedList(keyframeAu.length).setAll(0, keyframeAu);
    final handle = create(width, height, auPtr, keyframeAu.length);
    calloc.free(auPtr);
    if (handle == nullptr) {
      throw StateError('VideoToolbox HEVC 解码器创建失败');
    }
    return AppleHevcDecoder._(
      handle,
      width * height,
      lib.lookupFunction<_DecodeC, _DecodeD>('pw_vt_dec_decode'),
      lib.lookupFunction<_VoidPtrC, _VoidPtrD>('pw_vt_dec_destroy'),
    );
  }

  AppleHevcDecoder._(this._handle, this._ySize, this._decode, this._destroy)
      : _y = calloc<Uint8>(_ySize),
        _uv = calloc<Uint8>(_ySize ~/ 2);

  @override
  void decodeAu(Uint8List au, Uint8List y, Uint8List uv) {
    final p = calloc<Uint8>(au.length);
    p.asTypedList(au.length).setAll(0, au);
    final st = _decode(_handle, p, au.length, _y, _uv);
    calloc.free(p);
    if (st != 0) throw StateError('解码失败 OSStatus=$st');
    y.setAll(0, _y.asTypedList(_ySize));
    uv.setAll(0, _uv.asTypedList(_ySize ~/ 2));
  }

  @override
  void dispose() {
    _destroy(_handle);
    calloc.free(_y);
    calloc.free(_uv);
  }
}
