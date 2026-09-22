// Post-capture B/C/D execution boundary.
//
// The UI isolate sends data only. Every synchronous native call is created and
// executed inside a short-lived worker isolate, after capture has stopped.
// This file deliberately has no capture/UI imports and never deletes an image,
// gray payload, sidecar, or reconstruction artifact.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../detector_free_depth_ffi.dart';
import '../structural_planesweep_ffi.dart';
import 'bcd_detector_free_job_builder.dart';
import 'bcd_finalize_coordinator.dart';
import 'bcd_finalize_input_builder.dart';
import 'bcd_native_asset_reader.dart';
import 'bcd_product_finalize.dart';
import 'bcd_structural_quality_runner.dart';
import 'sfm_live_recon.dart';

enum BcdFinalizeWorkerStatus { completed, cancelled, failed }

/// Production options are reduced to scalar protocol data before spawning.
///
/// D intentionally has no Dart image-reader fallback. Only the frozen
/// [bcdNativeDetectorFreeAssetReaderFactoryId] is accepted; a null or different
/// identity becomes an explicit, ordered D failure after accepted B/C work.
class BcdFinalizeWorkerNativeOptions {
  const BcdFinalizeWorkerNativeOptions({
    required this.captureDigest,
    required this.backendAbi,
    this.detectorFreeRequested = true,
    this.nativeAssetReaderFactoryId,
  });

  final String captureDigest;
  final String backendAbi;
  final bool detectorFreeRequested;
  final String? nativeAssetReaderFactoryId;
}

/// One ordered, sendable statistic. Ordering is part of the worker protocol so
/// diagnostics never depend on map iteration order.
class BcdFinalizeWorkerStat {
  const BcdFinalizeWorkerStat(this.name, this.value);

  final String name;
  final Object? value;
}

class BcdFinalizeWorkerFailure {
  const BcdFinalizeWorkerFailure({required this.stage, required this.message});

  final String stage;
  final String message;
}

/// Data-only snapshot returned by the isolate.
///
/// New B/D points have no sparse-track observations, so [obsOffsets] is
/// extended with the previous terminal offset. The original observations are
/// untouched and the native point-index map is cleared because appended births
/// do not have native sparse indices.
class BcdFinalizeWorkerSnapshotData {
  BcdFinalizeWorkerSnapshotData({
    required Float32List xyz,
    required Uint8List rgb,
    required Float64List posesPacked,
    required Map<String, dynamic> summary,
    required this.refined,
    required Int32List obsOffsets,
    required Int32List obsFrameIds,
    required Float32List obsXY,
  }) : xyz = Float32List.fromList(xyz),
       rgb = Uint8List.fromList(rgb),
       posesPacked = Float64List.fromList(posesPacked),
       summary = Map<String, dynamic>.unmodifiable(summary),
       obsOffsets = Int32List.fromList(obsOffsets),
       obsFrameIds = Int32List.fromList(obsFrameIds),
       obsXY = Float32List.fromList(obsXY);

  final Float32List xyz;
  final Uint8List rgb;
  final Float64List posesPacked;
  final Map<String, dynamic> summary;
  final bool refined;
  final Int32List obsOffsets;
  final Int32List obsFrameIds;
  final Float32List obsXY;

  int get pointCount => xyz.length ~/ 3;

  SfmLiveSnapshot toSnapshot() => SfmLiveSnapshot(
    xyz: Float32List.fromList(xyz),
    rgb: Uint8List.fromList(rgb),
    posesPacked: Float64List.fromList(posesPacked),
    summary: Map<String, dynamic>.from(summary),
    refined: refined,
    obsOffsets: Int32List.fromList(obsOffsets),
    obsFrameIds: Int32List.fromList(obsFrameIds),
    obsXY: Float32List.fromList(obsXY),
    ghostSpatialKeepIdx: null,
  );
}

class BcdFinalizeWorkerResult {
  BcdFinalizeWorkerResult({
    required this.captureId,
    required this.status,
    required this.snapshot,
    required this.publication,
    required this.originalPointCount,
    required this.structuralBirthCount,
    required this.detectorFreeBirthCount,
    required List<BcdFinalizeWorkerStat> stats,
    required List<BcdFinalizeWorkerFailure> failures,
  }) : stats = List<BcdFinalizeWorkerStat>.unmodifiable(stats),
       failures = List<BcdFinalizeWorkerFailure>.unmodifiable(failures);

  final String captureId;
  final BcdFinalizeWorkerStatus status;
  final BcdFinalizeWorkerSnapshotData snapshot;
  final String publication;
  final int originalPointCount;
  final int structuralBirthCount;
  final int detectorFreeBirthCount;
  final List<BcdFinalizeWorkerStat> stats;
  final List<BcdFinalizeWorkerFailure> failures;

  BcdFinalizeWorkerStat? stat(String name) {
    for (final item in stats) {
      if (item.name == name) return item;
    }
    return null;
  }
}

