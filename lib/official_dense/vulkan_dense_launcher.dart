import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import '../official_capture/dense_stage.dart';
import 'dense_handoff.dart';
import 'dense_transaction_manifest.dart';

/// The immutable sparse-to-dense request handed to the native COLMAP/Vulkan
/// implementation. Algorithm options are intentionally absent: native owns the
/// frozen COLMAP 4.1.1 defaults rather than accepting product-side overrides.
final class OfficialDenseNativeRequest {
  OfficialDenseNativeRequest({
    required this.workspaceDirectory,
    required this.modelDirectory,
    required this.modelFiles,
    required this.fedFramesManifest,
    required this.materializationDirectory,
    required this.materializationPlan,
    required this.fusedPlyPath,
  });

  factory OfficialDenseNativeRequest.fromHandoff({
    required OfficialDenseHandoff handoff,
    required DenseHandoffFile handoffReady,
    required String workspaceDirectory,
    required String fusedPlyPath,
  }) {
    return OfficialDenseNativeRequest(
      workspaceDirectory: workspaceDirectory,
      modelDirectory: handoff.modelDirectory,
      modelFiles: <DenseHandoffFile>[...handoff.modelFiles, handoffReady],
      fedFramesManifest: handoff.fedFramesManifest,
      materializationDirectory: handoff.materializationDirectory,
      materializationPlan: handoff.materializationPlan,
      fusedPlyPath: fusedPlyPath,
    );
  }

  final String workspaceDirectory;
  final String modelDirectory;
  final List<DenseHandoffFile> modelFiles;
  final DenseHandoffFile fedFramesManifest;
  final String materializationDirectory;
  final List<DenseImageMaterialization> materializationPlan;
  final String fusedPlyPath;
}

final class OfficialDenseNativeResult {
  const OfficialDenseNativeResult._(this.succeeded, this.message);

  const OfficialDenseNativeResult.success() : this._(true, null);

  const OfficialDenseNativeResult.failed(String message)
    : this._(false, message);

  final bool succeeded;
  final String? message;
}

/// Injectable native boundary. Tests never need to load a process library.
abstract interface class OfficialDenseNativeAdapter {
  bool get isAvailable;

  Future<OfficialDenseNativeTransaction> openTransaction({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  });

  Future<OfficialDenseNativeResult> run(OfficialDenseNativeRequest request);
}

/// An already-open native directory-descriptor transaction. Paths passed to
/// these methods are relative to the native dense/run descriptors, never
/// re-resolved from Dart absolute path strings.
abstract interface class OfficialDenseNativeTransaction {
  Future<void> removeRunEntry(String runRelativePath);

  Future<void> removeRunDirectory();

  Future<void> publishPly({
    required String runRelativeSource,
    required String denseRelativeDestination,
  });

  Future<void> close();
}

/// Injectable execution boundary. Production uses [Isolate.run], while tests
/// may execute inline and assert that the boundary was crossed.
abstract interface class OfficialDenseExecutor {
  Future<T> run<T>(Future<T> Function() operation);
}

final class IsolateOfficialDenseExecutor implements OfficialDenseExecutor {
  const IsolateOfficialDenseExecutor();

  @override
  Future<T> run<T>(Future<T> Function() operation) => Isolate.run(operation);
}

final class UnavailableOfficialDenseNativeAdapter
    implements OfficialDenseNativeAdapter {
  const UnavailableOfficialDenseNativeAdapter([this.reason]);

  final String? reason;

  @override
  bool get isAvailable => false;

  @override
  Future<OfficialDenseNativeTransaction> openTransaction({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  }) {
    throw UnsupportedError(reason ?? 'native dense stage unavailable');
  }

  @override
  Future<OfficialDenseNativeResult> run(OfficialDenseNativeRequest request) {
    return Future<OfficialDenseNativeResult>.value(
      OfficialDenseNativeResult.failed(
        reason ?? 'native dense stage unavailable',
      ),
    );
  }
}

final class _OfficialDenseRunPaths {
  _OfficialDenseRunPaths._({
    required this.captureDirectory,
    required this.denseDirectory,
    required this.sourceSparseDirectory,
    required this.sourceFedFramesManifest,
    required this.runsDirectory,
    required this.runDirectory,
    required this.runRelativeDirectory,
    required this.workspaceDirectory,
    required this.workspaceSparseDirectory,
    required this.workspaceImagesDirectory,
    required this.workspaceFedFramesManifest,
    required this.temporaryFusedPly,
    required this.publishedFusedPly,
  });

  final String captureDirectory;
  final String denseDirectory;
  final String sourceSparseDirectory;
  final String sourceFedFramesManifest;
  final String runsDirectory;
  final String runDirectory;
  final String runRelativeDirectory;
  final String workspaceDirectory;
  final String workspaceSparseDirectory;
  final String workspaceImagesDirectory;
  final String workspaceFedFramesManifest;
  final String temporaryFusedPly;
  final String publishedFusedPly;

