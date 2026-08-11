import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'official_capture/database_archive_ffi_codec.dart';
import 'official_capture/database_archive_ffi_preprocessor.dart';
import 'official_capture/database_archive_manifest.dart';
import 'official_capture/database_archive_policy.dart';
import 'official_capture/database_archive_resolver.dart';
import 'official_capture/database_archive_transaction.dart';

const repeatCount = 1;
const trackDeltaV1HostBaselineBytes = 124401918;
const _resultFileName = 'database_archive_benchmark_result.json';
const _runId = String.fromEnvironment(
  'PW_BENCH_RUN_ID',
  defaultValue: 'manual',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BenchmarkApp());
}

class _BenchmarkApp extends StatefulWidget {
  const _BenchmarkApp();

  @override
  State<_BenchmarkApp> createState() => _BenchmarkAppState();
}

class _BenchmarkAppState extends State<_BenchmarkApp> {
  String _status = 'Starting independent SQLite archive benchmark…';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final result = await runDatabaseArchiveBenchmark(
        onStatus: (value) {
          if (mounted) setState(() => _status = value);
        },
      );
      if (mounted) {
        setState(
          () => _status = result['status'] == 'passed' ? 'PASS' : 'FAIL',
        );
      }
    } catch (error, stack) {
      final documents = await getApplicationDocumentsDirectory();
      await _writeJsonAtomic(
        File('${documents.path}/$_resultFileName'),
        <String, Object?>{
          'schema': 'pw_sqlite_exact_transform_v2_iphone_benchmark_v1',
          'run_id': _runId,
          'status': 'failed',
          'error': '$error',
          'stack': '$stack',
        },
      );
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

Future<Map<String, Object?>> runDatabaseArchiveBenchmark({
  void Function(String status)? onStatus,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final input = File('${documents.path}/benchmark_input.db');
  final resultFile = File('${documents.path}/$_resultFileName');
  if (!await input.exists()) {
    final waiting = <String, Object?>{
      'schema': 'pw_sqlite_exact_transform_v2_iphone_benchmark_v1',
      'run_id': _runId,
      'status': 'waiting_for_input',
      'expected_input': 'benchmark_input.db',
    };
    await _writeJsonAtomic(resultFile, waiting);
    onStatus?.call('Waiting for Documents/benchmark_input.db');
    return waiting;
  }

  final codec = ZpaqFfiDatabaseArchiveCodec();
  final preprocessor = TrackDeltaFfiDatabaseArchivePreprocessor();
  final exactV2 = ExactTransformV2FfiBenchmarkPreprocessor();
  if (!codec.isSupported || !preprocessor.isSupported || !exactV2.isSupported) {
    throw StateError('ZPAQ, track-delta, or exact v2 FFI is unavailable');
  }

  final sourceBytes = await input.length();
  final sourceSha256 = await databaseArchiveSha256(input);
  final sourceIntegrity = await preprocessor.integrityCheck(input);
  if (!sourceIntegrity) throw StateError('input SQLite integrity_check failed');

  var peakRssBytes = ProcessInfo.currentRss;
  final rssSampler = Timer.periodic(const Duration(milliseconds: 200), (_) {
    final current = ProcessInfo.currentRss;
    if (current > peakRssBytes) peakRssBytes = current;
  });
  final runs = <Map<String, Object?>>[];
  final workRoot = Directory(
    '${documents.path}/database_archive_benchmark_work',
  );
  if (await workRoot.exists()) await workRoot.delete(recursive: true);
  await workRoot.create(recursive: true);

  try {
    for (var repeat = 1; repeat <= repeatCount; repeat++) {
      onStatus?.call('Running phone repeat $repeat / $repeatCount');
      final capture = Directory('${workRoot.path}/repeat_$repeat');
      await capture.create(recursive: true);
      await DatabaseArchivePolicy.writeForNewCapture(capture);
      await File(
        '${capture.path}/official_sfm_sparse.ply',
      ).writeAsBytes(<int>[1], flush: true);
      await File(
        '${capture.path}/official_sfm_sparse_meta.json',
      ).writeAsString('{"n_points":1}', flush: true);
      final source = File(
        '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
      );
      await input.copy(source.path);

      final stopwatch = Stopwatch()..start();
      final exactV2Result = await _runExactV2Candidate(
        input: input,
        workDirectory: Directory('${capture.path}/exact_transform_v2'),
        codec: codec,
        preprocessor: exactV2,
        sourceBytes: sourceBytes,
        sourceSha256: sourceSha256,
      );
      final transaction = await DatabaseArchiveTransaction(
        codec: codec,
        preprocessor: preprocessor,
      ).archiveCapture(capture);
      final sourceDeletedAfterCommit = !await source.exists();
      final manifest = await DatabaseArchiveManifest.read(capture);
      if (!transaction.archived || manifest == null) {
        throw StateError('repeat $repeat did not publish an archive');
      }
      final archive = File(
        '${capture.path}/${DatabaseArchiveManifest.archiveFileName}',
      );
      final restored = await DatabaseArchiveResolver(
        codec: codec,
        preprocessor: preprocessor,
      ).resolveDatabase(capture);
      stopwatch.stop();
      if (restored == null) {
        throw StateError('repeat $repeat could not restore the database');
      }

      final restoredSha256 = await databaseArchiveSha256(restored);
      final byteEqual = await databaseArchiveFilesEqual(input, restored);
      final integrityOk = await preprocessor.integrityCheck(restored);
      final temporaryLeaks = <String>[];
      await for (final entity in capture.list(followLinks: false)) {
        if (entity.path.endsWith('.tmp')) {
          temporaryLeaks.add(entity.path.split(Platform.pathSeparator).last);
        }
      }
      temporaryLeaks.sort();
      final exact =
          await restored.length() == sourceBytes &&
          restoredSha256 == sourceSha256 &&
          byteEqual &&
          integrityOk;
      if (!exact || temporaryLeaks.isNotEmpty) {
        throw StateError('repeat $repeat exactness or cleanup gate failed');
      }

      runs.add(<String, Object?>{
        'repeat': repeat,
        'selected_preprocess': manifest.preprocess,
        'source_bytes': sourceBytes,
        'source_sha256': sourceSha256,
        'restored_sha256': restoredSha256,
        'archive_bytes': manifest.archiveBytes,
        'archive_sha256': await databaseArchiveSha256(archive),
        'raw_archive_bytes': manifest.rawArchiveBytes,
        'track_archive_bytes': manifest.trackArchiveBytes,
        'exact_v2_archive_bytes': exactV2Result['archive_bytes'],
        'exact_v2_archive_sha256': exactV2Result['archive_sha256'],
        'exact_v2_transformed_sha256': exactV2Result['transformed_sha256'],
        'exact_v2_restored_sha256': exactV2Result['restored_sha256'],
        'exact_v2_byte_equal': exactV2Result['byte_equal'],
        'exact_v2_integrity_check': exactV2Result['integrity_check'],
        'exact_v2_elapsed_ms': exactV2Result['elapsed_ms'],
        'source_deleted_after_commit': sourceDeletedAfterCommit,
        'byte_equal': byteEqual,
        'integrity_check': integrityOk ? 'ok' : 'failed',
        'temporary_leaks': temporaryLeaks,
        'elapsed_ms': stopwatch.elapsedMilliseconds,
      });
      await capture.delete(recursive: true);

      await _writeJsonAtomic(resultFile, <String, Object?>{
        'schema': 'pw_sqlite_exact_transform_v2_iphone_benchmark_v1',
        'run_id': _runId,
        'status': 'running',
        'completed_repeats': runs.length,
        'repeat_count': repeatCount,
        'source_bytes': sourceBytes,
        'source_sha256': sourceSha256,
        'runs': runs,
      });
    }
  } finally {
    rssSampler.cancel();
    if (await workRoot.exists()) await workRoot.delete(recursive: true);
  }

  final selected = runs.map((run) => run['selected_preprocess']).toSet();
  final rawSizes = runs.map((run) => run['raw_archive_bytes']).toSet();
  final trackSizes = runs.map((run) => run['track_archive_bytes']).toSet();
  final exactV2Sizes = runs.map((run) => run['exact_v2_archive_bytes']).toSet();
  final deterministic =
      selected.length == 1 &&
      rawSizes.length == 1 &&
      trackSizes.length == 1 &&
      exactV2Sizes.length == 1;
  final trackWinsEveryRepeat = runs.every((run) {
    final raw = run['raw_archive_bytes'] as int?;
    final track = run['track_archive_bytes'] as int?;
    return run['selected_preprocess'] == 'track_delta_v1' &&
        raw != null &&
        track != null &&
        track < raw;
  });
  final exactV2WinsEveryRepeat = runs.every((run) {
    final track = run['track_archive_bytes'] as int?;
    final exactV2Bytes = run['exact_v2_archive_bytes'] as int?;
    return track != null &&
        exactV2Bytes != null &&
        exactV2Bytes < track &&
        exactV2Bytes < trackDeltaV1HostBaselineBytes &&
        run['exact_v2_byte_equal'] == true &&
        run['exact_v2_integrity_check'] == 'ok';
  });
  final passed =
      deterministic && trackWinsEveryRepeat && exactV2WinsEveryRepeat;
  final result = <String, Object?>{
    'schema': 'pw_sqlite_exact_transform_v2_iphone_benchmark_v1',
    'run_id': _runId,
    'status': passed ? 'passed' : 'failed',
    'bundle_id': 'com.kyle.PocketWorld.ArchiveBench',
    'repeat_count': repeatCount,
    'source_bytes': sourceBytes,
    'source_sha256': sourceSha256,
    'source_integrity_check': sourceIntegrity ? 'ok' : 'failed',
    'deterministic': deterministic,
    'track_wins_every_repeat': trackWinsEveryRepeat,
    'exact_v2_wins_every_repeat': exactV2WinsEveryRepeat,
    'peak_rss_bytes': peakRssBytes,
    'runs': runs,
  };
  await _writeJsonAtomic(resultFile, result);
  return result;
}

Future<Map<String, Object?>> _runExactV2Candidate({
  required File input,
  required Directory workDirectory,
  required ZpaqFfiDatabaseArchiveCodec codec,
  required ExactTransformV2FfiBenchmarkPreprocessor preprocessor,
  required int sourceBytes,
  required String sourceSha256,
}) async {
  if (await workDirectory.exists()) {
    await workDirectory.delete(recursive: true);
  }
  await workDirectory.create(recursive: true);
  final transformed = File('${workDirectory.path}/transformed.db');
  final archive = File('${workDirectory.path}/archive.zpaq');
  final decoded = File('${workDirectory.path}/decoded.db');
  final restored = File('${workDirectory.path}/restored.db');
  final stopwatch = Stopwatch()..start();
  try {
    await preprocessor.transform(
      sourceDatabase: input,
      destinationDatabase: transformed,
    );
    if (!await preprocessor.integrityCheck(transformed)) {
      throw StateError('exact_transform_v2 transformed integrity failed');
    }
    await codec.compress(
      sourceDatabase: transformed,
      destinationArchive: archive,
    );
    await codec.decompress(
      sourceArchive: archive,
      destinationDatabase: decoded,
    );
    await preprocessor.restore(
      sourceDatabase: decoded,
      destinationDatabase: restored,
    );
    stopwatch.stop();

    final restoredSha256 = await databaseArchiveSha256(restored);
    final byteEqual =
        await restored.length() == sourceBytes &&
        restoredSha256 == sourceSha256 &&
        await databaseArchiveFilesEqual(input, restored);
    final integrityOk = await preprocessor.integrityCheck(restored);
    if (!byteEqual || !integrityOk) {
      throw StateError('exact_transform_v2 exactness failed');
    }
    return <String, Object?>{
      'arm': 'exact_transform_v2',
      'archive_bytes': await archive.length(),
      'archive_sha256': await databaseArchiveSha256(archive),
      'transformed_sha256': await databaseArchiveSha256(transformed),
      'restored_sha256': restoredSha256,
      'byte_equal': byteEqual,
      'integrity_check': integrityOk ? 'ok' : 'failed',
      'elapsed_ms': stopwatch.elapsedMilliseconds,
    };
  } finally {
    if (await workDirectory.exists()) {
      await workDirectory.delete(recursive: true);
    }
  }
}

Future<void> _writeJsonAtomic(File output, Map<String, Object?> value) async {
  final temporary = File('${output.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
  if (await output.exists()) await output.delete();
  await temporary.rename(output.path);
}