/// Test-only data backend. It still executes in the real spawned isolate and
/// never transfers a runner or closure. This exercises the protocol, copying,
/// cancellation, and UI-isolate scheduling without loading native libraries.
class BcdFinalizeWorkerTestOptions {
  const BcdFinalizeWorkerTestOptions({
    this.busyFor = Duration.zero,
    this.structuralBirthXyz = const <double>[],
    this.structuralBirthRgb = const <int>[],
    this.detectorFreeBirthXyz = const <double>[],
    this.detectorFreeBirthRgb = const <int>[],
    this.structuralFailure,
    this.detectorFreeFailure,
    this.uncaughtFailure,
    this.nativeReaderProbe,
  });

  final Duration busyFor;
  final List<double> structuralBirthXyz;
  final List<int> structuralBirthRgb;
  final List<double> detectorFreeBirthXyz;
  final List<int> detectorFreeBirthRgb;
  final String? structuralFailure;
  final String? detectorFreeFailure;
  final String? uncaughtFailure;
  final BcdFinalizeWorkerNativeReaderProbe? nativeReaderProbe;
}

/// Test-only scalar description for proving that the exact production native
/// registry and path reader execute inside the spawned isolate.
class BcdFinalizeWorkerNativeReaderProbe {
  const BcdFinalizeWorkerNativeReaderProbe({
    required this.jpegPath,
    this.factoryId = bcdNativeDetectorFreeAssetReaderFactoryId,
    this.frameId = 1,
    this.imageWidth = 256,
    this.imageHeight = 144,
    this.grayWidth = 256,
    this.grayHeight = 144,
    this.grayFx = 200,
    this.grayFy = 180,
    this.grayCx = 128,
    this.grayCy = 72,
  });

  final String? factoryId;
  final String jpegPath;
  final int frameId;
  final int imageWidth;
  final int imageHeight;
  final int grayWidth;
  final int grayHeight;
  final double grayFx;
  final double grayFy;
  final double grayCx;
  final double grayCy;
}

/// Handle for one capture's short-lived worker. [cancel] kills blocking native
/// work immediately and completes [result] with an explicit cancelled state.
class BcdFinalizeWorkerTask {
  BcdFinalizeWorkerTask._({
    required this.captureId,
    required Map<String, Object?> payload,
    required Map<String, Object?> fallbackSnapshot,
    required void Function(String captureId, BcdFinalizeWorkerTask task)
    release,
  }) : _payload = payload,
       _fallbackSnapshot = fallbackSnapshot,
       _release = release;

  final String captureId;
  final Map<String, Object?> _payload;
  final Map<String, Object?> _fallbackSnapshot;
  final void Function(String captureId, BcdFinalizeWorkerTask task) _release;
  final Completer<BcdFinalizeWorkerResult> _completer = Completer();

  Isolate? _isolate;
  ReceivePort? _messages;
  ReceivePort? _errors;
  StreamSubscription<dynamic>? _messageSub;
  StreamSubscription<dynamic>? _errorSub;
  bool _cancelRequested = false;
  bool _released = false;

  Future<BcdFinalizeWorkerResult> get result => _completer.future;
  bool get isCompleted => _completer.isCompleted;

  void _launch() {
    unawaited(_spawn());
  }

  Future<void> _spawn() async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    _messages = messages;
    _errors = errors;
    _messageSub = messages.listen((message) {
      if (message is Map) {
        try {
          _finish(_decodeResult(Map<Object?, Object?>.from(message)));
        } catch (error) {
          _finish(
            _fallbackResult(
              status: BcdFinalizeWorkerStatus.failed,
              stage: 'decode_result',
              message: '$error',
            ),
          );
        }
      } else if (message == null && !_completer.isCompleted) {
        _finish(
          _fallbackResult(
            status: BcdFinalizeWorkerStatus.failed,
            stage: 'worker_exit',
            message: 'B/C/D isolate exited without a result',
          ),
        );
      }
    });
    _errorSub = errors.listen((message) {
      if (_completer.isCompleted) return;
      _finish(
        _fallbackResult(
          status: BcdFinalizeWorkerStatus.failed,
          stage: 'worker_isolate',
          message: _isolateErrorMessage(message),
        ),
      );
    });
    try {
      final isolate = await Isolate.spawn<List<Object?>>(
        _bcdFinalizeWorkerMain,
        <Object?>[messages.sendPort, _payload],
        debugName: 'bcd_finalize_$captureId',
        errorsAreFatal: true,
        onError: errors.sendPort,
        onExit: messages.sendPort,
      );
      _isolate = isolate;
      if (_cancelRequested) isolate.kill(priority: Isolate.immediate);
    } catch (error) {
      _finish(
        _fallbackResult(
          status: BcdFinalizeWorkerStatus.failed,
          stage: 'spawn',
          message: '$error',
        ),
      );
    }
  }

  Future<void> cancel([String reason = 'cancelled by caller']) async {
    if (_completer.isCompleted) return;
    _cancelRequested = true;
    _isolate?.kill(priority: Isolate.immediate);
    _finish(
      _fallbackResult(
        status: BcdFinalizeWorkerStatus.cancelled,
        stage: 'cancelled',
        message: reason,
      ),
    );
  }

  void _finish(BcdFinalizeWorkerResult value) {
    if (_completer.isCompleted) return;
    _completer.complete(value);
    _isolate?.kill(priority: Isolate.immediate);
    _dispose();
  }

  void _dispose() {
    if (_released) return;
    _released = true;
    _messages?.close();
    _errors?.close();
    unawaited(_messageSub?.cancel());
    unawaited(_errorSub?.cancel());
    _release(captureId, this);
  }

  BcdFinalizeWorkerResult _fallbackResult({
    required BcdFinalizeWorkerStatus status,
    required String stage,
    required String message,
  }) {
    final snapshot = _decodeSnapshot(_fallbackSnapshot);
    return BcdFinalizeWorkerResult(
      captureId: captureId,
      status: status,
      snapshot: snapshot,
      publication: 'sparseOnly',
      originalPointCount: snapshot.pointCount,
      structuralBirthCount: 0,
      detectorFreeBirthCount: 0,
      stats: <BcdFinalizeWorkerStat>[
        BcdFinalizeWorkerStat('input_frames', _payloadFrameCount(_payload)),
        BcdFinalizeWorkerStat('original_points', snapshot.pointCount),
        const BcdFinalizeWorkerStat('structural_births', 0),
        const BcdFinalizeWorkerStat('detector_free_births', 0),
        BcdFinalizeWorkerStat('output_points', snapshot.pointCount),
      ],
      failures: <BcdFinalizeWorkerFailure>[
        BcdFinalizeWorkerFailure(stage: stage, message: message),
      ],
    );
  }
}

