import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'database_archive_codec.dart';
import 'database_archive_preprocessor.dart';

/// Production reversible preprocessor backed by the C++17 SQLite bridge.
class TrackDeltaFfiDatabaseArchivePreprocessor
    implements DatabaseArchivePreprocessor {
  bool? _supported;

  @override
  bool get isSupported {
    if (!Platform.isIOS) return false;
    return _supported ??= _NativeTrackDeltaBindings.tryLoad() != null;
  }

  @override
  Future<void> transformTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) => _run(sourceDatabase.path, destinationDatabase.path, false);

  @override
  Future<void> restoreTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) => _run(sourceDatabase.path, destinationDatabase.path, true);

  Future<void> _run(String sourcePath, String destinationPath, bool inverse) {
    if (!isSupported) {
      throw UnsupportedError('track-delta SQLite bridge is unavailable');
    }
    final generation = _NativeTrackDeltaBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () => _transformFile(sourcePath, destinationPath, inverse, generation),
    );
  }

  @override
  void requestCancellation() {
    if (!Platform.isIOS) return;
    _NativeTrackDeltaBindings.tryLoad()?.requestCancel();
  }

  Future<bool> integrityCheck(File database) {
    if (!isSupported) return Future<bool>.value(false);
    final path = database.path;
    return Isolate.run(() => _integrityCheckFile(path));
  }
}

/// Benchmark-only exact transform v2 adapter.
///
/// Production manifests do not know this transform until the independent
/// physical-iPhone size and exactness gates admit it.
class ExactTransformV2FfiBenchmarkPreprocessor {
  bool? _supported;

  bool get isSupported {
    if (!Platform.isIOS) return false;
    return _supported ??= _NativeTrackDeltaBindings.tryLoad() != null;
  }

  Future<void> transform({
    required File sourceDatabase,
    required File destinationDatabase,
  }) => _runExactV2(sourceDatabase.path, destinationDatabase.path, false);

  Future<void> restore({
    required File sourceDatabase,
    required File destinationDatabase,
  }) => _runExactV2(sourceDatabase.path, destinationDatabase.path, true);

  Future<bool> integrityCheck(File database) {
    if (!isSupported) return Future<bool>.value(false);
    final path = database.path;
    return Isolate.run(() => _integrityCheckFile(path));
  }

  void requestCancellation() {
    if (!Platform.isIOS) return;
    _NativeTrackDeltaBindings.tryLoad()?.requestCancel();
  }
}

Future<void> _runExactV2(
  String sourcePath,
  String destinationPath,
  bool inverse,
) {
  final bindings = _NativeTrackDeltaBindings.loadRequired();
  final generation = bindings.cancellationGeneration();
  return Isolate.run(
    () => _transformFileWithTransform(
      sourcePath,
      destinationPath,
      inverse,
      generation,
      _NativeTrackDeltaBindings.exactTransformV2,
    ),
  );
}

bool _integrityCheckFile(String path) {
  final bindings = _NativeTrackDeltaBindings.loadRequired();
  final nativePath = path.toNativeUtf8(allocator: calloc);
  try {
    return bindings.integrityCheck(nativePath) == 1;
  } finally {
    calloc.free(nativePath);
  }
}

void _transformFile(
  String sourcePath,
  String destinationPath,
  bool inverse,
  int cancellationGeneration,
) {
  _transformFileWithTransform(
    sourcePath,
    destinationPath,
    inverse,
    cancellationGeneration,
    _NativeTrackDeltaBindings.trackDeltaTransform,
  );
}

void _transformFileWithTransform(
  String sourcePath,
  String destinationPath,
  bool inverse,
  int cancellationGeneration,
  int transform,
) {
  final bindings = _NativeTrackDeltaBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  try {
    bindings.checkStatus(
      bindings.transformFile(
        source,
        destination,
        transform,
        inverse ? 1 : 0,
        cancellationGeneration,
        nullptr,
      ),
    );
  } finally {
    calloc
      ..free(destination)
      ..free(source);
  }
}

typedef _NativeTransformFile = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Uint64,
  Pointer<Void>,
);
typedef _DartTransformFile = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  Pointer<Void>,
);
typedef _NativeCancellationGeneration = Uint64 Function();
typedef _DartCancellationGeneration = int Function();
typedef _NativeRequestCancel = Void Function();
typedef _DartRequestCancel = void Function();
typedef _NativeLastError = Pointer<Utf8> Function();
typedef _DartLastError = Pointer<Utf8> Function();
typedef _NativeIntegrityCheck = Int32 Function(Pointer<Utf8>);
typedef _DartIntegrityCheck = int Function(Pointer<Utf8>);

class _NativeTrackDeltaBindings {
  _NativeTrackDeltaBindings._(DynamicLibrary library)
    : transformFile = library
          .lookupFunction<_NativeTransformFile, _DartTransformFile>(
            'pw_sqlite_descriptor_transform_file_cancellable',
          ),
      cancellationGeneration = library
          .lookupFunction<
            _NativeCancellationGeneration,
            _DartCancellationGeneration
          >('pw_sqlite_descriptor_transform_cancellation_generation'),
      requestCancel = library
          .lookupFunction<_NativeRequestCancel, _DartRequestCancel>(
            'pw_sqlite_descriptor_transform_request_cancel',
          ),
      lastError = library.lookupFunction<_NativeLastError, _DartLastError>(
        'pw_sqlite_descriptor_transform_last_error',
      ),
      integrityCheck = library
          .lookupFunction<_NativeIntegrityCheck, _DartIntegrityCheck>(
            'pw_sqlite_descriptor_integrity_check_file',
          );

  static const trackDeltaTransform = 4;
  static const exactTransformV2 = 5;
  static const cancelledStatus = 8;

  final _DartTransformFile transformFile;
  final _DartCancellationGeneration cancellationGeneration;
  final _DartRequestCancel requestCancel;
  final _DartLastError lastError;
  final _DartIntegrityCheck integrityCheck;

  static _NativeTrackDeltaBindings? tryLoad() {
    if (!Platform.isIOS) return null;
    try {
      return _NativeTrackDeltaBindings._(DynamicLibrary.process());
    } catch (_) {
      return null;
    }
  }

  static _NativeTrackDeltaBindings loadRequired() {
    final bindings = tryLoad();
    if (bindings == null) {
      throw UnsupportedError('track-delta SQLite bridge is unavailable');
    }
    return bindings;
  }

  void checkStatus(int status) {
    if (status == 0) return;
    if (status == cancelledStatus) throw const DatabaseArchiveCancelled();
    throw StateError(
      'track-delta SQLite bridge $status: ${lastError().toDartString()}',
    );
  }
}