  static Future<_OfficialDenseRunPaths> create(
    String capturePath, {
    required int runSequence,
  }) async {
    final capture = await _canonicalExistingDirectory(
      capturePath,
      label: 'capture',
    );
    final dense = await _canonicalExistingDirectory(
      _join(capture, 'official_dense'),
      label: 'official_dense',
      containingDirectory: capture,
    );
    final sourceSparse = await _canonicalExistingDirectory(
      _join(dense, 'sparse'),
      label: 'official_dense/sparse',
      containingDirectory: capture,
    );
    final published = _join(dense, 'fused.ply');

    final runs = await _ensureDirectory(
      _join(dense, '.pwofficial_dense_runs'),
      label: 'official dense runs',
      containingDirectory: capture,
    );
    final runName =
        'run-${DateTime.now().microsecondsSinceEpoch}-$pid-$runSequence';
    final run = _join(runs, runName);
    await _createFreshDirectory(
      run,
      label: 'official dense run',
      containingDirectory: runs,
    );
    final workspace = await _createFreshDirectory(
      _join(run, 'workspace'),
      label: 'official dense workspace',
      containingDirectory: run,
    );
    final workspaceSparse = await _createFreshDirectory(
      _join(workspace, 'sparse'),
      label: 'official dense workspace sparse',
      containingDirectory: workspace,
    );
    return _OfficialDenseRunPaths._(
      captureDirectory: capture,
      denseDirectory: dense,
      sourceSparseDirectory: sourceSparse,
      sourceFedFramesManifest: _join(capture, 'official_sfm_fed_frames.jsonl'),
      runsDirectory: runs,
      runDirectory: run,
      runRelativeDirectory: '.pwofficial_dense_runs/$runName',
      workspaceDirectory: workspace,
      workspaceSparseDirectory: workspaceSparse,
      workspaceImagesDirectory: _join(workspace, 'images'),
      workspaceFedFramesManifest: _join(
        workspace,
        'official_sfm_fed_frames.jsonl',
      ),
      temporaryFusedPly: _join(run, 'fused.ply.pending'),
      publishedFusedPly: published,
    );
  }
}

Future<String> _canonicalExistingDirectory(
  String path, {
  required String label,
  String? containingDirectory,
}) async {
  final absolute = Directory(path).absolute.path;
  final type = await FileSystemEntity.type(absolute, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException('$label must not be a symlink', absolute);
  }
  if (type != FileSystemEntityType.directory) {
    throw FileSystemException('$label is not a directory', absolute);
  }
  final real = await Directory(absolute).resolveSymbolicLinks();
  if (containingDirectory != null && !_isWithin(containingDirectory, real)) {
    throw FileSystemException('$label escaped its capture directory', real);
  }
  return real;
}

Future<String> _ensureDirectory(
  String path, {
  required String label,
  required String containingDirectory,
}) async {
  final absolute = Directory(path).absolute.path;
  final type = await FileSystemEntity.type(absolute, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    await Directory(absolute).create();
  } else if (type == FileSystemEntityType.link) {
    throw FileSystemException('$label must not be a symlink', absolute);
  } else if (type != FileSystemEntityType.directory) {
    throw FileSystemException('$label is not a directory', absolute);
  }
  return _canonicalExistingDirectory(
    absolute,
    label: label,
    containingDirectory: containingDirectory,
  );
}

Future<String> _createFreshDirectory(
  String path, {
  required String label,
  required String containingDirectory,
}) async {
  final absolute = Directory(path).absolute.path;
  final type = await FileSystemEntity.type(absolute, followLinks: false);
  if (type != FileSystemEntityType.notFound) {
    throw FileSystemException('$label already exists', absolute);
  }
  await Directory(absolute).create();
  return _canonicalExistingDirectory(
    absolute,
    label: label,
    containingDirectory: containingDirectory,
  );
}

bool _isWithin(String root, String child) {
  final normalizedRoot = Directory(root).absolute.path;
  final normalizedChild = Directory(child).absolute.path;
  return normalizedChild == normalizedRoot ||
      normalizedChild.startsWith('$normalizedRoot${Platform.pathSeparator}');
}