class BcdFinalizeWorker {
  BcdFinalizeWorker._();

  static final Map<String, BcdFinalizeWorkerTask> _active = {};

  static bool isActive(String captureId) => _active.containsKey(captureId);

  static BcdFinalizeWorkerTask start({
    required String captureId,
    required SfmLiveSnapshot snapshot,
    required List<SfmDurableFedFrameInput> durableFedFrames,
    BcdKnownFloorPlane? metricKnownFloorPlane,
    required BcdFinalizeWorkerNativeOptions options,
  }) => _start(
    captureId: captureId,
    snapshot: snapshot,
    durableFedFrames: durableFedFrames,
    metricKnownFloorPlane: metricKnownFloorPlane,
    mode: 'production',
    options: <String, Object?>{
      'captureDigest': options.captureDigest,
      'backendAbi': options.backendAbi,
      'detectorFreeRequested': options.detectorFreeRequested,
      'nativeAssetReaderFactoryId': options.nativeAssetReaderFactoryId,
    },
  );

  static BcdFinalizeWorkerTask startForTesting({
    required String captureId,
    required SfmLiveSnapshot snapshot,
    required List<SfmDurableFedFrameInput> durableFedFrames,
    BcdKnownFloorPlane? metricKnownFloorPlane,
    BcdFinalizeWorkerTestOptions options = const BcdFinalizeWorkerTestOptions(),
  }) => _start(
    captureId: captureId,
    snapshot: snapshot,
    durableFedFrames: durableFedFrames,
    metricKnownFloorPlane: metricKnownFloorPlane,
    mode: 'test',
    options: <String, Object?>{
      'busyMicros': options.busyFor.inMicroseconds,
      'structuralBirthXyz': Float32List.fromList(options.structuralBirthXyz),
      'structuralBirthRgb': Uint8List.fromList(options.structuralBirthRgb),
      'detectorFreeBirthXyz': Float32List.fromList(
        options.detectorFreeBirthXyz,
      ),
      'detectorFreeBirthRgb': Uint8List.fromList(options.detectorFreeBirthRgb),
      'structuralFailure': options.structuralFailure,
      'detectorFreeFailure': options.detectorFreeFailure,
      'uncaughtFailure': options.uncaughtFailure,
      'nativeReaderProbe': options.nativeReaderProbe == null
          ? null
          : <String, Object?>{
              'factoryId': options.nativeReaderProbe!.factoryId,
              'jpegPath': options.nativeReaderProbe!.jpegPath,
              'frameId': options.nativeReaderProbe!.frameId,
              'imageWidth': options.nativeReaderProbe!.imageWidth,
              'imageHeight': options.nativeReaderProbe!.imageHeight,
              'grayWidth': options.nativeReaderProbe!.grayWidth,
              'grayHeight': options.nativeReaderProbe!.grayHeight,
              'grayFx': options.nativeReaderProbe!.grayFx,
              'grayFy': options.nativeReaderProbe!.grayFy,
              'grayCx': options.nativeReaderProbe!.grayCx,
              'grayCy': options.nativeReaderProbe!.grayCy,
            },
    },
  );

  static BcdFinalizeWorkerTask _start({
    required String captureId,
    required SfmLiveSnapshot snapshot,
    required List<SfmDurableFedFrameInput> durableFedFrames,
    required BcdKnownFloorPlane? metricKnownFloorPlane,
    required String mode,
    required Map<String, Object?> options,
  }) {
    final id = captureId.trim();
    if (id.isEmpty) throw ArgumentError.value(captureId, 'captureId');
    if (_active.containsKey(id)) {
      throw StateError('B/C/D worker already active for capture $id');
    }
    final snapshotPayload = _encodeSnapshot(snapshot);
    final payload = <String, Object?>{
      'protocolVersion': 1,
      'captureId': id,
      'mode': mode,
      'snapshot': snapshotPayload,
      'durableFrames': <Object?>[
        for (final frame in durableFedFrames) _encodeDurableFrame(frame),
      ],
      'knownFloor': metricKnownFloorPlane == null
          ? null
          : <String, Object?>{
              'normal': List<double>.of(metricKnownFloorPlane.normal),
              'planeValue': metricKnownFloorPlane.planeValue,
            },
      'options': options,
    };
    late BcdFinalizeWorkerTask task;
    task = BcdFinalizeWorkerTask._(
      captureId: id,
      payload: payload,
      fallbackSnapshot: snapshotPayload,
      release: (captureId, completed) {
        if (identical(_active[captureId], completed)) {
          _active.remove(captureId);
        }
      },
    );
    _active[id] = task;
    task._launch();
    return task;
  }
}

