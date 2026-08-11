import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'official_capture/lepton_jxl_benchmark_gate.dart';
import 'official_capture/lepton_photo_archive_ffi_codec.dart';
import 'official_capture/photo_archive_codec.dart';
import 'official_capture/photo_archive_ffi_codec.dart';
import 'official_capture/photo_archive_policy.dart';

const _bundleId = 'com.kyle.PocketWorld.LeptonBench';
const _resultFileName = 'lepton_jxl_benchmark_result.json';
const _runId = String.fromEnvironment(
  'PW_LEPTON_BENCH_RUN_ID',
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
  String _status = 'Starting official Lepton/JXL iPhone A/B…';

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final result = await runLeptonJxlBenchmark(
        onStatus: (value) {
          if (mounted) setState(() => _status = value);
        },
      );
      if (mounted) {
        setState(() => _status = 'Result: ${result['status']}');
      }
    } catch (error, stack) {
      final documents = await getApplicationDocumentsDirectory();
      await _writeJsonAtomic(
        File('${documents.path}/$_resultFileName'),
        <String, Object?>{
          'schema': 'pw_lepton_jxl_iphone_ab_result_v1',
          'run_id': _runId,
          'bundle_id': _bundleId,
          'status': 'failed',
          'production_eligible': false,
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

Future<Map<String, Object?>> runLeptonJxlBenchmark({
  void Function(String status)? onStatus,
}) async {
  final documents = await getApplicationDocumentsDirectory();
  final input = File('${documents.path}/benchmark_input.jpg');
  final resultFile = File('${documents.path}/$_resultFileName');
  if (!await input.exists()) {
    final waiting = <String, Object?>{
      'schema': 'pw_lepton_jxl_iphone_ab_result_v1',
      'run_id': _runId,
      'bundle_id': _bundleId,
      'status': 'waiting_for_input',
      'production_eligible': false,
      'expected_input': 'benchmark_input.jpg',
      'expected_source_bytes': expectedLeptonJxlSourceBytes,
      'expected_source_sha256': expectedLeptonJxlSourceSha256,
    };
    await _writeJsonAtomic(resultFile, waiting);
    onStatus?.call('Waiting for immutable benchmark_input.jpg');
    return waiting;
  }

  final sourceBytes = await input.length();
  final sourceSha256 = await _sha256Of(input);
  if (!isExpectedLeptonJxlBenchmarkInput(
    bytes: sourceBytes,
    sha256Hex: sourceSha256,
  )) {
    final rejected = <String, Object?>{
      'schema': 'pw_lepton_jxl_iphone_ab_result_v1',
      'run_id': _runId,
      'bundle_id': _bundleId,
      'status': 'failed',
      'production_eligible': false,
      'error': 'immutable input identity mismatch',
      'source_bytes': sourceBytes,
      'source_sha256': sourceSha256,
      'expected_source_bytes': expectedLeptonJxlSourceBytes,
      'expected_source_sha256': expectedLeptonJxlSourceSha256,
    };
    await _writeJsonAtomic(resultFile, rejected);
    return rejected;
  }

  final jxlCodec = JxlFfiPhotoArchiveCodec(effort: 10);
  final leptonCodec = LeptonFfiPhotoArchiveCodec();
  if (!jxlCodec.isSupported || !leptonCodec.isSupported) {
    throw StateError('JXL or official Lepton FFI is unavailable');
  }

  var peakRssBytes = ProcessInfo.currentRss;
  final rssSampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
    final current = ProcessInfo.currentRss;
    if (current > peakRssBytes) peakRssBytes = current;
  });
  final jxlArchive = File('${documents.path}/benchmark_input.jpg.jxl');
  final jxlRestored = File('${documents.path}/benchmark_jxl_restored.jpg');
  final leptonArchive = File('${documents.path}/benchmark_input.jpg.lep');
  final leptonRestored = File(
    '${documents.path}/benchmark_lepton_restored.jpg',
  );
  for (final file in <File>[
    jxlArchive,
    jxlRestored,
    leptonArchive,
    leptonRestored,
  ]) {
    await _deleteIfPresent(file);
  }

  try {
    onStatus?.call('Running production JXL effort 10…');
    final jxl = await _runArm(
      name: 'jxl',
      source: input,
      archive: jxlArchive,
      restored: jxlRestored,
      codec: jxlCodec,
      codecVersion: '0.12.0',
      codecRevision: PhotoArchivePolicy.pinnedLibjxlRevision,
    );
    await _writeJsonAtomic(resultFile, <String, Object?>{
      'schema': 'pw_lepton_jxl_iphone_ab_result_v1',
      'run_id': _runId,
      'bundle_id': _bundleId,
      'status': 'running',
      'source_bytes': sourceBytes,
      'source_sha256': sourceSha256,
      'jxl': jxl.toJson(),
      'production_eligible': false,
    });

    onStatus?.call('Running official Rust Lepton 0.5.8…');
    final lepton = await _runArm(
      name: 'lepton',
      source: input,
      archive: leptonArchive,
      restored: leptonRestored,
      codec: leptonCodec,
      codecVersion: leptonCodec.version,
      codecRevision: leptonCodec.revision,
    );

    final productionEligible = isLeptonProductionEligible(
      jxlExact: jxl.exact,
      leptonExact: lepton.exact,
      jxlArchiveBytes: jxl.archiveBytes,
      leptonArchiveBytes: lepton.archiveBytes,
    );
    final winner = lepton.archiveBytes < jxl.archiveBytes
        ? 'lepton'
        : jxl.archiveBytes < lepton.archiveBytes
        ? 'jxl'
        : 'tie';
    final result = <String, Object?>{
      'schema': 'pw_lepton_jxl_iphone_ab_result_v1',
      'run_id': _runId,
      'bundle_id': _bundleId,
      'status': productionEligible ? 'passed' : 'not_eligible',
      'platform': Platform.operatingSystem,
      'operating_system_version': Platform.operatingSystemVersion,
      'source_bytes': sourceBytes,
      'source_sha256': sourceSha256,
      'jxl': jxl.toJson(),
      'lepton': lepton.toJson(),
      'winner': winner,
      'lepton_archive_bytes < jxl_archive_bytes':
          lepton.archiveBytes < jxl.archiveBytes,
      'production_eligible': productionEligible,
      'peak_rss_bytes': peakRssBytes,
    };
    await _writeJsonAtomic(resultFile, result);
    return result;
  } finally {
    rssSampler.cancel();
  }
}

Future<_ArmResult> _runArm({
  required String name,
  required File source,
  required File archive,
  required File restored,
  required PhotoArchiveCodec codec,
  required String codecVersion,
  required String codecRevision,
}) async {
  final encodeWatch = Stopwatch()..start();
  await codec.encodeJpeg(sourceJpeg: source, destinationJxl: archive);
  encodeWatch.stop();
  if (!await archive.exists()) {
    throw StateError('$name encoder produced no archive');
  }

  final decodeWatch = Stopwatch()..start();
  await codec.reconstructJpeg(sourceJxl: archive, destinationJpeg: restored);
  decodeWatch.stop();
  if (!await restored.exists()) {
    throw StateError('$name decoder produced no JPEG');
  }

  final sourceSha256 = await _sha256Of(source);
  final restoredSha256 = await _sha256Of(restored);
  final byteEqual = await _filesEqual(source, restored);
  return _ArmResult(
    codec: name,
    codecVersion: codecVersion,
    codecRevision: codecRevision,
    archiveBytes: await archive.length(),
    archiveSha256: await _sha256Of(archive),
    restoredBytes: await restored.length(),
    restoredSha256: restoredSha256,
    byteEqual: byteEqual,
    sha256Equal: sourceSha256 == restoredSha256,
    encodeElapsedUs: encodeWatch.elapsedMicroseconds,
    decodeElapsedUs: decodeWatch.elapsedMicroseconds,
  );
}

class _ArmResult {
  const _ArmResult({
    required this.codec,
    required this.codecVersion,
    required this.codecRevision,
    required this.archiveBytes,
    required this.archiveSha256,
    required this.restoredBytes,
    required this.restoredSha256,
    required this.byteEqual,
    required this.sha256Equal,
    required this.encodeElapsedUs,
    required this.decodeElapsedUs,
  });

  final String codec;
  final String codecVersion;
  final String codecRevision;
  final int archiveBytes;
  final String archiveSha256;
  final int restoredBytes;
  final String restoredSha256;
  final bool byteEqual;
  final bool sha256Equal;
  final int encodeElapsedUs;
  final int decodeElapsedUs;

  bool get exact => byteEqual && sha256Equal;

  Map<String, Object?> toJson() => <String, Object?>{
    'codec': codec,
    'codec_version': codecVersion,
    'codec_revision': codecRevision,
    'archive_bytes': archiveBytes,
    'archive_sha256': archiveSha256,
    'restored_bytes': restoredBytes,
    'restored_sha256': restoredSha256,
    'byte_equal': byteEqual,
    'sha256_equal': sha256Equal,
    'exact': exact,
    'encode_elapsed_us': encodeElapsedUs,
    'decode_elapsed_us': decodeElapsedUs,
  };
}

Future<String> _sha256Of(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<bool> _filesEqual(File left, File right) async {
  if (!await left.exists() || !await right.exists()) return false;
  if (await left.length() != await right.length()) return false;
  final leftHandle = await left.open();
  final rightHandle = await right.open();
  try {
    const chunkSize = 256 * 1024;
    while (true) {
      final leftBytes = await leftHandle.read(chunkSize);
      final rightBytes = await rightHandle.read(chunkSize);
      if (leftBytes.length != rightBytes.length) return false;
      if (leftBytes.isEmpty) return true;
      for (var index = 0; index < leftBytes.length; index++) {
        if (leftBytes[index] != rightBytes[index]) return false;
      }
    }
  } finally {
    await leftHandle.close();
    await rightHandle.close();
  }
}

Future<void> _writeJsonAtomic(
  File destination,
  Map<String, Object?> data,
) async {
  final temporary = File('${destination.path}.tmp');
  await temporary.writeAsString(
    const JsonEncoder.withIndent('  ').convert(data),
    flush: true,
  );
  if (await destination.exists()) await destination.delete();
  await temporary.rename(destination.path);
}

Future<void> _deleteIfPresent(File file) async {
  if (await file.exists()) await file.delete();
}
