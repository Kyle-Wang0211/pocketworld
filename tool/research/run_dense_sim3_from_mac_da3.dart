import 'dart:convert';
import 'dart:io';

import 'package:pocketworld_flutter/pipeline/geometry_verification.dart';

Future<void> main(List<String> args) async {
  final parsed = _parseArgs(args);
  final captureDir = Directory(_required(parsed, 'capture-dir'));
  final depthDir = Directory(_required(parsed, 'depth-dir'));
  final depthRunnerReportFile = File(
    '${depthDir.path}/depth_runner_report.json',
  );
  final depthIndexFile = File('${depthDir.path}/depth_index.json');
  final kWindowsFile = File('${captureDir.path}/da3_k_windows.json');

  final depthRunnerReport = await _readJsonMap(depthRunnerReportFile);
  final depthIndex = await _readJsonMap(depthIndexFile);
  final kWindowsPlan = await _readJsonMap(kWindowsFile);
  final windowReports = _maps(depthRunnerReport['windows']);
  final kWindowGraph = <String, Object?>{
    'windowing_policy': _mapValue(kWindowsPlan['windowingPolicy']),
    'bridge_graph': _maps(kWindowsPlan['bridgeGraph']),
    'loop_closure_policy': _mapValue(kWindowsPlan['loopClosurePolicy']),
    'loop_candidates': _maps(kWindowsPlan['loopCandidates']),
    'uncovered_frame_ids': _strings(kWindowsPlan['uncoveredFrameIDs']),
  };

  final visualReport = await const ContractOnlyVisualLoopRetrievalExecutor()
      .retrieve(
        VisualLoopRetrievalRequest(
          captureDir: captureDir,
          depthOutputDir: depthDir,
          kWindowGraph: kWindowGraph,
          windowReports: windowReports,
        ),
      );
  final visualJson = visualReport.toJson();
  await _writeJson(
    File('${depthDir.path}/visual_loop_retrieval_report.json'),
    visualJson,
  );

  final denseReport = await const DartDenseSim3Verifier().verify(
    DenseSim3VerificationRequest(
      captureDir: captureDir,
      depthOutputDir: depthDir,
      kWindowGraph: kWindowGraph,
      windowReports: windowReports,
      visualLoopRetrievalReport: visualJson,
    ),
  );
  final denseJson = denseReport.toJson();
  await _writeJson(
    File('${depthDir.path}/dense_sim3_verification_report.json'),
    denseJson,
  );

  final streaming = _mapValue(denseJson['streaming_alignment']);
  final transformByWindowID = <String, Map<String, Object?>>{
    for (final transform in _maps(streaming['windowTransforms']))
      _asString(transform['windowID']): transform,
  }..removeWhere((key, _) => key.isEmpty);

  final frames = [
    for (final frame in _maps(depthIndex['frames']))
      {
        ...frame,
        if (transformByWindowID[_asString(frame['windowID'])]?['sim3'] != null)
          'windowToRootSim3':
              transformByWindowID[_asString(frame['windowID'])]!['sim3'],
        if (transformByWindowID[_asString(frame['windowID'])]?['status'] !=
            null)
          'streamingAlignmentStatus':
              transformByWindowID[_asString(frame['windowID'])]!['status'],
      },
  ];

  final geometryGateStatus = _asString(
    denseJson['status'],
    fallback: 'unknown',
  );
  final updatedDepthIndex = <String, Object?>{
    ...depthIndex,
    'visual_loop_retrieval_report_path': 'visual_loop_retrieval_report.json',
    'visual_loop_retrieval': visualJson,
    'dense_sim3_verification_report_path':
        'dense_sim3_verification_report.json',
    'dense_sim3_verification': denseJson,
    'streaming_alignment': streaming,
    'geometry_gate_status': geometryGateStatus,
    'geometry_gate_blocks_downstream': geometryGateStatus != 'passed',
    'frames': frames,
  };
  await _writeJson(depthIndexFile, updatedDepthIndex);

  final updatedRunnerReport = <String, Object?>{
    ...depthRunnerReport,
    'visual_loop_retrieval': visualJson,
    'dense_sim3_verification': denseJson,
    'streaming_alignment': streaming,
    'geometry_gate_status': geometryGateStatus,
  };
  await _writeJson(depthRunnerReportFile, updatedRunnerReport);

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'status': geometryGateStatus,
      'window_count': windowReports.length,
      'dense_sim3_counts': denseJson['counts'],
      'streaming_alignment_status': streaming['status'],
      'aligned_window_count': streaming['alignedWindowCount'],
    }),
  );
}

Map<String, String> _parseArgs(List<String> args) {
  final parsed = <String, String>{};
  for (var i = 0; i < args.length; i += 1) {
    final raw = args[i];
    if (!raw.startsWith('--')) continue;
    final key = raw.substring(2);
    if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
      parsed[key] = 'true';
    } else {
      parsed[key] = args[i + 1];
      i += 1;
    }
  }
  return parsed;
}

String _required(Map<String, String> args, String key) {
  final value = args[key];
  if (value == null || value.isEmpty) {
    throw ArgumentError('Missing --$key');
  }
  return value;
}

Future<Map<String, Object?>> _readJsonMap(File file) async {
  final value = jsonDecode(await file.readAsString());
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  throw FormatException('${file.path} is not a JSON object');
}

Future<void> _writeJson(File file, Object? value) {
  return file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(value),
    flush: true,
  );
}

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return Map<String, Object?>.from(value);
  return <String, Object?>{};
}

List<Map<String, Object?>> _maps(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return [
    for (final item in value)
      if (item is Map<String, Object?>)
        item
      else if (item is Map)
        Map<String, Object?>.from(item),
  ];
}

List<String> _strings(Object? value) {
  if (value is! List) return const <String>[];
  return [for (final item in value) item.toString()];
}

String _asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  return value.toString();
}