void _bcdFinalizeWorkerMain(List<Object?> bootstrap) {
  final reply = bootstrap[0] as SendPort;
  final payload = Map<Object?, Object?>.from(bootstrap[1]! as Map);
  try {
    final result = payload['mode'] == 'test'
        ? _runTestWorker(payload)
        : _runProductionWorker(payload);
    reply.send(result);
  } catch (error, stack) {
    final snapshotPayload = Map<String, Object?>.from(
      payload['snapshot']! as Map,
    );
    final snapshot = _decodeSnapshot(snapshotPayload);
    reply.send(
      _encodeWorkerResult(
        captureId: payload['captureId']! as String,
        status: BcdFinalizeWorkerStatus.failed,
        snapshot: snapshot,
        publication: 'sparseOnly',
        originalPointCount: snapshot.pointCount,
        structuralBirthCount: 0,
        detectorFreeBirthCount: 0,
        stats: <BcdFinalizeWorkerStat>[
          BcdFinalizeWorkerStat('input_frames', _payloadFrameCount(payload)),
          BcdFinalizeWorkerStat('original_points', snapshot.pointCount),
          const BcdFinalizeWorkerStat('structural_births', 0),
          const BcdFinalizeWorkerStat('detector_free_births', 0),
          BcdFinalizeWorkerStat('output_points', snapshot.pointCount),
        ],
        failures: <BcdFinalizeWorkerFailure>[
          BcdFinalizeWorkerFailure(
            stage: 'worker_exception',
            message: '$error\n$stack',
          ),
        ],
      ),
    );
  }
}

Map<String, Object?> _runProductionWorker(Map<Object?, Object?> payload) {
  final stopwatch = Stopwatch()..start();
  final captureId = payload['captureId']! as String;
  final snapshot = _decodeSnapshot(
    Map<String, Object?>.from(payload['snapshot']! as Map),
  ).toSnapshot();
  final durables = _decodeDurableFrames(payload['durableFrames']);
  final knownFloor = _decodeKnownFloor(payload['knownFloor']);
  final options = Map<Object?, Object?>.from(payload['options']! as Map);

  final product = const BcdProductFinalize();
  BcdProductDetectorFreeFullScenePlanFactory? dFactory;
  if (options['detectorFreeRequested'] == true) {
    dFactory = _StrictNativeAssetPlanFactory(
      captureDigest: options['captureDigest']! as String,
      backendAbi: options['backendAbi']! as String,
      factoryId: options['nativeAssetReaderFactoryId'] as String?,
    );
  }
  final finalized = product.run(
    snapshot: snapshot,
    durableFedFrames: durables,
    metricKnownFloorPlane: knownFloor,
    detectorFreePlanFactory: dFactory,
  );
  stopwatch.stop();
  final outputSnapshot = _snapshotWithCloud(
    source: snapshot,
    xyz: finalized.xyz,
    rgb: finalized.rgb,
  );
  final failures = <BcdFinalizeWorkerFailure>[
    if (finalized.structuralFailure case final failure?)
      BcdFinalizeWorkerFailure(stage: 'structural', message: failure),
    if (finalized.detectorFreeFailure case final failure?)
      BcdFinalizeWorkerFailure(stage: 'detector_free', message: failure),
  ];
  final d = finalized.detectorFreeExecution;
  final stats = <BcdFinalizeWorkerStat>[
    BcdFinalizeWorkerStat('input_frames', durables.length),
    BcdFinalizeWorkerStat('registered_frames', snapshot.registeredCount),
    BcdFinalizeWorkerStat(
      'original_points',
      finalized.finalize.originalPointCount,
    ),
    BcdFinalizeWorkerStat(
      'structural_births',
      finalized.finalize.structuralBirthCount,
    ),
    BcdFinalizeWorkerStat(
      'detector_free_births',
      finalized.finalize.detectorFreeBirthCount,
    ),
    BcdFinalizeWorkerStat('output_points', finalized.xyz.length ~/ 3),
    BcdFinalizeWorkerStat('elapsed_us', stopwatch.elapsedMicroseconds),
    BcdFinalizeWorkerStat('d_certified_references', d?.certifiedReferenceCount),
    BcdFinalizeWorkerStat('d_blocked_references', d?.blockedReferenceCount),
    BcdFinalizeWorkerStat('d_skipped_references', d?.skippedReferenceCount),
    BcdFinalizeWorkerStat('d_cache_hits', d?.cacheStats.hits),
    BcdFinalizeWorkerStat('d_cache_misses', d?.cacheStats.misses),
    BcdFinalizeWorkerStat('d_cache_peak_bytes', d?.cacheStats.peakBytes),
  ];
  return _encodeWorkerResult(
    captureId: captureId,
    status: BcdFinalizeWorkerStatus.completed,
    snapshot: outputSnapshot,
    publication: finalized.publication.name,
    originalPointCount: finalized.finalize.originalPointCount,
    structuralBirthCount: finalized.finalize.structuralBirthCount,
    detectorFreeBirthCount: finalized.finalize.detectorFreeBirthCount,
    stats: stats,
    failures: failures,
  );
}

