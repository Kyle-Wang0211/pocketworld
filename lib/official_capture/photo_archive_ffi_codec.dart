import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'photo_archive_codec.dart';
import 'photo_archive_policy.dart';

/// Production JPEG XL codec backed by the pinned native libjxl bridge.
class JxlFfiPhotoArchiveCodec implements PhotoArchiveCodec {
  JxlFfiPhotoArchiveCodec({this.effort = 10});

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
    final generation = _NativeJxlBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () =>
          _encodeFile(sourcePath, destinationPath, selectedEffort, generation),
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
    final generation = _NativeJxlBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () => _reconstructFile(sourcePath, destinationPath, generation),
    );
  }

  @override
  void requestCancellation() {
    if (!Platform.isIOS) return;
    _NativeJxlBindings.tryLoad()?.requestCancel();
  }
}

void _encodeFile(
  String sourcePath,
  String destinationPath,
  int effort,
  int cancellationGeneration,
) {
  final bindings = _NativeJxlBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.encodeFileCancellable(
        source,
        destination,
        effort,
        cancellationGeneration,
        elapsed,
      ),
    );
  } finally {
    calloc
      ..free(elapsed)
      ..free(destination)
      ..free(source);
  }
}

void _reconstructFile(
  String sourcePath,
  String destinationPath,
  int cancellationGeneration,
) {
  final bindings = _NativeJxlBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.reconstructFileCancellable(
        source,
        destination,
        cancellationGeneration,
        elapsed,
      ),
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
typedef _NativeEncodeFile = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Pointer<Uint64>,
);
typedef _DartEncodeFile = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Uint64>,
);
typedef _NativeReconstructFile = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint64>,
);
typedef _DartReconstructFile = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Uint64>,
);
typedef _NativeEncodeFileCancellable = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Uint64,
  Pointer<Uint64>,
);
typedef _DartEncodeFileCancellable = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  Pointer<Uint64>,
);
typedef _NativeReconstructFileCancellable = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint64,
  Pointer<Uint64>,
);
typedef _DartReconstructFileCancellable = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Uint64>,
);
typedef _NativeCancellationGeneration = Uint64 Function();
typedef _DartCancellationGeneration = int Function();
typedef _NativeRequestCancel = Void Function();
typedef _DartRequestCancel = void Function();

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
          ),
      encodeFileCancellable = library
          .lookupFunction<
            _NativeEncodeFileCancellable,
            _DartEncodeFileCancellable
          >('pw_jxl_encode_jpeg_file_cancellable'),
      reconstructFileCancellable = library
          .lookupFunction<
            _NativeReconstructFileCancellable,
            _DartReconstructFileCancellable
          >('pw_jxl_reconstruct_jpeg_file_cancellable'),
      cancellationGeneration = library
          .lookupFunction<
            _NativeCancellationGeneration,
            _DartCancellationGeneration
          >('pw_jxl_cancellation_generation'),
      requestCancel = library
          .lookupFunction<_NativeRequestCancel, _DartRequestCancel>(
            'pw_jxl_request_cancel',
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
  final _DartEncodeFileCancellable encodeFileCancellable;
  final _DartReconstructFileCancellable reconstructFileCancellable;
  final _DartCancellationGeneration cancellationGeneration;
  final _DartRequestCancel requestCancel;

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
    if (status == 14) {
      throw const PhotoArchiveCancelled();
    }
    throw StateError(
      'libjxl bridge $status: ${errorMessage(status).toDartString()}',
    );
  }
}
