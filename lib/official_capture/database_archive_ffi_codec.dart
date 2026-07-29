import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'database_archive_codec.dart';
import 'database_archive_policy.dart';

/// Production database codec backed by the pinned portable libzpaq bridge.
class ZpaqFfiDatabaseArchiveCodec implements DatabaseArchiveCodec {
  bool? _supported;

  @override
  bool get isSupported {
    if (!Platform.isIOS) return false;
    return _supported ??= _NativeZpaqBindings.tryLoad() != null;
  }

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) {
    if (!isSupported) {
      throw UnsupportedError('pinned ZPAQ bridge is unavailable');
    }
    final sourcePath = sourceDatabase.path;
    final destinationPath = destinationArchive.path;
    final generation = _NativeZpaqBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () => _compressFile(sourcePath, destinationPath, generation),
    );
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) {
    if (!isSupported) {
      throw UnsupportedError('pinned ZPAQ bridge is unavailable');
    }
    final sourcePath = sourceArchive.path;
    final destinationPath = destinationDatabase.path;
    final generation = _NativeZpaqBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () => _decompressFile(sourcePath, destinationPath, generation),
    );
  }

  @override
  void requestCancellation() {
    if (!Platform.isIOS) return;
    _NativeZpaqBindings.tryLoad()?.requestCancel();
  }
}

void _compressFile(
  String sourcePath,
  String destinationPath,
  int cancellationGeneration,
) {
  final bindings = _NativeZpaqBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  try {
    bindings.checkStatus(
      bindings.compressFile(
        source,
        destination,
        DatabaseArchivePolicy.method5,
        cancellationGeneration,
      ),
    );
  } finally {
    calloc
      ..free(destination)
      ..free(source);
  }
}

void _decompressFile(
  String sourcePath,
  String destinationPath,
  int cancellationGeneration,
) {
  final bindings = _NativeZpaqBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  try {
    bindings.checkStatus(
      bindings.decompressFile(source, destination, cancellationGeneration),
    );
  } finally {
    calloc
      ..free(destination)
      ..free(source);
  }
}

typedef _NativeCString = Pointer<Utf8> Function();
typedef _DartCString = Pointer<Utf8> Function();
typedef _NativeErrorMessage = Pointer<Utf8> Function(Int32);
typedef _DartErrorMessage = Pointer<Utf8> Function(int);
typedef _NativeCompressFile =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Uint64);
typedef _DartCompressFile =
    int Function(Pointer<Utf8>, Pointer<Utf8>, int, int);
typedef _NativeDecompressFile =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint64);
typedef _DartDecompressFile = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _NativeCancellationGeneration = Uint64 Function();
typedef _DartCancellationGeneration = int Function();
typedef _NativeRequestCancel = Void Function();
typedef _DartRequestCancel = void Function();

class _NativeZpaqBindings {
  _NativeZpaqBindings._(DynamicLibrary library)
    : version = library
          .lookupFunction<_NativeCString, _DartCString>('pw_zpaq_version')()
          .toDartString(),
      revision = library
          .lookupFunction<_NativeCString, _DartCString>('pw_zpaq_revision')()
          .toDartString(),
      errorMessage = library
          .lookupFunction<_NativeErrorMessage, _DartErrorMessage>(
            'pw_zpaq_error_message',
          ),
      lastError = library.lookupFunction<_NativeCString, _DartCString>(
        'pw_zpaq_last_error',
      ),
      compressFile = library
          .lookupFunction<_NativeCompressFile, _DartCompressFile>(
            'pw_zpaq_compress_file',
          ),
      decompressFile = library
          .lookupFunction<_NativeDecompressFile, _DartDecompressFile>(
            'pw_zpaq_decompress_file',
          ),
      cancellationGeneration = library
          .lookupFunction<
            _NativeCancellationGeneration,
            _DartCancellationGeneration
          >('pw_zpaq_cancellation_generation'),
      requestCancel = library
          .lookupFunction<_NativeRequestCancel, _DartRequestCancel>(
            'pw_zpaq_request_cancel',
          ) {
    if (version != DatabaseArchivePolicy.version715 ||
        revision != DatabaseArchivePolicy.pinnedRevision) {
      throw StateError('unexpected ZPAQ bridge identity: $version $revision');
    }
  }

  static const cancelledStatus = 10;

  final String version;
  final String revision;
  final _DartErrorMessage errorMessage;
  final _DartCString lastError;
  final _DartCompressFile compressFile;
  final _DartDecompressFile decompressFile;
  final _DartCancellationGeneration cancellationGeneration;
  final _DartRequestCancel requestCancel;

  static _NativeZpaqBindings? tryLoad() {
    if (!Platform.isIOS) return null;
    try {
      return _NativeZpaqBindings._(DynamicLibrary.process());
    } catch (_) {
      return null;
    }
  }

  static _NativeZpaqBindings loadRequired() {
    final bindings = tryLoad();
    if (bindings == null) {
      throw UnsupportedError('pinned ZPAQ bridge is unavailable');
    }
    return bindings;
  }

  void checkStatus(int status) {
    if (status == 0) return;
    if (status == cancelledStatus) {
      throw const DatabaseArchiveCancelled();
    }
    final detail = lastError().toDartString();
    throw StateError(
      'ZPAQ bridge $status: ${errorMessage(status).toDartString()}'
      '${detail.isEmpty ? '' : ' ($detail)'}',
    );
  }
}