/// Exact Dart FFI mirror of `pwofficial_dense_options_t`.
final class PwOfficialDenseOptions extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int abiVersion;

  @Double()
  external double depthMin;
  @Double()
  external double depthMax;
  @Double()
  external double sigmaSpatial;
  @Double()
  external double sigmaColor;
  @Double()
  external double nccSigma;
  @Double()
  external double minTriangulationAngle;
  @Double()
  external double incidentAngleSigma;
  @Double()
  external double geomConsistencyRegularizer;
  @Double()
  external double geomConsistencyMaxCost;
  @Double()
  external double filterMinNcc;
  @Double()
  external double filterMinTriangulationAngle;
  @Double()
  external double filterGeomConsistencyMaxCost;
  @Double()
  external double patchMatchCacheSize;
  @Array(32)
  external Array<Int8> gpuIndex;
  @Int32()
  external int patchMatchMaxImageSize;
  @Int32()
  external int windowRadius;
  @Int32()
  external int windowStep;
  @Int32()
  external int numSamples;
  @Int32()
  external int numIterations;
  @Int32()
  external int filterMinNumConsistent;
  @Int32()
  external int patchMatchNumThreads;
  @Int32()
  external int geomConsistency;
  @Int32()
  external int filter;
  @Int32()
  external int allowMissingFiles;
  @Int32()
  external int writeConsistencyGraph;

  @Array(1024)
  external Array<Int8> maskPath;
  @Int32()
  external int fusionNumThreads;
  @Int32()
  external int fusionMaxImageSize;
  @Int32()
  external int minNumPixels;
  @Int32()
  external int maxNumPixels;
  @Int32()
  external int maxTraversalDepth;
  @Double()
  external double maxReprojError;
  @Double()
  external double maxDepthError;
  @Double()
  external double maxNormalError;
  @Int32()
  external int checkNumImages;
  @Int32()
  external int useCache;
  @Double()
  external double fusionCacheSize;
  @Array(3)
  external Array<Float> boundingBoxMin;
  @Array(3)
  external Array<Float> boundingBoxMax;
}

/// Auditable offsets for the public C layout. Contract tests compare every
/// entry against a macOS arm64 C `offsetof` oracle.
abstract final class PwOfficialDenseOptionsLayout {
  static const int size = 1296;
  static const Map<String, int> offsets = <String, int>{
    'struct_size': 0,
    'abi_version': 4,
    'depth_min': 8,
    'depth_max': 16,
    'sigma_spatial': 24,
    'sigma_color': 32,
    'ncc_sigma': 40,
    'min_triangulation_angle': 48,
    'incident_angle_sigma': 56,
    'geom_consistency_regularizer': 64,
    'geom_consistency_max_cost': 72,
    'filter_min_ncc': 80,
    'filter_min_triangulation_angle': 88,
    'filter_geom_consistency_max_cost': 96,
    'patch_match_cache_size': 104,
    'gpu_index': 112,
    'patch_match_max_image_size': 144,
    'window_radius': 148,
    'window_step': 152,
    'num_samples': 156,
    'num_iterations': 160,
    'filter_min_num_consistent': 164,
    'patch_match_num_threads': 168,
    'geom_consistency': 172,
    'filter': 176,
    'allow_missing_files': 180,
    'write_consistency_graph': 184,
    'mask_path': 188,
    'fusion_num_threads': 1212,
    'fusion_max_image_size': 1216,
    'min_num_pixels': 1220,
    'max_num_pixels': 1224,
    'max_traversal_depth': 1228,
    'max_reproj_error': 1232,
    'max_depth_error': 1240,
    'max_normal_error': 1248,
    'check_num_images': 1256,
    'use_cache': 1260,
    'fusion_cache_size': 1264,
    'bounding_box_min': 1272,
    'bounding_box_max': 1284,
  };
}

typedef _VersionC = Uint32 Function();
typedef _VersionDart = int Function();
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();
typedef _DefaultOptionsC = Int32 Function(Pointer<PwOfficialDenseOptions>);
typedef _DefaultOptionsDart = int Function(Pointer<PwOfficialDenseOptions>);
typedef _IsAvailableC = Int32 Function();
typedef _IsAvailableDart = int Function();
typedef _RunC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<PwOfficialDenseOptions>,
    );
typedef _RunDart =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<PwOfficialDenseOptions>);
typedef _CancelC = Int32 Function();
typedef _CancelDart = int Function();
typedef _TxOpenC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );
typedef _TxOpenDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );
typedef _TxOnePathC = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _TxOnePathDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _TxNoPathC = Int32 Function(Pointer<Void>);
typedef _TxNoPathDart = int Function(Pointer<Void>);
typedef _TxPublishC =
    Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _TxPublishDart =
    int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _TxLastErrorC = Pointer<Utf8> Function();
typedef _TxLastErrorDart = Pointer<Utf8> Function();
typedef _TxCloseC = Void Function(Pointer<Void>);
typedef _TxCloseDart = void Function(Pointer<Void>);

