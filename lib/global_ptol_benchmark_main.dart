import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'official_aether_sfm_ffi.dart';
import 'official_capture/database_archive_manifest.dart';
import 'official_capture/database_archive_policy.dart';
import 'official_capture/database_archive_resolver.dart';
import 'official_capture/global_ptol_benchmark_gate.dart';
import 'official_capture/photo_archive_runtime.dart';
import 'official_capture/sfm_live_recon.dart';
import 'official_capture/sparse_ply.dart';

const _bundleId = 'com.kyle.PocketWorld.PtolBench';
const _resultFileName = 'global_ptol_benchmark_result.json';
const _runId = String.fromEnvironment(
  'PW_GLOBAL_PTOL_RUN_ID',
  defaultValue: 'manual',
);
const _globalPtolEnvironmentName = 'OFFICIAL_AETHER_GLOBAL_PTOL';
const _poseSidecarName = 'official_sfm_live.db.arkit_pose_v1';
const _fedFramesName = 'official_sfm_fed_frames.jsonl';
const _sparsePlyName = 'official_sfm_sparse.ply';
const _sparseMetaName = 'official_sfm_sparse_meta.json';
const _finalizeSegmentsName = 'official_finalize_segments.json';
const _knownLimitation =
    'Ceres final cost is not exposed by the registered native framework; '
    'summary reprojection alone does not establish numerical equivalence. '
    'This frozen-database phone replay exercises production global BA and '
    'final PLY generation, but not capture-time ARKit ingestion or the Metal '
    'feature/matcher path; it cannot approve a production value.';

const _armSpecs = <GlobalPtolArmSpec>[
  GlobalPtolArmSpec(label: 'A1', ptol: '0'),
  GlobalPtolArmSpec(label: 'B1', ptol: '1e-8'),
  GlobalPtolArmSpec(label: 'A2', ptol: '0'),
  GlobalPtolArmSpec(label: 'B2', ptol: '1e-8'),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _GlobalPtolBenchmarkApp());
}

class _GlobalPtolBenchmarkApp extends StatefulWidget {
  const _GlobalPtolBenchmarkApp();

  @override
  State<_GlobalPtolBenchmarkApp> createState() =>
      _GlobalPtolBenchmarkAppState();
}