/// Strict production registry. The exact frozen native-reader identity builds
/// the product full-scene plan; null, unknown, Dart, and experimental IDs throw
/// here (after B/C was accepted, so [BcdProductFinalize] retains B/C).
class _StrictNativeAssetPlanFactory
    implements BcdProductDetectorFreeFullScenePlanFactory {
  const _StrictNativeAssetPlanFactory({
    required this.captureDigest,
    required this.backendAbi,
    required this.factoryId,
  });

  final String captureDigest;
  final String backendAbi;
  final String? factoryId;

  @override
  BcdProductDetectorFreeFullScenePlan? build({
    required BcdFinalizeInputBundle inputs,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
  }) {
    _requireNativeAssetReaderFactoryId(factoryId);
    return NativeBcdProductDetectorFreeFullScenePlanFactory(
      captureDigest: captureDigest,
      backendAbi: backendAbi,
    ).build(
      inputs: inputs,
      selectedFloor: selectedFloor,
      certifiedWalls: certifiedWalls,
    );
  }
}

BcdDetectorFreeAssetReader _nativeAssetReaderFromStrictRegistry(String? rawId) {
  _requireNativeAssetReaderFactoryId(rawId);
  return const BcdNativeDetectorFreeAssetReader.path();
}

void _requireNativeAssetReaderFactoryId(String? rawId) {
  final id = rawId?.trim();
  if (id == bcdNativeDetectorFreeAssetReaderFactoryId) {
    return;
  }
  throw UnsupportedError(
    'native D solve-asset reader factory '
    '${id == null || id.isEmpty ? "is not installed" : "$id is not registered"}; '
    'expected=$bcdNativeDetectorFreeAssetReaderFactoryId; '
    'Dart/experimental asset readers disabled',
  );
}