final class _ProcessOfficialDenseNativeTransaction
    implements OfficialDenseNativeTransaction {
  _ProcessOfficialDenseNativeTransaction(this._handle);

  Pointer<Void> _handle;

  bool get _isOpen => _handle != nullptr;

  @override
  Future<void> removeRunEntry(String runRelativePath) async {
    _requireOpen();
    final path = runRelativePath.toNativeUtf8();
    try {
      _checkTransactionResult(
        ProcessOfficialDenseNativeAdapter._lookupTxRemoveRun()(_handle, path),
        'native run cleanup failed',
      );
    } finally {
      malloc.free(path);
    }
  }

  @override
  Future<void> removeRunDirectory() async {
    _requireOpen();
    _checkTransactionResult(
      ProcessOfficialDenseNativeAdapter._lookupTxRemoveRunDirectory()(_handle),
      'native run-directory cleanup failed',
    );
  }

  @override
  Future<void> publishPly({
    required String runRelativeSource,
    required String denseRelativeDestination,
  }) async {
    _requireOpen();
    final source = runRelativeSource.toNativeUtf8();
    final destination = denseRelativeDestination.toNativeUtf8();
    try {
      _checkTransactionResult(
        ProcessOfficialDenseNativeAdapter._lookupTxPublish()(
          _handle,
          source,
          destination,
        ),
        'native PLY publication failed',
      );
    } finally {
      malloc.free(destination);
      malloc.free(source);
    }
  }

  @override
  Future<void> close() async {
    if (!_isOpen) return;
    ProcessOfficialDenseNativeAdapter._lookupTxClose()(_handle);
    _handle = nullptr;
  }

  void _requireOpen() {
    if (!_isOpen) throw StateError('native transaction is closed');
  }

  static void _checkTransactionResult(int code, String fallback) {
    if (code == 0) return;
    String message = '';
    try {
      final pointer = ProcessOfficialDenseNativeAdapter._lookupTxLastError()();
      if (pointer != nullptr) message = pointer.toDartString();
    } catch (_) {}
    throw FileSystemException(
      message.isEmpty ? '$fallback with code $code' : message,
    );
  }
}

