import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/pipeline/metric_depth_alignment.dart';

void main() {
  test('metric-depth spec keeps Dart as policy owner', () {
    const spec = MetricDepthAlignmentSpec();

    final json = spec.toJson();

    expect(json['schema_version'], 'aether_metric_depth_alignment_spec_v1');
    expect(json['metric_authority'], 'arkit_vio_sparse_world_anchors');
    expect(
      (json['algorithm_executor_boundary'] as Map)['policyOwner'],
      'Flutter/Dart',
    );
    expect(
      ((json['algorithm_executor_boundary'] as Map)['executorMustNotOwn']
              as List)
          .cast<String>(),
      contains('metric authority selection'),
    );
  });

  test(
    'FFI executor writes skipped report when ARKit anchor sidecar is absent',
    () async {
      final captureDir = await Directory.systemTemp.createTemp(
        'metric_depth_alignment_capture_',
      );
      final depthDir = Directory('${captureDir.path}/stages/depth')
        ..createSync(recursive: true);
      addTearDown(() => captureDir.delete(recursive: true));

      final report = await const FfiMetricDepthAlignmentExecutor().align(
        MetricDepthAlignmentRequest(
          captureDir: captureDir,
          depthOutputDir: depthDir,
          denseSim3Verification: const {'status': 'passed'},
          frames: const [
            MetricDepthAlignmentFrame(
              frameID: 'cap-1',
              frameIndex: 0,
              status: 'completed',
              sourceImageRelativePath: 'photos_highres/cap-1.jpg',
              relativeDepthPath: 'relative_depth/cap-1.bin',
              confidencePath: 'confidence/cap-1.bin',
              depthWidth: 742,
              depthHeight: 476,
              imageWidth: 4224,
              imageHeight: 2376,
              cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
              intrinsics: [2600, 2600, 2112, 1188],
              preprocessTransform: {'scaleX': 742 / 4224, 'scaleY': 476 / 2376},
            ),
          ],
        ),
      );

      expect(report.status, 'skipped');
      expect(report.frames.single.reason, 'missing_arkit_anchor_sidecar');
      expect(
        File('${depthDir.path}/metric_depth_alignment_spec.json').existsSync(),
        isTrue,
      );
    },
  );
}