Map<String, Object?> _runTestWorker(Map<Object?, Object?> payload) {
  final stopwatch = Stopwatch()..start();
  final captureId = payload['captureId']! as String;
  final source = _decodeSnapshot(
    Map<String, Object?>.from(payload['snapshot']! as Map),
  );
  final options = Map<Object?, Object?>.from(payload['options']! as Map);
  final busyMicros = options['busyMicros']! as int;
  if (busyMicros > 0) {
    final spin = Stopwatch()..start();
    while (spin.elapsedMicroseconds < busyMicros) {
      // Deliberate test-only CPU work proves the caller event loop is free.
    }
  }
  final uncaught = options['uncaughtFailure'] as String?;
  if (uncaught != null) throw StateError(uncaught);

  final structuralFailure = options['structuralFailure'] as String?;
  final detectorFailure = options['detectorFreeFailure'] as String?;
  final nativeReaderProbe = options['nativeReaderProbe'];
  BcdDetectorFreeSolveAsset? probeAsset;
  if (nativeReaderProbe != null) {
    final probe = Map<Object?, Object?>.from(nativeReaderProbe as Map);
    final reader = _nativeAssetReaderFromStrictRegistry(
      probe['factoryId'] as String?,
    );
    probeAsset = reader.readSolveAsset(
      BcdFinalizeRegisteredFrameInput(
        cameraFrame: BcdRegisteredCameraFrame(
          frameId: probe['frameId']! as int,
          jpegPath: probe['jpegPath']! as String,
          imageWidth: probe['imageWidth']! as int,
          imageHeight: probe['imageHeight']! as int,
          grayWidth: probe['grayWidth']! as int,
          grayHeight: probe['grayHeight']! as int,
          grayFx: probe['grayFx']! as double,
          grayFy: probe['grayFy']! as double,
          grayCx: probe['grayCx']! as double,
          grayCy: probe['grayCy']! as double,
          cameraFromWorldQuaternionWxyz: const <double>[1, 0, 0, 0],
          cameraFromWorldTranslation: const <double>[0, 0, 0],
        ),
        grayPath: '/native-reader-probe-must-not-use-gray',
      ),
      width: detectorFreeImageWidth,
      height: detectorFreeImageHeight,
    );
    if (probeAsset == null) {
      throw StateError('native D path reader rejected worker probe JPEG');
    }
  }
  final structuralXyz = Float32List.fromList(
    options['structuralBirthXyz']! as Float32List,
  );
  final structuralRgb = Uint8List.fromList(
    options['structuralBirthRgb']! as Uint8List,
  );
  final detectorXyz = Float32List.fromList(
    options['detectorFreeBirthXyz']! as Float32List,
  );
  final detectorRgb = Uint8List.fromList(
    options['detectorFreeBirthRgb']! as Uint8List,
  );
  _validateCloudPair(structuralXyz, structuralRgb, 'test structural birth');
  _validateCloudPair(detectorXyz, detectorRgb, 'test detector-free birth');

  final acceptedStructuralXyz = structuralFailure == null
      ? structuralXyz
      : Float32List(0);
  final acceptedStructuralRgb = structuralFailure == null
      ? structuralRgb
      : Uint8List(0);
  final acceptedDetectorXyz =
      structuralFailure == null && detectorFailure == null
      ? detectorXyz
      : Float32List(0);
  final acceptedDetectorRgb =
      structuralFailure == null && detectorFailure == null
      ? detectorRgb
      : Uint8List(0);
  final xyz = _appendFloat32(<Float32List>[
    source.xyz,
    acceptedStructuralXyz,
    acceptedDetectorXyz,
  ]);
  final rgb = _appendUint8(<Uint8List>[
    source.rgb,
    acceptedStructuralRgb,
    acceptedDetectorRgb,
  ]);
  final output = _copySnapshotWithCloud(source: source, xyz: xyz, rgb: rgb);
  stopwatch.stop();
  final structuralCount = acceptedStructuralXyz.length ~/ 3;
  final detectorCount = acceptedDetectorXyz.length ~/ 3;
  return _encodeWorkerResult(
    captureId: captureId,
    status: BcdFinalizeWorkerStatus.completed,
    snapshot: output,
    publication: structuralCount == 0
        ? 'sparseOnly'
        : detectorCount == 0
        ? 'structural'
        : 'structuralAndDetectorFree',
    originalPointCount: source.pointCount,
    structuralBirthCount: structuralCount,
    detectorFreeBirthCount: detectorCount,
    stats: <BcdFinalizeWorkerStat>[
      BcdFinalizeWorkerStat('input_frames', _payloadFrameCount(payload)),
      BcdFinalizeWorkerStat('original_points', source.pointCount),
      BcdFinalizeWorkerStat('structural_births', structuralCount),
      BcdFinalizeWorkerStat('detector_free_births', detectorCount),
      BcdFinalizeWorkerStat('output_points', output.pointCount),
      BcdFinalizeWorkerStat('elapsed_us', stopwatch.elapsedMicroseconds),
      if (nativeReaderProbe != null) ...<BcdFinalizeWorkerStat>[
        const BcdFinalizeWorkerStat(
          'native_asset_reader_factory',
          bcdNativeDetectorFreeAssetReaderFactoryId,
        ),
        BcdFinalizeWorkerStat('native_asset_rgb_digest', probeAsset!.rgbDigest),
        BcdFinalizeWorkerStat(
          'native_asset_gray_digest',
          probeAsset.grayDigest,
        ),
      ],
    ],
    failures: <BcdFinalizeWorkerFailure>[
      if (structuralFailure != null)
        BcdFinalizeWorkerFailure(
          stage: 'structural',
          message: structuralFailure,
        ),
      if (structuralFailure == null && detectorFailure != null)
        BcdFinalizeWorkerFailure(
          stage: 'detector_free',
          message: detectorFailure,
        ),
    ],
  );
}

Map<String, Object?> _encodeSnapshot(SfmLiveSnapshot snapshot) {
  _validateSnapshotArrays(
    xyz: snapshot.xyz,
    rgb: snapshot.rgb,
    posesPacked: snapshot.posesPacked,
    obsOffsets: snapshot.obsOffsets,
    obsFrameIds: snapshot.obsFrameIds,
    obsXY: snapshot.obsXY,
  );
  return <String, Object?>{
    'xyz': Float32List.fromList(snapshot.xyz),
    'rgb': Uint8List.fromList(snapshot.rgb),
    'posesPacked': Float64List.fromList(snapshot.posesPacked),
    'summary': _copySendableStringMap(snapshot.summary),
    'refined': snapshot.refined,
    'obsOffsets': Int32List.fromList(snapshot.obsOffsets),
    'obsFrameIds': Int32List.fromList(snapshot.obsFrameIds),
    'obsXY': Float32List.fromList(snapshot.obsXY),
  };
}

Map<String, Object?> _encodeDurableFrame(SfmDurableFedFrameInput input) {
  final meta = input.meta;
  return <String, Object?>{
    'sequence': input.sequence,
    'frameId': input.frameId,
    'grayPath': input.grayPath,
    'jpegPath': meta.jpegPath,
    'imageW': meta.imageW,
    'imageH': meta.imageH,
    'grayW': meta.grayW,
    'grayH': meta.grayH,
    'fx': meta.fx,
    'fy': meta.fy,
    'cx': meta.cx,
    'cy': meta.cy,
    'arkitQuatWxyz': meta.arkitQuatWxyz == null
        ? null
        : List<double>.of(meta.arkitQuatWxyz!),
    'arkitTransTxyz': meta.arkitTransTxyz == null
        ? null
        : List<double>.of(meta.arkitTransTxyz!),
    'arkitCameraCenterWorld': meta.arkitCameraCenterWorld == null
        ? null
        : List<double>.of(meta.arkitCameraCenterWorld!),
  };
}

