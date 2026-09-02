import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'photo_archive_codec.dart';

/// Official Microsoft Rust Lepton 0.5.8 codec selected after the registered
/// physical-iPhone size and exactness gate passed.
class LeptonFfiPhotoArchiveCodec implements PhotoArchiveCodec {
  static const expectedVersion = '0.5.8';
  static const expectedRevision = '90fdc27828676892fbb41777cfcc6bad1e470516';

  bool? _supported;

  @override
  bool get isSupported {
    if (!Platform.isIOS) return false;
    return _supported ??= _NativeLeptonBindings.tryLoad() != null;
  }

  String get version => _NativeLeptonBindings.loadRequired().version;
  String get revision => _NativeLeptonBindings.loadRequired().revision;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    await encodeJpegMeasured(
      sourceJpeg: sourceJpeg,
      destinationLepton: destinationJxl,
    );
  }

  Future<int> encodeJpegMeasured({
    required File sourceJpeg,
    required File destinationLepton,
  }) {
    if (!isSupported) {
      throw UnsupportedError('official Lepton 0.5.8 bridge is unavailable');
    }
    final generation = _NativeLeptonBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () => _encodeFile(sourceJpeg.path, destinationLepton.path, generation),
    );
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    await reconstructJpegMeasured(
      sourceLepton: sourceJxl,
      destinationJpeg: destinationJpeg,
    );
  }

  Future<int> reconstructJpegMeasured({
    required File sourceLepton,
    required File destinationJpeg,
  }) {
    if (!isSupported) {
      throw UnsupportedError('official Lepton 0.5.8 bridge is unavailable');
    }
    final generation = _NativeLeptonBindings.loadRequired()
        .cancellationGeneration();
    return Isolate.run(
      () =>
          _reconstructFile(sourceLepton.path, destinationJpeg.path, generation),
    );
  }

  @override
  void requestCancellation() {
    _NativeLeptonBindings.tryLoad()?.requestCancel();
  }
}

int _encodeFile(String sourcePath, String destinationPath, int generation) {
  final bindings = _NativeLeptonBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.encodeFileCancellable(source, destination, generation, elapsed),
    );
    return elapsed.value;
  } finally {
    calloc
      ..free(elapsed)
      ..free(destination)
      ..free(source);
  }
}

int _reconstructFile(
  String sourcePath,
  String destinationPath,
  int generation,
) {
  final bindings = _NativeLeptonBindings.loadRequired();
  final source = sourcePath.toNativeUtf8(allocator: calloc);
  final destination = destinationPath.toNativeUtf8(allocator: calloc);
  final elapsed = calloc<Uint64>();
  try {
    bindings.checkStatus(
      bindings.reconstructFileCancellable(
        source,
        destination,
        generation,
        elapsed,
      ),
    );
    return elapsed.value;
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
typedef _NativeGeneration = Uint64 Function();
typedef _DartGeneration = int Function();
typedef _NativeCancel = Void Function();
typedef _DartCancel = void Function();
typedef _NativeCancellableFileOperation = Int32 Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Uint64,
  Pointer<Uint64>,
);
typedef _DartCancellableFileOperation = int Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  Pointer<Uint64>,
);

class _NativeLeptonBindings {
  _NativeLeptonBindings._(DynamicLibrary library)
    : version = library
          .lookupFunction<_NativeCString, _DartCString>('pw_lepton_version')()
          .toDartString(),
      revision = library
          .lookupFunction<_NativeCString, _DartCString>('pw_lepton_revision')()
          .toDartString(),
      errorMessage = library
          .lookupFunction<_NativeErrorMessage, _DartErrorMessage>(
            'pw_lepton_error_message',
          ),
      cancellationGeneration = library
          .lookupFunction<_NativeGeneration, _DartGeneration>(
            'pw_lepton_cancellation_generation',
          ),
      requestCancel = library.lookupFunction<_NativeCancel, _DartCancel>(
        'pw_lepton_request_cancel',
      ),
      encodeFileCancellable = library
          .lookupFunction<
            _NativeCancellableFileOperation,
            _DartCancellableFileOperation
          >('pw_lepton_encode_jpeg_file_cancellable'),
      reconstructFileCancellable = library
          .lookupFunction<
            _NativeCancellableFileOperation,
            _DartCancellableFileOperation
          >('pw_lepton_reconstruct_jpeg_file_cancellable') {
    if (version != '0.5.8' ||
        revision != LeptonFfiPhotoArchiveCodec.expectedRevision) {
      throw StateError('unexpected Lepton bridge identity: $version $revision');
    }
  }

  final String version;
  final String revision;
  final _DartErrorMessage errorMessage;
  final _DartGeneration cancellationGeneration;
  final _DartCancel requestCancel;
  final _DartCancellableFileOperation encodeFileCancellable;
  final _DartCancellableFileOperation reconstructFileCancellable;

  static _NativeLeptonBindings? tryLoad() {
    if (!Platform.isIOS) return null;
    try {
      return _NativeLeptonBindings._(DynamicLibrary.process());
    } catch (_) {
      return null;
    }
  }

  static _NativeLeptonBindings loadRequired() {
    final bindings = tryLoad();
    if (bindings == null) {
      throw UnsupportedError('official Lepton 0.5.8 bridge is unavailable');
    }
    return bindings;
  }

  void checkStatus(int status) {
    if (status == 0) return;
    if (status == 5) throw const PhotoArchiveCancelled();
    throw StateError(
      'Lepton bridge $status: ${errorMessage(status).toDartString()}',
    );
  }
}
