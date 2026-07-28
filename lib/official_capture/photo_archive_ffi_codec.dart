import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_policy.dart';

/// Production JPEG XL codec backed by the pinned native libjxl bridge.
class JxlFfiPhotoArchiveCodec implements PhotoArchiveCodec {
  JxlFfiPhotoArchiveCodec({this.effort = 7});

  final int effort;
  bool? _supported;

  @override
  bool get isSupported {
    if (!Platform.isIOS) return false;
    return _supported ??= _NativeJxlBindings.tryLoad() != null;
  }

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) {
    if (!isSupported) {
      throw UnsupportedError('pinned libjxl bridge is unavailable');
    }
    final sourcePath = sourceJpeg.path;
    final destinationPath = destinationJxl.path;
    final selectedEffort = effort;
    return Isolate.run(
      () => _encodeFile(sourcePath, destinationPath, selectedEffort),
    );
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) {
    if (!isSupported) {
      throw UnsupportedError('pinned libjxl bridge is unavailable');
    }
    final sourcePath = sourceJxl.path;
    final destinationPath = destinationJpeg.path;
    return Isolate.run(() => _reconstructFile(sourcePath, destinationPath));
  }
}

void _encodeFile(String sourcePath, String destinationPath, int effort) {
  final bindings = _NativeJxlBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.encodeFile(source, destination, effort, elapsed),
    );
  } finally {
    calloc
      ..free(elapsed)
      ..free(destination)
      ..free(source);
  }
}

void _reconstructFile(String sourcePath, String destinationPath) {
  final bindings = _NativeJxlBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.reconstructFile(source, destination, elapsed),
    );
  } finally {
    calloc
      ..free(elapsed)
      ..free(destination)
      ..free(source);
  }
}

typedef _NativeCString = Pointer<Utf8> Function();
typedef _DartCString = Pointer<Utf8> Function();
typedef _NativeErrorMessage = Pointer<Utf8> Function(Int32);
typedef _DartErrorMessage = Pointer<Utf8> Function(int);
typedef _NativeEncodeFile =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Uint64>);
typedef _DartEncodeFile =
    int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Uint64>);
typedef _NativeReconstructFile =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint64>);
typedef _DartReconstructFile =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint64>);

class _NativeJxlBindings {
  _NativeJxlBindings._(DynamicLibrary library)
    : version = library
          .lookupFunction<_NativeCString, _DartCString>('pw_jxl_version')()
          .toDartString(),
      revision = library
          .lookupFunction<_NativeCString, _DartCString>('pw_jxl_revision')()
          .toDartString(),
      errorMessage = library
          .lookupFunction<_NativeErrorMessage, _DartErrorMessage>(
            'pw_jxl_error_message',
          ),
      encodeFile = library.lookupFunction<_NativeEncodeFile, _DartEncodeFile>(
        'pw_jxl_encode_jpeg_file',
      ),
      reconstructFile = library
          .lookupFunction<_NativeReconstructFile, _DartReconstructFile>(
            'pw_jxl_reconstruct_jpeg_file',
          ) {
    if (version != '0.12.0' ||
        revision != PhotoArchivePolicy.pinnedLibjxlRevision) {
      throw StateError('unexpected libjxl bridge identity: $version $revision');
    }
  }

  final String version;
  final String revision;
  final _DartErrorMessage errorMessage;
  final _DartEncodeFile encodeFile;
  final _DartReconstructFile reconstructFile;

  static _NativeJxlBindings? tryLoad() {
    if (!Platform.isIOS) return null;
    try {
      return _NativeJxlBindings._(DynamicLibrary.process());
    } catch (_) {
      return null;
    }
  }

  static _NativeJxlBindings loadRequired() {
    final bindings = tryLoad();
    if (bindings == null) {
      throw UnsupportedError('pinned libjxl bridge is unavailable');
    }
    return bindings;
  }

  void checkStatus(int status) {
    if (status == 0) return;
    throw StateError(
      'libjxl bridge $status: ${errorMessage(status).toDartString()}',
    );
  }
}
