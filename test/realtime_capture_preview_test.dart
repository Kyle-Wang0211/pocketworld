import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/realtime_capture_preview.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('preview model voxelizes AR preview points and advances phases', () {
    final model = RealtimeCapturePreviewModel();
    final pose = ARPose(
      position: Vector3.zero(),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 1,
      hasOrigin: true,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[],
      intrinsicFxFyCxCy: const <double>[],
      previewPoints: [
        ARPreviewPoint(
          position: Vector3(0.10, 0.02, -0.50),
          r: 100,
          g: 120,
          b: 140,
          confidence: 0.8,
        ),
        ARPreviewPoint(
          position: Vector3(0.105, 0.02, -0.50),
          r: 120,
          g: 140,
          b: 160,
          confidence: 0.9,
        ),
      ],
    );

    model.updateFromPose(pose, photoCount: 0);
    expect(model.phase, CapturePreviewPhase.veryRoughPreview);
    expect(model.voxels, hasLength(1));
    expect(model.voxels.single.observations, 2);

    model.updateFromPose(pose, photoCount: 8);
    expect(model.phase, CapturePreviewPhase.initializingAlignment);

    model.updateFromPose(pose, photoCount: 24);
    expect(model.phase, CapturePreviewPhase.qualityPointCloud);
    expect(model.voxels.single.quality, greaterThan(0));
  });
}
