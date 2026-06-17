import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/pipeline/geometry_verification.dart';

void main() {
  test(
    'DartDenseSim3Verifier accepts identical shared-frame geometry',
    () async {
      final root = await Directory.systemTemp.createTemp('dense_sim3_');
      addTearDown(() => root.delete(recursive: true));
      Directory('${root.path}/relative_depth').createSync();
      Directory('${root.path}/confidence').createSync();
      Directory('${root.path}/pred_pose').createSync();

      const width = 64;
      const height = 64;
      const sharedFrameIDs = ['a', 'b', 'c'];
      final sourceFrames = <Map<String, Object?>>[];
      final targetFrames = <Map<String, Object?>>[];

      for (final frameID in sharedFrameIDs) {
        final sourcePrefix = 'source_$frameID';
        final targetPrefix = 'target_$frameID';
        await _writeTensor(
          File('${root.path}/relative_depth/$sourcePrefix.bin'),
          List<double>.filled(width * height, 1.4),
        );
        await _writeTensor(
          File('${root.path}/relative_depth/$targetPrefix.bin'),
          List<double>.filled(width * height, 1.4),
        );
        await _writeTensor(
          File('${root.path}/confidence/$sourcePrefix.bin'),
          List<double>.filled(width * height, 1.0),
        );
        await _writeTensor(
          File('${root.path}/confidence/$targetPrefix.bin'),
          List<double>.filled(width * height, 1.0),
        );
        await _writeTensor(
          File('${root.path}/pred_pose/${sourcePrefix}_extrinsics.bin'),
          _identity3x4,
        );
        await _writeTensor(
          File('${root.path}/pred_pose/${targetPrefix}_extrinsics.bin'),
          _identity3x4,
        );
        await _writeTensor(
          File('${root.path}/pred_pose/${sourcePrefix}_intrinsics.bin'),
          _intrinsics,
        );
        await _writeTensor(
          File('${root.path}/pred_pose/${targetPrefix}_intrinsics.bin'),
          _intrinsics,
        );

        sourceFrames.add(
          _frame(
            frameID: frameID,
            prefix: sourcePrefix,
            width: width,
            height: height,
          ),
        );
        targetFrames.add(
          _frame(
            frameID: frameID,
            prefix: targetPrefix,
            width: width,
            height: height,
          ),
        );
      }

      final report = await const DartDenseSim3Verifier().verify(
        DenseSim3VerificationRequest(
          captureDir: root,
          depthOutputDir: root,
          kWindowGraph: {
            'bridge_graph': [
              {
                'sourceWindowID': 'window_000',
                'targetWindowID': 'window_001',
                'kind': 'tree_bridge',
                'bridgeFrameIDs': sharedFrameIDs,
              },
            ],
            'loop_candidates': const <Map<String, Object?>>[],
          },
          windowReports: [
            {'windowID': 'window_000', 'frames': sourceFrames},
            {'windowID': 'window_001', 'frames': targetFrames},
          ],
          visualLoopRetrievalReport: const {
            'status': 'not_configured',
            'candidates': <Map<String, Object?>>[],
          },
        ),
      );

      final json = report.toJson();
      expect(json['status'], 'passed');
      final alignment = json['streaming_alignment'] as Map;
      expect(
        alignment['contractVersion'],
        kDa3StreamingGeometryContractVersion,
      );
      expect(alignment['loopRetrievalBackend'], 'SelaVPR++');
      final optimizer = alignment['loopOptimizer'] as Map;
      expect(optimizer['executor'], 'OfficialSim3LoopOptimizer');
      expect(optimizer['policyOwner'], 'Flutter/Dart');
      expect(optimizer['status'], 'not_run_no_dense_verified_loop_constraints');
      final bridge = (json['bridge_edges'] as List).single as Map;
      expect(bridge['status'], 'accepted');
      expect(bridge['usedSharedFrameCount'], 3);
      expect(bridge['pointCount'], greaterThanOrEqualTo(96));
      final sim3 = bridge['sim3'] as Map;
      expect(sim3['scale'], closeTo(1.0, 1e-9));
      expect(sim3['normalizedRmse'], closeTo(0.0, 1e-9));
    },
  );

  test(
    'DartDenseSim3Verifier accumulates target-to-source bridge Sim3',
    () async {
      final root = await Directory.systemTemp.createTemp('dense_sim3_chain_');
      addTearDown(() => root.delete(recursive: true));
      Directory('${root.path}/relative_depth').createSync();
      Directory('${root.path}/confidence').createSync();
      Directory('${root.path}/pred_pose').createSync();

      const width = 64;
      const height = 64;
      const sharedFrameIDs = ['a', 'b', 'c'];
      final window0 = await _writeWindowGeometry(
        root: root,
        windowPrefix: 'w0',
        frameIDs: sharedFrameIDs,
        width: width,
        height: height,
        worldShiftX: 0,
      );
      final window1 = await _writeWindowGeometry(
        root: root,
        windowPrefix: 'w1',
        frameIDs: sharedFrameIDs,
        width: width,
        height: height,
        worldShiftX: 2,
      );
      final window2 = await _writeWindowGeometry(
        root: root,
        windowPrefix: 'w2',
        frameIDs: sharedFrameIDs,
        width: width,
        height: height,
        worldShiftX: 5,
      );

      final report = await const DartDenseSim3Verifier().verify(
        DenseSim3VerificationRequest(
          captureDir: root,
          depthOutputDir: root,
          kWindowGraph: {
            'bridge_graph': [
              {
                'sourceWindowID': 'window_000',
                'targetWindowID': 'window_001',
                'kind': 'official_adjacent_chunk_bridge',
                'bridgeFrameIDs': sharedFrameIDs,
              },
              {
                'sourceWindowID': 'window_001',
                'targetWindowID': 'window_002',
                'kind': 'official_adjacent_chunk_bridge',
                'bridgeFrameIDs': sharedFrameIDs,
              },
            ],
            'loop_candidates': const <Map<String, Object?>>[],
          },
          windowReports: [
            {'windowID': 'window_000', 'frames': window0},
            {'windowID': 'window_001', 'frames': window1},
            {'windowID': 'window_002', 'frames': window2},
          ],
          visualLoopRetrievalReport: const {
            'status': 'not_configured',
            'candidates': <Map<String, Object?>>[],
          },
        ),
      );

      final json = report.toJson();
      expect(json['status'], 'passed');
      final edges = (json['bridge_edges'] as List).cast<Map>();
      final edge01 = edges.firstWhere((edge) {
        return edge['targetWindowID'] == 'window_001';
      });
      final edge12 = edges.firstWhere((edge) {
        return edge['targetWindowID'] == 'window_002';
      });
      _expectSim3Translation(edge01['sim3'] as Map, [-2, 0, 0]);
      _expectSim3Translation(edge12['sim3'] as Map, [-3, 0, 0]);

      final alignment = json['streaming_alignment'] as Map;
      expect(alignment['status'], 'ready_for_downstream_application');
      final transforms = (alignment['windowTransforms'] as List).cast<Map>();
      final transform1 = transforms.firstWhere((item) {
        return item['windowID'] == 'window_001';
      });
      final transform2 = transforms.firstWhere((item) {
        return item['windowID'] == 'window_002';
      });
      _expectSim3Translation(transform1['sim3'] as Map, [-2, 0, 0]);
      _expectSim3Translation(transform2['sim3'] as Map, [-5, 0, 0]);
    },
  );

  test('visual loop retrieval contract defaults to SelaVPR++', () async {
    final report = await const ContractOnlyVisualLoopRetrievalExecutor()
        .retrieve(
          VisualLoopRetrievalRequest(
            captureDir: Directory.systemTemp,
            depthOutputDir: Directory.systemTemp,
            kWindowGraph: const {
              'loop_candidates': [
                {
                  'sourceWindowID': 'window_010',
                  'targetWindowID': 'window_001',
                  'poseGraphCrossScore': 0.91,
                  'sharedFrameIDs': ['a', 'b'],
                },
              ],
            },
            windowReports: const [],
          ),
        );

    final json = report.toJson();
    expect(json['status'], 'awaiting_thin_executor');
    expect(json['executor'], 'VisualLoopRetrievalExecutor');
    final policy = json['policy'] as Map;
    expect(policy['selectedBackend'], 'SelaVPR++');
    expect(policy['defaultCommercialBackend'], 'SelaVPR++');
    expect(
      policy['blockedBundledBackends'],
      contains('GPL-3.0 SALAD reference implementation'),
    );
    final spec = policy['spec'] as Map;
    expect(spec['backend'], 'SelaVPR++');
    expect(spec['officialDa3StreamingMapping'], isA<Map>());
  });
}

