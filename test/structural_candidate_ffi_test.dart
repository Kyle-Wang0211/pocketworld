import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/structural_candidate_ffi.dart';

void main() {
  StructuralCandidateFrame frame(double cameraX) {
    return StructuralCandidateFrame(
      projection3x4: Float64List.fromList([
        100,
        0,
        50,
        -100 * cameraX,
        0,
        100,
        50,
        0,
        0,
        0,
        1,
        0,
      ]),
      cameraCenter: Float64List.fromList([cameraX, 0, 0]),
      width: 100,
      height: 100,
    );
  }

  test('shared C builds u-major grid with center hypothesis first', () {
    final grid = StructuralCandidatePreparation.buildGrid(
      spec: const StructuralCandidateGridSpec(
        normal: [0, 0, 1],
        basisU: [1, 0, 0],
        basisV: [0, 1, 0],
        planeValue: 2,
        basisVOriginValue: 0,
        boundsU: [-0.1, 0.1],
        boundsV: [0, 0.1],
        gridM: 0.1,
      ),
      depthOffsetsM: const [0, -0.05, 0.05],
    );

    expect(grid.candidateCount, 6);
    expect(grid.hypothesesPerCandidate, 3);
    expect(grid.centersXyz.take(9), [-0.1, 0, 2, -0.1, 0.1, 2, 0, 0, 2]);
    expect(grid.pointsXyz.take(9), [-0.1, 0, 2, -0.1, 0, 1.95, -0.1, 0, 2.05]);
  });

  test('shared C returns deterministic per-point view plan and visibility', () {
    final grid = StructuralCandidatePreparation.buildGrid(
      spec: const StructuralCandidateGridSpec(
        normal: [0, 0, 1],
        basisU: [1, 0, 0],
        basisV: [0, 1, 0],
        planeValue: 2,
        basisVOriginValue: 0,
        boundsU: [0, 0],
        boundsV: [0, 0],
        gridM: 0.1,
      ),
      depthOffsetsM: const [0, 0.05],
    );
    final result = StructuralCandidatePreparation.prepareViews(
      grid: grid,
      frames: [frame(-0.2), frame(0.2), frame(0)],
      normal: const [0, 0, 1],
      maximumViews: 2,
      mode: StructuralViewMode.perPoint,
    );

    expect(result.hypothesisVisibility, everyElement(1));
    expect(result.selectedViewIndices, [
      [2, 0],
    ]);
  });

  test('Dart rejects a competing-depth list without center zero', () {
    expect(
      () => StructuralCandidatePreparation.buildGrid(
        spec: const StructuralCandidateGridSpec(
          normal: [0, 0, 1],
          basisU: [1, 0, 0],
          basisV: [0, 1, 0],
          planeValue: 2,
          basisVOriginValue: 0,
          boundsU: [0, 0],
          boundsV: [0, 0],
          gridM: 0.1,
        ),
        depthOffsetsM: const [0.05],
      ),
      throwsArgumentError,
    );
  });
}