List<SfmDurableFedFrameInput> _decodeDurableFrames(Object? raw) {
  final rows = raw! as List;
  return List<SfmDurableFedFrameInput>.unmodifiable(<SfmDurableFedFrameInput>[
    for (final row in rows)
      _decodeDurableFrame(Map<Object?, Object?>.from(row! as Map)),
  ]);
}

SfmDurableFedFrameInput _decodeDurableFrame(Map<Object?, Object?> row) {
  return SfmDurableFedFrameInput(
    sequence: row['sequence']! as int,
    frameId: row['frameId']! as int,
    grayPath: row['grayPath']! as String,
    meta: SfmFedFrameMeta(
      jpegPath: row['jpegPath']! as String,
      imageW: row['imageW']! as int,
      imageH: row['imageH']! as int,
      grayW: row['grayW']! as int,
      grayH: row['grayH']! as int,
      fx: row['fx']! as double,
      fy: row['fy']! as double,
      cx: row['cx']! as double,
      cy: row['cy']! as double,
      arkitQuatWxyz: _nullableDoubleList(row['arkitQuatWxyz']),
      arkitTransTxyz: _nullableDoubleList(row['arkitTransTxyz']),
      arkitCameraCenterWorld: _nullableDoubleList(
        row['arkitCameraCenterWorld'],
      ),
    ),
  );
}

BcdKnownFloorPlane? _decodeKnownFloor(Object? raw) {
  if (raw == null) return null;
  final map = Map<Object?, Object?>.from(raw as Map);
  return BcdKnownFloorPlane(
    normal: List<double>.from(map['normal']! as List),
    planeValue: map['planeValue']! as double,
  );
}

BcdFinalizeWorkerSnapshotData _decodeSnapshot(Map<String, Object?> payload) {
  return BcdFinalizeWorkerSnapshotData(
    xyz: Float32List.fromList(payload['xyz']! as Float32List),
    rgb: Uint8List.fromList(payload['rgb']! as Uint8List),
    posesPacked: Float64List.fromList(payload['posesPacked']! as Float64List),
    summary: Map<String, dynamic>.from(payload['summary']! as Map),
    refined: payload['refined']! as bool,
    obsOffsets: Int32List.fromList(payload['obsOffsets']! as Int32List),
    obsFrameIds: Int32List.fromList(payload['obsFrameIds']! as Int32List),
    obsXY: Float32List.fromList(payload['obsXY']! as Float32List),
  );
}

BcdFinalizeWorkerSnapshotData _snapshotWithCloud({
  required SfmLiveSnapshot source,
  required Float32List xyz,
  required Uint8List rgb,
}) => _copySnapshotWithCloud(
  source: BcdFinalizeWorkerSnapshotData(
    xyz: source.xyz,
    rgb: source.rgb,
    posesPacked: source.posesPacked,
    summary: source.summary,
    refined: source.refined,
    obsOffsets: source.obsOffsets,
    obsFrameIds: source.obsFrameIds,
    obsXY: source.obsXY,
  ),
  xyz: xyz,
  rgb: rgb,
);

BcdFinalizeWorkerSnapshotData _copySnapshotWithCloud({
  required BcdFinalizeWorkerSnapshotData source,
  required Float32List xyz,
  required Uint8List rgb,
}) {
  _validateCloudPair(xyz, rgb, 'worker output');
  if (xyz.length < source.xyz.length ||
      !_floatPrefixExact(xyz, source.xyz) ||
      !_bytePrefixExact(rgb, source.rgb)) {
    throw StateError('B/C/D worker changed the original sparse byte prefix');
  }
  final outputPoints = xyz.length ~/ 3;
  final terminalOffset = source.obsOffsets.last;
  final offsets = Int32List(outputPoints + 1);
  offsets.setRange(0, source.obsOffsets.length, source.obsOffsets);
  for (var index = source.obsOffsets.length; index < offsets.length; index++) {
    offsets[index] = terminalOffset;
  }
  return BcdFinalizeWorkerSnapshotData(
    xyz: xyz,
    rgb: rgb,
    posesPacked: source.posesPacked,
    summary: source.summary,
    refined: source.refined,
    obsOffsets: offsets,
    obsFrameIds: source.obsFrameIds,
    obsXY: source.obsXY,
  );
}

Map<String, Object?> _encodeWorkerResult({
  required String captureId,
  required BcdFinalizeWorkerStatus status,
  required BcdFinalizeWorkerSnapshotData snapshot,
  required String publication,
  required int originalPointCount,
  required int structuralBirthCount,
  required int detectorFreeBirthCount,
  required List<BcdFinalizeWorkerStat> stats,
  required List<BcdFinalizeWorkerFailure> failures,
}) => <String, Object?>{
  'captureId': captureId,
  'status': status.name,
  'snapshot': <String, Object?>{
    'xyz': Float32List.fromList(snapshot.xyz),
    'rgb': Uint8List.fromList(snapshot.rgb),
    'posesPacked': Float64List.fromList(snapshot.posesPacked),
    'summary': _copySendableStringMap(snapshot.summary),
    'refined': snapshot.refined,
    'obsOffsets': Int32List.fromList(snapshot.obsOffsets),
    'obsFrameIds': Int32List.fromList(snapshot.obsFrameIds),
    'obsXY': Float32List.fromList(snapshot.obsXY),
  },
  'publication': publication,
  'originalPointCount': originalPointCount,
  'structuralBirthCount': structuralBirthCount,
  'detectorFreeBirthCount': detectorFreeBirthCount,
  'stats': <Object?>[
    for (final item in stats)
      <String, Object?>{'name': item.name, 'value': item.value},
  ],
  'failures': <Object?>[
    for (final item in failures)
      <String, Object?>{'stage': item.stage, 'message': item.message},
  ],
};