const _identity3x4 = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];

const _intrinsics = <double>[60, 0, 32, 0, 60, 32, 0, 0, 1];

List<double> _translatedW2C(double worldShiftX) => [
  1,
  0,
  0,
  -worldShiftX,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
  0,
];

Future<List<Map<String, Object?>>> _writeWindowGeometry({
  required Directory root,
  required String windowPrefix,
  required List<String> frameIDs,
  required int width,
  required int height,
  required double worldShiftX,
}) async {
  final frames = <Map<String, Object?>>[];
  for (final frameID in frameIDs) {
    final prefix = '${windowPrefix}_$frameID';
    await _writeTensor(
      File('${root.path}/relative_depth/$prefix.bin'),
      List<double>.filled(width * height, 1.4),
    );
    await _writeTensor(
      File('${root.path}/confidence/$prefix.bin'),
      List<double>.filled(width * height, 1.0),
    );
    await _writeTensor(
      File('${root.path}/pred_pose/${prefix}_extrinsics.bin'),
      _translatedW2C(worldShiftX),
    );
    await _writeTensor(
      File('${root.path}/pred_pose/${prefix}_intrinsics.bin'),
      _intrinsics,
    );
    frames.add(
      _frame(frameID: frameID, prefix: prefix, width: width, height: height),
    );
  }
  return frames;
}

void _expectSim3Translation(Map sim3, List<double> expected) {
  expect(sim3['scale'], closeTo(1.0, 1e-9));
  final translation = (sim3['translation'] as List).cast<num>();
  for (var i = 0; i < expected.length; i += 1) {
    expect(translation[i].toDouble(), closeTo(expected[i], 1e-6));
  }
}

Map<String, Object?> _frame({
  required String frameID,
  required String prefix,
  required int width,
  required int height,
}) {
  return {
    'frameID': frameID,
    'status': 'completed',
    'relativeDepthPath': 'relative_depth/$prefix.bin',
    'confidencePath': 'confidence/$prefix.bin',
    'predExtrinsicsPath': 'pred_pose/${prefix}_extrinsics.bin',
    'predIntrinsicsPath': 'pred_pose/${prefix}_intrinsics.bin',
    'depthWidth': width,
    'depthHeight': height,
  };
}

Future<void> _writeTensor(File file, List<double> values) async {
  final bytes = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i += 1) {
    bytes.setFloat32(i * 4, values[i], Endian.little);
  }
  await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}