class _GlobalPtolBenchmarkAppState extends State<_GlobalPtolBenchmarkApp> {
  String _status = 'Starting isolated global PTOL A/B/A/B benchmark…';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final result = await runGlobalPtolBenchmark(
        onStatus: (status) {
          if (mounted) setState(() => _status = status);
        },
      );
      if (mounted) {
        setState(() => _status = 'Result: ${result['status']}');
      }
    } catch (error) {
      if (mounted) setState(() => _status = 'FAIL: $error');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xff0b1118),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<Map<String, Object?>> runGlobalPtolBenchmark({
  void Function(String status)? onStatus,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final resultFile = File('${documents.path}/$_resultFileName');
  final result = <String, Object?>{
    'schema': 'pw_global_ptol_phone_ab_result_v1',
    'run_id': _runId,
    'bundle_id': _bundleId,
    'status': 'running',
    'stage': 'starting',
    'experiment_class': 'diagnostic_mechanical_screen',
    'pose_source': 'frozen_production_arkit_sidecar',
    'excluded_shadow_pose_source': 'xrslam_vio',
    'production_eligible': false,
    'known_limitation': _knownLimitation,
    'arms': <Object?>[],
  };

  Future<void> flush(String stage) async {
    result['stage'] = stage;
    result['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await _writeJsonAtomic(resultFile, result);
  }

  try {
    await flush('starting');
    _validateRunId(_runId);
    final inputDirectory = Directory('${documents.path}/benchmark_input');
    final archive = File(
      '${inputDirectory.path}/${DatabaseArchiveManifest.archiveFileName}',
    );
    final archiveManifest = File(
      '${inputDirectory.path}/${DatabaseArchiveManifest.fileName}',
    );
    final poseSidecar = File('${inputDirectory.path}/$_poseSidecarName');
    final fedFrames = File('${inputDirectory.path}/$_fedFramesName');
    final archivePolicy = File(
      '${inputDirectory.path}/${DatabaseArchivePolicy.fileName}',
    );

    onStatus?.call('Verifying frozen benchmark inputs…');
    final archiveIdentity = await _verifyFile(
      archive,
      expectedBytes: expectedGlobalPtolArchiveBytes,
      expectedSha256: expectedGlobalPtolArchiveSha256,
    );
    final archiveManifestIdentity = await _verifyFile(
      archiveManifest,
      expectedBytes: expectedGlobalPtolArchiveManifestBytes,
      expectedSha256: expectedGlobalPtolArchiveManifestSha256,
    );
    final poseIdentity = await _verifyFile(
      poseSidecar,
      expectedBytes: expectedGlobalPtolPoseBytes,
      expectedSha256: expectedGlobalPtolPoseSha256,
    );
    final fedFramesIdentity = await _verifyFile(
      fedFrames,
      expectedBytes: expectedGlobalPtolFedFramesBytes,
      expectedSha256: expectedGlobalPtolFedFramesSha256,
    );
    final archivePolicyIdentity = await _verifyFile(
      archivePolicy,
      expectedBytes: expectedGlobalPtolArchivePolicyBytes,
      expectedSha256: expectedGlobalPtolArchivePolicySha256,
    );

    result['input_identity'] = <String, Object?>{
      'source_directory': 'Documents/benchmark_input',
      'archive_sha256': archiveIdentity['sha256'],
      'archive_manifest_sha256': archiveManifestIdentity['sha256'],
      'pose_sha256': poseIdentity['sha256'],
      'fed_frames_sha256': fedFramesIdentity['sha256'],
      'native_framework_sha256': expectedGlobalPtolNativeFrameworkSha256,
      'archive': archiveIdentity,
      'archive_manifest': archiveManifestIdentity,
      'pose_sidecar': poseIdentity,
      'fed_frames': fedFramesIdentity,
      'archive_policy': archivePolicyIdentity,
      'native_framework': <String, Object?>{
        'expected_sha256': expectedGlobalPtolNativeFrameworkSha256,
        'verification': 'host_verified_before_launch',
      },
    };
    await flush('source_inputs_verified');

    onStatus?.call('Materializing the production SQLite database…');
    final materialized = await DatabaseArchiveResolver(
      codec: databaseArchiveCodec,
      preprocessor: databaseArchivePreprocessor,
    ).resolveDatabase(inputDirectory);
    if (materialized == null) {
      throw StateError('Production database archive materialization failed');
    }
    final materializedIdentity = await _verifyFile(
      materialized,
      expectedBytes: expectedGlobalPtolMaterializedSqliteBytes,
      expectedSha256: expectedGlobalPtolMaterializedSqliteSha256,
    );
    final frozenIdentity = GlobalPtolInputIdentity(
      archiveSha256: archiveIdentity['sha256']! as String,
      archiveManifestSha256: archiveManifestIdentity['sha256']! as String,
      poseSha256: poseIdentity['sha256']! as String,
      materializedSqliteSha256: materializedIdentity['sha256']! as String,
      nativeFrameworkSha256: expectedGlobalPtolNativeFrameworkSha256,
    );
    if (!isFrozenGlobalPtolInputIdentity(frozenIdentity)) {
      throw StateError('Frozen global PTOL input identity mismatch');
    }
    (result['input_identity']! as Map<String, Object?>)['materialized_sqlite'] =
        materializedIdentity;
    (result['input_identity']!
            as Map<String, Object?>)['materialized_sqlite_sha256'] =
        materializedIdentity['sha256'];
    await flush('input_verified');

    final fedFrameMeta = await _loadFedFrameMeta(fedFrames);
    if (fedFrameMeta.isEmpty) {
      throw StateError('Verified fed-frame sidecar produced no frame metadata');
    }
    result['fed_frame_meta_count'] = fedFrameMeta.length;
    result['fed_frame_meta_with_arkit'] = fedFrameMeta.values
        .where((meta) => meta.arkitQuatWxyz != null)
        .length;
    await flush('resume_metadata_verified');

    final runDirectory = Directory(
      '${documents.path}/global_ptol_benchmark/$_runId',
    );
    if (await runDirectory.exists()) {
      throw StateError(
        'Benchmark run directory already exists; use a fresh run ID',
      );
    }
    await runDirectory.create(recursive: true);

    final armResults = <_GlobalPtolArmResult>[];
    for (final arm in _armSpecs) {
      onStatus?.call('Running ${arm.label} (PTOL=${arm.ptol})…');
      final armResult = await _runArm(
        spec: arm,
        runDirectory: runDirectory,
        materializedDatabase: materialized,
        poseSidecar: poseSidecar,
        fedFrameMeta: fedFrameMeta,
      );
      armResults.add(armResult);
      await _writeJsonAtomic(
        File('${runDirectory.path}/${arm.label}/global_ptol_arm_result.json'),
        armResult.toJson(),
      );
      result['arms'] = <Object?>[
        for (final completed in armResults) completed.toJson(),
      ];
      await flush('arm_${arm.label}_complete');
    }

    final gateArms = <GlobalPtolArmMetrics>[
      for (final arm in armResults) arm.gateMetrics,
    ];
    if (!hasExactGlobalPtolArmOrder(gateArms)) {
      throw StateError('Completed arms violate the frozen A/B/A/B order');
    }
    final evaluation = evaluateGlobalPtolWinner(gateArms);
    result['evaluation'] = evaluation.toJson();
    result['winner'] = evaluation.toJson();
    result['diagnostic_candidate_value'] = evaluation.eligible ? '1e-8' : null;
    result['advance_to_end_to_end_candidate'] = evaluation.eligible;
    result['production_eligible'] = false;
    result['status'] = evaluation.eligible ? 'passed' : 'not_eligible';
    await flush('complete');
    return result;
  } catch (error, stack) {
    result['status'] = 'failed';
    result['production_eligible'] = false;
    result['error'] = '$error';
    result['stack'] = '$stack';
    await flush('failed');
    onStatus?.call('FAIL: $error');
    return result;
  } finally {
    AetherProcessEnv.unset(_globalPtolEnvironmentName);
  }
}

Future<_GlobalPtolArmResult> _runArm({
  required GlobalPtolArmSpec spec,
  required Directory runDirectory,
  required File materializedDatabase,
  required File poseSidecar,
  required Map<int, SfmFedFrameMeta> fedFrameMeta,
}) async {
  final armDirectory = Directory('${runDirectory.path}/${spec.label}');
  if (await armDirectory.exists()) {
    throw StateError('Arm directory already exists: ${spec.label}');
  }
  await armDirectory.create(recursive: false);

  final armDatabase = File(
    '${armDirectory.path}/${DatabaseArchivePolicy.sourceFileName}',
  );
  await materializedDatabase.copy(armDatabase.path);
  await poseSidecar.copy('${armDatabase.path}.arkit_pose_v1');
  final copiedDatabaseIdentity = await _verifyFile(
    armDatabase,
    expectedBytes: expectedGlobalPtolMaterializedSqliteBytes,
    expectedSha256: expectedGlobalPtolMaterializedSqliteSha256,
  );
  final copiedPoseIdentity = await _verifyFile(
    File('${armDatabase.path}.arkit_pose_v1'),
    expectedBytes: expectedGlobalPtolPoseBytes,
    expectedSha256: expectedGlobalPtolPoseSha256,
  );

  AetherProcessEnv.unset(_globalPtolEnvironmentName);
  AetherProcessEnv.set(_globalPtolEnvironmentName, spec.ptol);
  final stopwatch = Stopwatch()..start();
  SfmLiveRecon? recon;
  StreamSubscription<SfmLiveEvent>? subscription;
  try {
    recon = await SfmLiveRecon.start(dbPath: armDatabase.path);
    if (recon == null) {
      throw StateError('SfmLiveRecon.start returned null for ${spec.label}');
    }
    recon.seedFedMeta(fedFrameMeta);
    final refined = Completer<SfmLiveRefined>();
    subscription = recon.events.listen(
      (event) {
        if (event is SfmLiveRefined && !refined.isCompleted) {
          refined.complete(event);
        } else if (event is SfmLiveFailed && !refined.isCompleted) {
          refined.completeError(StateError('${event.stage}: ${event.message}'));
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!refined.isCompleted) refined.completeError(error, stack);
      },
      onDone: () {
        if (!refined.isCompleted) {
          refined.completeError(
            StateError('Reconstruction event stream closed before refined'),
          );
        }
      },
    );
    recon.resumeFromDb(imageWidth: 4032, imageHeight: 3024);
    final event = await refined.future.timeout(const Duration(minutes: 25));
    stopwatch.stop();

    final snapshot = event.snapshot;
    final reprojectionErrorPx = (snapshot.summary['reproj_px']! as num)
        .toDouble();
    if (!reprojectionErrorPx.isFinite) {
      throw StateError('Non-finite reprojection error for ${spec.label}');
    }
    await persistSparseSnapshot(
      captureDir: armDirectory.path,
      snapshot: snapshot,
      rgb: snapshot.rgb,
    );
    final ply = File('${armDirectory.path}/$_sparsePlyName');
    final metadata = File('${armDirectory.path}/$_sparseMetaName');
    if (!await ply.exists() ||
        await ply.length() <= 0 ||
        !await metadata.exists() ||
        await metadata.length() <= 0) {
      throw StateError('Missing or empty PLY/meta for ${spec.label}');
    }

    final plyIdentity = await _fileIdentity(ply);
    final metadataIdentity = await _fileIdentity(metadata);
    final segments = File('${armDirectory.path}/$_finalizeSegmentsName');
    final segmentsIdentity = await segments.exists()
        ? await _fileIdentity(segments)
        : null;
    return _GlobalPtolArmResult(
      spec: spec,
      elapsedMs: stopwatch.elapsedMilliseconds,
      refineMs: event.refineMs,
      registeredCameras: snapshot.registeredCount,
      pointCount: snapshot.pointCount,
      reprojectionErrorPx: reprojectionErrorPx,
      summary: Map<String, Object?>.from(snapshot.summary),
      databaseIdentity: copiedDatabaseIdentity,
      poseIdentity: copiedPoseIdentity,
      plyIdentity: plyIdentity,
      metadataIdentity: metadataIdentity,
      finalizeSegmentsIdentity: segmentsIdentity,
    );
  } finally {
    stopwatch.stop();
    await subscription?.cancel();
    await recon?.dispose();
  }
}

Future<Map<int, SfmFedFrameMeta>> _loadFedFrameMeta(File sidecar) async {
  final frameMeta = <int, SfmFedFrameMeta>{};
  List<double>? doubles(Object? value) => value is List
      ? value.map((item) => (item as num).toDouble()).toList(growable: false)
      : null;
  for (final line in await sidecar.readAsLines()) {
    if (line.trim().isEmpty) continue;
    final row = jsonDecode(line) as Map<String, Object?>;
    final frameId = (row['frameId']! as num).toInt();
    final grayWidth = (row['grayW']! as num).toInt();
    final grayHeight = (row['grayH']! as num).toInt();
    frameMeta[frameId] = SfmFedFrameMeta(
      jpegPath: (row['jpegPath']! as String).split('/').last,
      imageW: grayWidth,
      imageH: grayHeight,
      grayW: grayWidth,
      grayH: grayHeight,
      fx: 0,
      fy: 0,
      cx: 0,
      cy: 0,
      arkitQuatWxyz: doubles(row['arkitCamFromWorldQwxyz']),
      arkitTransTxyz: doubles(row['arkitCamFromWorldTxyz']),
      arkitCameraCenterWorld: doubles(row['arkitCameraCenterWorld']),
    );
  }
  return frameMeta;
}

class _GlobalPtolArmResult {
  const _GlobalPtolArmResult({
    required this.spec,
    required this.elapsedMs,
    required this.refineMs,
    required this.registeredCameras,
    required this.pointCount,
    required this.reprojectionErrorPx,
    required this.summary,
    required this.databaseIdentity,
    required this.poseIdentity,
    required this.plyIdentity,
    required this.metadataIdentity,
    required this.finalizeSegmentsIdentity,
  });

  final GlobalPtolArmSpec spec;
  final int elapsedMs;
  final int refineMs;
  final int registeredCameras;
  final int pointCount;
  final double reprojectionErrorPx;
  final Map<String, Object?> summary;
  final Map<String, Object?> databaseIdentity;
  final Map<String, Object?> poseIdentity;
  final Map<String, Object?> plyIdentity;
  final Map<String, Object?> metadataIdentity;
  final Map<String, Object?>? finalizeSegmentsIdentity;

  GlobalPtolArmMetrics get gateMetrics => GlobalPtolArmMetrics(
    label: spec.label,
    ptol: spec.ptol,
    elapsedMs: elapsedMs,
    registeredCameras: registeredCameras,
    pointCount: pointCount,
    reprojectionErrorPx: reprojectionErrorPx,
    succeeded: true,
    plyBytes: plyIdentity['bytes']! as int,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'label': spec.label,
    'ptol': spec.ptol,
    'effective_global_ptol': spec.ptol,
    'succeeded': true,
    'elapsed_ms': elapsedMs,
    'refine_ms': refineMs,
    'registered': registeredCameras,
    'delivered_points': pointCount,
    'reprojection_error_px': reprojectionErrorPx,
    'summary': summary,
    'database': databaseIdentity,
    'pose_sidecar': poseIdentity,
    'ply_bytes': plyIdentity['bytes'],
    'ply_sha256': plyIdentity['sha256'],
    'sparse_meta': metadataIdentity,
    if (finalizeSegmentsIdentity != null)
      'finalize_segments': finalizeSegmentsIdentity,
  };
}

Future<Map<String, Object?>> _verifyFile(
  File file, {
  required int expectedBytes,
  required String expectedSha256,
}) async {
  if (!await file.exists()) {
    throw StateError('Required input is missing: ${file.path}');
  }
  final identity = await _fileIdentity(file);
  if (identity['bytes'] != expectedBytes ||
      identity['sha256'] != expectedSha256) {
    throw StateError('Frozen identity mismatch: ${file.path}');
  }
  return <String, Object?>{
    ...identity,
    'expected_bytes': expectedBytes,
    'expected_sha256': expectedSha256,
    'verified': true,
  };
}

Future<Map<String, Object?>> _fileIdentity(File file) async =>
    <String, Object?>{
      'file_name': file.uri.pathSegments.last,
      'bytes': await file.length(),
      'sha256': await _sha256Of(file),
    };

Future<String> _sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _writeJsonAtomic(
  File destination,
  Map<String, Object?> data,
) async {
  final temporary = File('${destination.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
    flush: true,
  );
  await temporary.rename(destination.path);
}

void _validateRunId(String runId) {
  if (runId.isEmpty || !RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(runId)) {
    throw StateError('PW_GLOBAL_PTOL_RUN_ID is empty or unsafe');
  }
}