BcdFinalizeWorkerResult _decodeResult(Map<Object?, Object?> payload) {
  return BcdFinalizeWorkerResult(
    captureId: payload['captureId']! as String,
    status: BcdFinalizeWorkerStatus.values.byName(payload['status']! as String),
    snapshot: _decodeSnapshot(
      Map<String, Object?>.from(payload['snapshot']! as Map),
    ),
    publication: payload['publication']! as String,
    originalPointCount: payload['originalPointCount']! as int,
    structuralBirthCount: payload['structuralBirthCount']! as int,
    detectorFreeBirthCount: payload['detectorFreeBirthCount']! as int,
    stats: <BcdFinalizeWorkerStat>[
      for (final raw in payload['stats']! as List)
        BcdFinalizeWorkerStat((raw! as Map)['name']! as String, raw['value']),
    ],
    failures: <BcdFinalizeWorkerFailure>[
      for (final raw in payload['failures']! as List)
        BcdFinalizeWorkerFailure(
          stage: (raw! as Map)['stage']! as String,
          message: raw['message']! as String,
        ),
    ],
  );
}

void _validateSnapshotArrays({
  required Float32List xyz,
  required Uint8List rgb,
  required Float64List posesPacked,
  required Int32List obsOffsets,
  required Int32List obsFrameIds,
  required Float32List obsXY,
}) {
  _validateCloudPair(xyz, rgb, 'worker input sparse');
  final points = xyz.length ~/ 3;
  if (posesPacked.length % 9 != 0 ||
      posesPacked.any((value) => !value.isFinite) ||
      obsOffsets.length != points + 1 ||
      obsOffsets.isEmpty ||
      obsOffsets.first != 0 ||
      obsOffsets.last != obsFrameIds.length ||
      obsXY.length != obsFrameIds.length * 2) {
    throw ArgumentError('B/C/D worker snapshot arrays are malformed');
  }
  for (var index = 1; index < obsOffsets.length; index++) {
    if (obsOffsets[index] < obsOffsets[index - 1]) {
      throw ArgumentError('B/C/D worker observation offsets are not ordered');
    }
  }
}

void _validateCloudPair(Float32List xyz, Uint8List rgb, String label) {
  if (xyz.length % 3 != 0 ||
      rgb.length != xyz.length ||
      xyz.any((value) => !value.isFinite)) {
    throw ArgumentError('$label XYZ/RGB is malformed or non-finite');
  }
}

Map<String, dynamic> _copySendableStringMap(Map<String, dynamic> source) {
  final output = <String, dynamic>{};
  for (final entry in source.entries) {
    output[entry.key] = _copySendable(entry.value);
  }
  return output;
}

Object? _copySendable(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is Uint8List) return Uint8List.fromList(value);
  if (value is Int32List) return Int32List.fromList(value);
  if (value is Float32List) return Float32List.fromList(value);
  if (value is Float64List) return Float64List.fromList(value);
  if (value is List) {
    return <Object?>[for (final item in value) _copySendable(item)];
  }
  if (value is Map) {
    final output = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw ArgumentError('snapshot summary map keys must be strings');
      }
      output[entry.key! as String] = _copySendable(entry.value);
    }
    return output;
  }
  throw ArgumentError(
    'snapshot summary contains unsendable ${value.runtimeType}',
  );
}

List<double>? _nullableDoubleList(Object? value) =>
    value == null ? null : List<double>.from(value as List);

Float32List _appendFloat32(List<Float32List> parts) {
  final length = parts.fold<int>(0, (sum, item) => sum + item.length);
  final output = Float32List(length);
  var offset = 0;
  for (final part in parts) {
    output.setAll(offset, part);
    offset += part.length;
  }
  return output;
}

Uint8List _appendUint8(List<Uint8List> parts) {
  final length = parts.fold<int>(0, (sum, item) => sum + item.length);
  final output = Uint8List(length);
  var offset = 0;
  for (final part in parts) {
    output.setAll(offset, part);
    offset += part.length;
  }
  return output;
}

bool _floatPrefixExact(Float32List full, Float32List prefix) =>
    _bytePrefixExact(
      full.buffer.asUint8List(full.offsetInBytes, full.lengthInBytes),
      prefix.buffer.asUint8List(prefix.offsetInBytes, prefix.lengthInBytes),
    );

bool _bytePrefixExact(Uint8List full, Uint8List prefix) {
  if (full.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (full[index] != prefix[index]) return false;
  }
  return true;
}

int _payloadFrameCount(Map<Object?, Object?> payload) =>
    (payload['durableFrames']! as List).length;

String _isolateErrorMessage(Object? message) {
  if (message is List && message.isNotEmpty) {
    return message.map((item) => '$item').join('\n');
  }
  return '$message';
}