/// C ABI adapter for the statically linked mobile library.
///
/// Loading is explicit and fail-closed. Merely constructing a launcher never
/// makes the global [denseStageLauncher] available.
final class ProcessOfficialDenseNativeAdapter
    implements OfficialDenseNativeAdapter {
  const ProcessOfficialDenseNativeAdapter._();

  static OfficialDenseNativeAdapter tryCreate() {
    try {
      _lookupVersion();
      _lookupLastError();
      _lookupDefaultOptions();
      _lookupIsAvailable();
      _lookupRun();
      _lookupCancel();
      _lookupTxOpen();
      _lookupTxRemoveRun();
      _lookupTxRemoveRunDirectory();
      _lookupTxPublish();
      _lookupTxLastError();
      _lookupTxClose();
      return const ProcessOfficialDenseNativeAdapter._();
    } catch (error) {
      return UnavailableOfficialDenseNativeAdapter('$error');
    }
  }

  @override
  bool get isAvailable {
    try {
      return _lookupVersion()() == 1 && _lookupIsAvailable()() == 1;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<OfficialDenseNativeTransaction> openTransaction({
    required String captureDirectory,
    required String denseRelativeDirectory,
    required String runRelativeDirectory,
  }) async {
    final capture = captureDirectory.toNativeUtf8();
    final dense = denseRelativeDirectory.toNativeUtf8();
    final run = runRelativeDirectory.toNativeUtf8();
    final output = calloc<Pointer<Void>>();
    try {
      final code = _lookupTxOpen()(capture, dense, run, output);
      _ProcessOfficialDenseNativeTransaction._checkTransactionResult(
        code,
        'native transaction open failed',
      );
      if (output.value == nullptr) {
        throw const FileSystemException(
          'native transaction returned a null handle',
        );
      }
      return _ProcessOfficialDenseNativeTransaction(output.value);
    } finally {
      calloc.free(output);
      malloc.free(run);
      malloc.free(dense);
      malloc.free(capture);
    }
  }

  @override
  Future<OfficialDenseNativeResult> run(
    OfficialDenseNativeRequest request,
  ) async {
    final options = calloc<PwOfficialDenseOptions>();
    Pointer<Utf8>? workspacePath;
    Pointer<Utf8>? outputPath;
    try {
      if (_lookupVersion()() != 1) {
        return const OfficialDenseNativeResult.failed(
          'native dense ABI version is not 1',
        );
      }
      final defaultResult = _lookupDefaultOptions()(options);
      if (defaultResult != 0) {
        return OfficialDenseNativeResult.failed(
          _resultMessage('native default_options failed', defaultResult),
        );
      }
      if (options.ref.structSize != sizeOf<PwOfficialDenseOptions>() ||
          options.ref.structSize != PwOfficialDenseOptionsLayout.size ||
          options.ref.abiVersion != 1) {
        return const OfficialDenseNativeResult.failed(
          'native dense options layout/version mismatch',
        );
      }
      workspacePath = request.workspaceDirectory.toNativeUtf8();
      outputPath = request.fusedPlyPath.toNativeUtf8();
      // Resolve inside the worker isolate. No DynamicLibrary or native function
      // pointer is captured from the UI isolate. Options are exactly the native
      // COLMAP 4.1.1 defaults and are not modified by Dart.
      final code = _lookupRun()(workspacePath, outputPath, options);
      if (code == 0) return const OfficialDenseNativeResult.success();
      return OfficialDenseNativeResult.failed(
        _resultMessage('native dense stage failed', code),
      );
    } catch (error) {
      return OfficialDenseNativeResult.failed('$error');
    } finally {
      if (workspacePath != null) malloc.free(workspacePath);
      if (outputPath != null) malloc.free(outputPath);
      calloc.free(options);
    }
  }

  String _resultMessage(String fallback, int code) {
    final message = _readLastError();
    return message.isEmpty ? '$fallback with code $code' : message;
  }

  String _readLastError() {
    try {
      final pointer = _lookupLastError()();
      if (pointer == nullptr) return '';
      return pointer.toDartString();
    } catch (_) {
      return '';
    }
  }

  static _VersionDart _lookupVersion() => DynamicLibrary.process()
      .lookupFunction<_VersionC, _VersionDart>('pwofficial_dense_version');

  static _DefaultOptionsDart _lookupDefaultOptions() => DynamicLibrary.process()
      .lookupFunction<_DefaultOptionsC, _DefaultOptionsDart>(
        'pwofficial_dense_default_options',
      );

  static _IsAvailableDart _lookupIsAvailable() =>
      DynamicLibrary.process().lookupFunction<_IsAvailableC, _IsAvailableDart>(
        'pwofficial_dense_is_available',
      );

  static _RunDart _lookupRun() => DynamicLibrary.process()
      .lookupFunction<_RunC, _RunDart>('pwofficial_dense_run');

  static _LastErrorDart _lookupLastError() =>
      DynamicLibrary.process().lookupFunction<_LastErrorC, _LastErrorDart>(
        'pwofficial_dense_last_error',
      );

  static _CancelDart _lookupCancel() => DynamicLibrary.process()
      .lookupFunction<_CancelC, _CancelDart>('pwofficial_dense_cancel');

  static _TxOpenDart _lookupTxOpen() => DynamicLibrary.process()
      .lookupFunction<_TxOpenC, _TxOpenDart>('pwofficial_dense_tx_open_v1');

  static _TxOnePathDart _lookupTxRemoveRun() =>
      DynamicLibrary.process().lookupFunction<_TxOnePathC, _TxOnePathDart>(
        'pwofficial_dense_tx_remove_run_entry_v1',
      );

  static _TxNoPathDart _lookupTxRemoveRunDirectory() =>
      DynamicLibrary.process().lookupFunction<_TxNoPathC, _TxNoPathDart>(
        'pwofficial_dense_tx_remove_run_directory_v1',
      );

  static _TxPublishDart _lookupTxPublish() =>
      DynamicLibrary.process().lookupFunction<_TxPublishC, _TxPublishDart>(
        'pwofficial_dense_tx_publish_ply_v1',
      );

  static _TxLastErrorDart _lookupTxLastError() =>
      DynamicLibrary.process().lookupFunction<_TxLastErrorC, _TxLastErrorDart>(
        'pwofficial_dense_tx_last_error_v1',
      );

  static _TxCloseDart _lookupTxClose() => DynamicLibrary.process()
      .lookupFunction<_TxCloseC, _TxCloseDart>('pwofficial_dense_tx_close_v1');
}

/// Pure-Dart bridge from the existing capture UI boundary to the native
/// COLMAP/Vulkan implementation.
///
/// This class is deliberately not installed into the global launcher. The
/// current public [DenseStageLauncher] contract has no completion channel, so
/// production [start] remains unavailable rather than returning `started`
/// after a synchronous native run. [runForVerification] exercises the frozen
/// chain without claiming that the production state machine is connected.
final class VulkanOfficialDenseStageLauncher implements DenseStageLauncher {
  VulkanOfficialDenseStageLauncher({
    required OfficialDenseNativeAdapter native,
    OfficialDenseExecutor executor = const IsolateOfficialDenseExecutor(),
  }) : _native = native,
       _executor = executor;

  factory VulkanOfficialDenseStageLauncher.process() {
    return VulkanOfficialDenseStageLauncher(
      native: ProcessOfficialDenseNativeAdapter.tryCreate(),
    );
  }

  final OfficialDenseNativeAdapter _native;
  final OfficialDenseExecutor _executor;
  static final Set<String> _activeCaptures = <String>{};
  static bool _nativeRunActive = false;
  static int _runSequence = 0;

  bool get isNativeReady => _native.isAvailable;

  @override
  bool get isAvailable => false;

  @override
  Future<DenseStageResult> start(DenseStageRequest request) {
    return Future<DenseStageResult>.value(
      const DenseStageResult(
        DenseStageStatus.unavailable,
        message:
            'native dense is not connected to a production completion status',
      ),
    );
  }

  /// End-to-end verification entrypoint. It is intentionally absent from the
  /// shared UI interface and must not be used to enable [denseStageLauncher].
  Future<DenseStageResult> runForVerification(DenseStageRequest request) async {
    if (!isNativeReady) {
      return const DenseStageResult(DenseStageStatus.unavailable);
    }

    String captureKey;
    try {
      captureKey = await _canonicalExistingDirectory(
        request.captureDir,
        label: 'capture',
      );
    } catch (error) {
      return DenseStageResult(DenseStageStatus.failed, message: '$error');
    }
    if (_activeCaptures.contains(captureKey) || _nativeRunActive) {
      return const DenseStageResult(
        DenseStageStatus.failed,
        message: 'official dense native runner is busy',
      );
    }
    _activeCaptures.add(captureKey);
    _nativeRunActive = true;
    try {
      return await _executor.run<DenseStageResult>(
        () => _run(request, captureKey),
      );
    } finally {
      _nativeRunActive = false;
      _activeCaptures.remove(captureKey);
    }
  }

  Future<DenseStageResult> _run(
    DenseStageRequest request,
    String captureRealPath,
  ) async {
    _OfficialDenseRunPaths? paths;
    OfficialDenseNativeTransaction? fileTransaction;
    try {
      paths = await _OfficialDenseRunPaths.create(
        captureRealPath,
        runSequence: _runSequence++,
      );
      fileTransaction = await _native.openTransaction(
        captureDirectory: paths.captureDirectory,
        denseRelativeDirectory: 'official_dense',
        runRelativeDirectory: paths.runRelativeDirectory,
      );

      final markerSource = File(
        _join(paths.sourceSparseDirectory, 'handoff.ready'),
      );
      final copiedMarker = await _copyStableFile(
        markerSource,
        File(_join(paths.workspaceSparseDirectory, 'handoff.ready')),
        fileName: 'handoff.ready',
      );
      final sourceSnapshots = <String, DenseHandoffFile>{
        markerSource.absolute.path: copiedMarker,
      };
      for (final fileName in const <String>[
        'cameras.bin',
        'images.bin',
        'points3D.bin',
      ]) {
        final source = File(_join(paths.sourceSparseDirectory, fileName));
        sourceSnapshots[source.absolute.path] = await _copyStableFile(
          source,
          File(_join(paths.workspaceSparseDirectory, fileName)),
          fileName: fileName,
        );
      }
      // Catch a transaction-directory replacement or a mix of old/new files
      // across the per-file copy interval.
      for (final entry in sourceSnapshots.entries) {
        await _verifyFrozenFile(
          path: entry.key,
          expectedSize: entry.value.byteSize,
          expectedSha256: entry.value.sha256,
        );
      }

      final sourceFedFramesManifest = File(paths.sourceFedFramesManifest);
      final copiedFedFramesManifest = await _copyStableFile(
        sourceFedFramesManifest,
        File(paths.workspaceFedFramesManifest),
        fileName: 'official_sfm_fed_frames.jsonl',
      );
      await _verifyFrozenFile(
        path: sourceFedFramesManifest.absolute.path,
        expectedSize: copiedFedFramesManifest.byteSize,
        expectedSha256: copiedFedFramesManifest.sha256,
      );

      final transaction = DenseTransactionManifest.readAndValidateSync(
        markerPath: copiedMarker.path,
        modelDirectory: paths.workspaceSparseDirectory,
        fedFramesManifestPath: paths.workspaceFedFramesManifest,
      );

      final registeredImageNames = await _readRegisteredImageNames(
        File(_join(paths.workspaceSparseDirectory, 'images.bin')),
      );
      final handoff = await OfficialDenseHandoff.freeze(
        modelDirectory: paths.workspaceSparseDirectory,
        fedFramesManifestPath: paths.workspaceFedFramesManifest,
        materializationDirectory: paths.workspaceImagesDirectory,
        registeredImageNames: registeredImageNames,
      );
      final nativeRequest = OfficialDenseNativeRequest.fromHandoff(
        handoff: handoff,
        handoffReady: copiedMarker,
        workspaceDirectory: paths.workspaceDirectory,
        fusedPlyPath: paths.temporaryFusedPly,
      );
      for (final frame in nativeRequest.materializationPlan) {
        transaction.requireFrameMatchesSync(
          frameId: frame.frameId,
          sourcePath: frame.sourcePath,
        );
      }
      await _materializeFrozenInputs(nativeRequest);
      await _verifyNativeRequestSnapshot(nativeRequest);

      final nativeResult = await _native.run(nativeRequest);
      if (!nativeResult.succeeded) {
        return DenseStageResult(
          DenseStageStatus.failed,
          message: nativeResult.message ?? 'native dense stage failed',
        );
      }

      final outputType = await FileSystemEntity.type(
        paths.temporaryFusedPly,
        followLinks: false,
      );
      final output = await File(paths.temporaryFusedPly).stat();
      if (outputType != FileSystemEntityType.file ||
          output.type != FileSystemEntityType.file ||
          output.size <= 0) {
        return const DenseStageResult(
          DenseStageStatus.failed,
          message: 'native dense stage did not produce a non-empty fused.ply',
        );
      }
      await fileTransaction.publishPly(
        runRelativeSource: 'fused.ply.pending',
        denseRelativeDestination: 'fused.ply',
      );
      // PublishPly performs the non-empty regular-file and inode identity
      // checks through the anchored native descriptors. Re-reading the Dart
      // absolute path here would reintroduce the ancestor-swap race.
      return const DenseStageResult.started();
    } on DenseHandoffException catch (error) {
      return DenseStageResult(DenseStageStatus.failed, message: error.message);
    } on FileSystemException catch (error) {
      return DenseStageResult(DenseStageStatus.failed, message: '$error');
    } on FormatException catch (error) {
      return DenseStageResult(DenseStageStatus.failed, message: '$error');
    } catch (error) {
      return DenseStageResult(DenseStageStatus.failed, message: '$error');
    } finally {
      if (fileTransaction != null) {
        try {
          if (paths != null) {
            await fileTransaction.removeRunDirectory();
          }
        } catch (_) {
          // Never fall back to Dart path cleanup. A failed anchored cleanup may
          // leave an orphaned run, but it cannot be redirected into user data.
        } finally {
          await fileTransaction.close();
        }
      }
    }
  }
}

Future<DenseHandoffFile> _copyStableFile(
  File source,
  File destination, {
  required String fileName,
}) async {
  final sourcePath = source.absolute.path;
  final sourceType = await FileSystemEntity.type(
    sourcePath,
    followLinks: false,
  );
  if (sourceType == FileSystemEntityType.link) {
    throw FileSystemException(
      'frozen source must not be a symlink',
      sourcePath,
    );
  }
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file || before.size <= 0) {
    throw FileSystemException(
      'required non-empty frozen source is missing',
      sourcePath,
    );
  }
  final sourceDigest = (await sha256.bind(source.openRead()).first).toString();
  final temporary = File('${destination.absolute.path}.copying');
  await source.copy(temporary.path);
  try {
    final after = await source.stat();
    final sourceDigestAfter = (await sha256.bind(source.openRead()).first)
        .toString();
    final copiedDigest = (await sha256.bind(temporary.openRead()).first)
        .toString();
    final copiedStat = await temporary.stat();
    if (after.type != FileSystemEntityType.file ||
        after.size != before.size ||
        after.modified != before.modified ||
        sourceDigestAfter != sourceDigest ||
        copiedStat.type != FileSystemEntityType.file ||
        copiedStat.size != before.size ||
        copiedDigest != sourceDigest) {
      throw DenseHandoffException(
        DenseHandoffError.sourceChanged,
        'source changed while copying run snapshot: $sourcePath',
      );
    }
    await temporary.rename(destination.absolute.path);
    return DenseHandoffFile(
      path: destination.absolute.path,
      fileName: fileName,
      byteSize: before.size,
      sha256: sourceDigest,
    );
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<void> _materializeFrozenInputs(
  OfficialDenseNativeRequest request,
) async {
  for (final modelFile in request.modelFiles) {
    await _verifyFrozenFile(
      path: modelFile.path,
      expectedSize: modelFile.byteSize,
      expectedSha256: modelFile.sha256,
    );
  }
  await _verifyFrozenFile(
    path: request.fedFramesManifest.path,
    expectedSize: request.fedFramesManifest.byteSize,
    expectedSha256: request.fedFramesManifest.sha256,
  );

  final materializationDirectory = Directory(
    request.materializationDirectory,
  ).absolute;
  final materializationPrefix =
      '${materializationDirectory.path}${Platform.pathSeparator}';
  for (final entry in request.materializationPlan) {
    final sourcePath = File(entry.sourcePath).absolute.path;
    if (sourcePath == materializationDirectory.path ||
        sourcePath.startsWith(materializationPrefix)) {
      throw DenseHandoffException(
        DenseHandoffError.sourceChanged,
        'frozen source aliases materialization output: $sourcePath',
      );
    }
    final expectedDestination = File(
      _join(materializationDirectory.path, entry.imageName),
    ).absolute.path;
    if (File(entry.destinationPath).absolute.path != expectedDestination) {
      throw DenseHandoffException(
        DenseHandoffError.invalidRegisteredImages,
        'materialization destination escaped the frozen images directory',
      );
    }
  }

  try {
    await _createFreshDirectory(
      materializationDirectory.path,
      label: 'official dense materialization',
      containingDirectory: request.workspaceDirectory,
    );
    var ordinal = 0;
    for (final entry in request.materializationPlan) {
      await _verifyFrozenFile(
        path: entry.sourcePath,
        expectedSize: entry.byteSize,
        expectedSha256: entry.sha256,
      );
      final destination = File(entry.destinationPath).absolute;
      final temporary = File('${destination.path}.tmp.$pid.${ordinal++}');
      await File(entry.sourcePath).copy(temporary.path);
      try {
        await _verifyFrozenFile(
          path: temporary.path,
          expectedSize: entry.byteSize,
          expectedSha256: entry.sha256,
        );
        await temporary.rename(destination.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
  } catch (_) {
    // The enclosing native fd-anchored transaction removes the entire run.
    // Dart must not recursively clean this path after an ancestor swap.
    rethrow;
  }
}

Future<void> _verifyNativeRequestSnapshot(
  OfficialDenseNativeRequest request,
) async {
  for (final modelFile in request.modelFiles) {
    await _verifyFrozenFile(
      path: modelFile.path,
      expectedSize: modelFile.byteSize,
      expectedSha256: modelFile.sha256,
    );
  }
  await _verifyFrozenFile(
    path: request.fedFramesManifest.path,
    expectedSize: request.fedFramesManifest.byteSize,
    expectedSha256: request.fedFramesManifest.sha256,
  );
  for (final entry in request.materializationPlan) {
    await _verifyFrozenFile(
      path: entry.destinationPath,
      expectedSize: entry.byteSize,
      expectedSha256: entry.sha256,
    );
  }
}

Future<void> _verifyFrozenFile({
  required String path,
  required int expectedSize,
  required String expectedSha256,
}) async {
  final file = File(path).absolute;
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw DenseHandoffException(
      DenseHandoffError.sourceChanged,
      'frozen source became a symlink: ${file.path}',
    );
  }
  final before = await file.stat();
  if (before.type != FileSystemEntityType.file ||
      before.size != expectedSize ||
      before.size <= 0) {
    throw DenseHandoffException(
      DenseHandoffError.sourceChanged,
      'frozen source is missing or changed: ${file.path}',
    );
  }
  final digest = (await sha256.bind(file.openRead()).first).toString();
  final after = await file.stat();
  if (after.type != FileSystemEntityType.file ||
      after.size != before.size ||
      after.modified != before.modified ||
      digest != expectedSha256) {
    throw DenseHandoffException(
      DenseHandoffError.sourceChanged,
      'frozen source hash changed: ${file.path}',
    );
  }
}

Future<List<String>> _readRegisteredImageNames(File imagesBin) async {
  final stat = await imagesBin.stat();
  if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
    throw FormatException(
      'required non-empty COLMAP images.bin is missing: ${imagesBin.path}',
    );
  }
  final reader = await imagesBin.open();
  try {
    var position = 0;

    Future<Uint8List> readExact(int count) async {
      if (count < 0 || position + count > stat.size) {
        throw const FormatException('truncated COLMAP images.bin');
      }
      final bytes = await reader.read(count);
      if (bytes.length != count) {
        throw const FormatException('truncated COLMAP images.bin');
      }
      position += count;
      return Uint8List.fromList(bytes);
    }

    Future<int> readUint64() async {
      final bytes = await readExact(8);
      return ByteData.sublistView(bytes).getUint64(0, Endian.little);
    }

    final imageCount = await readUint64();
    if (imageCount <= 0 || imageCount > 10000000) {
      throw FormatException(
        'invalid COLMAP registered image count: $imageCount',
      );
    }

    final names = <String>[];
    for (var imageIndex = 0; imageIndex < imageCount; imageIndex++) {
      // image_id + qvec[4] + tvec[3] + camera_id.
      await readExact(64);
      final nameBytes = <int>[];
      while (true) {
        final byte = (await readExact(1)).single;
        if (byte == 0) break;
        nameBytes.add(byte);
        if (nameBytes.length > 1048576) {
          throw const FormatException('COLMAP image name is unreasonably long');
        }
      }
      final name = utf8.decode(nameBytes, allowMalformed: false);
      if (name.isEmpty) {
        throw const FormatException('COLMAP registered image name is empty');
      }
      names.add(name);

      final pointCount = await readUint64();
      if (pointCount > (stat.size - position) ~/ 24) {
        throw const FormatException('invalid COLMAP points2D count');
      }
      final nextPosition = position + pointCount * 24;
      await reader.setPosition(nextPosition);
      position = nextPosition;
    }
    if (position != stat.size) {
      throw const FormatException(
        'unexpected trailing bytes in COLMAP images.bin',
      );
    }
    return List<String>.unmodifiable(names);
  } finally {
    await reader.close();
  }
}

String _join(String directory, String child) {
  if (directory.endsWith(Platform.pathSeparator)) return '$directory$child';
  return '$directory${Platform.pathSeparator}$child';
}
