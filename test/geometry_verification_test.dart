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
