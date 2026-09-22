import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

Float32List _readFloat32(String path) {
  final bytes = File(path).readAsBytesSync();
  if (bytes.length % 4 != 0) {
    throw FormatException('Float32 fixture byte count is not divisible by 4');
  }
  final data = ByteData.sublistView(bytes);
  return Float32List.fromList([
    for (var offset = 0; offset < bytes.length; offset += 4)
      data.getFloat32(offset, Endian.little),
  ]);
}

double? _finite(double value) => value.isFinite ? value : null;

Map<String, Object?> _evidenceJson(PlaneSweepCandidateResult evidence) => {
  'accepted': evidence.accepted,
  'supporting_views': evidence.supportingViews,
  'median_ncc': _finite(evidence.medianNcc),
  'parallax_deg': _finite(evidence.maxParallaxDeg),
  'observed_depth_margin': _finite(evidence.observedDepthMargin),
};

double _f32(double value) {
  final storage = Float32List(1)..[0] = value;
  return storage[0];
}

Map<String, Object?> _projectPatch({
  required BcdPlaneSweepBatch batch,
  required int pointIndex,
  required BcdPlaneSweepView view,
  required double radius,
  required bool quantizeInputs,
}) {
  double value(double input) => quantizeInputs ? _f32(input) : input;
  final p = [for (final input in view.projection3x4) value(input)];
  final center = [
    for (var axis = 0; axis < 3; axis++)
      value(batch.pointsXyz[pointIndex * 3 + axis]),
  ];
  final basisU = [for (final input in batch.basisU) value(input)];
  final basisV = [for (final input in batch.basisV) value(input)];
  final xs = <double>[];
  final ys = <double>[];
  final zs = <double>[];
  var inside = true;
  for (var uIndex = 0; uIndex < batch.patchN; uIndex++) {
    final u = batch.patchN == 1
        ? 0.0
        : -radius + 2 * radius * uIndex / (batch.patchN - 1);
    for (var vIndex = 0; vIndex < batch.patchN; vIndex++) {
      final v = batch.patchN == 1
          ? 0.0
          : -radius + 2 * radius * vIndex / (batch.patchN - 1);
      final world = [
        for (var axis = 0; axis < 3; axis++)
          center[axis] + basisU[axis] * value(u) + basisV[axis] * value(v),
      ];
      final q0 = p[0] * world[0] + p[1] * world[1] + p[2] * world[2] + p[3];
      final q1 = p[4] * world[0] + p[5] * world[1] + p[6] * world[2] + p[7];
      final q2 = p[8] * world[0] + p[9] * world[1] + p[10] * world[2] + p[11];
      final x = q0 / q2;
      final y = q1 / q2;
      xs.add(x);
      ys.add(y);
      zs.add(q2);
      if (q2 <= 0.05 ||
          x < 0 ||
          y < 0 ||
          x > view.width - 1 ||
          y > view.height - 1) {
        inside = false;
      }
    }
  }
  double minimum(List<double> values) =>
      values.reduce((left, right) => left < right ? left : right);
  double maximum(List<double> values) =>
      values.reduce((left, right) => left > right ? left : right);
  return {
    'inside': inside,
    'x_min': minimum(xs),
    'x_max': maximum(xs),
    'y_min': minimum(ys),
    'y_max': maximum(ys),
    'z_min': minimum(zs),
    'z_max': maximum(zs),
  };
}

Map<String, Object?> _batchDiagnostic({
  required BcdPlaneSweepBatch batch,
  required int sourceCandidateIndex,
  required Map<String, int> frameIdByPath,
}) {
  final local = batch.sourceCandidateIndices.indexOf(sourceCandidateIndex);
  if (local < 0) {
    throw StateError('target candidate is not in diagnostic batch');
  }
  final centerPoint = local * batch.hypothesesPerCandidate;
  final viewCount = batch.views.length;
  final pointCount = batch.candidateCount * batch.hypothesesPerCandidate;
  return {
    'source_candidate_indices': batch.sourceCandidateIndices,
    'local_candidate_index': local,
    'center_point_xyz': [
      for (var axis = 0; axis < 3; axis++)
        batch.pointsXyz[centerPoint * 3 + axis],
    ],
    'hypothesis_points_xyz': [
      for (
        var hypothesis = 0;
        hypothesis < batch.hypothesesPerCandidate;
        hypothesis++
      )
        [
          for (var axis = 0; axis < 3; axis++)
            batch.pointsXyz[(centerPoint + hypothesis) * 3 + axis],
        ],
    ],
    'patch_n': batch.patchN,
    'patch_radius_m_by_scale': batch.patchRadiusMByScale,
    'minimum_std_u8_by_scale': batch.minimumStdU8ByScale,
    'basis_u': batch.basisU,
    'basis_v': batch.basisV,
    'views': [
      for (var viewIndex = 0; viewIndex < viewCount; viewIndex++)
        {
          'batch_view_index': viewIndex,
          'frame_id': frameIdByPath[batch.views[viewIndex].jpegPath],
          'jpeg_path': batch.views[viewIndex].jpegPath,
          'center_masks_by_scale': [
            for (
              var scale = 0;
              scale < batch.birthOptionsByScale.length;
              scale++
            )
              batch.candidateViewMasks[scale * pointCount * viewCount +
                  centerPoint * viewCount +
                  viewIndex],
          ],
          'hypothesis_masks_scale0': [
            for (
              var hypothesis = 0;
              hypothesis < batch.hypothesesPerCandidate;
              hypothesis++
            )
              batch.candidateViewMasks[(local * batch.hypothesesPerCandidate +
                          hypothesis) *
                      viewCount +
                  viewIndex],
          ],
          'projection_f64': _projectPatch(
            batch: batch,
            pointIndex: centerPoint,
            view: batch.views[viewIndex],
            radius: batch.patchRadiusMByScale.first,
            quantizeInputs: false,
          ),
          'projection_f32_inputs': _projectPatch(
            batch: batch,
            pointIndex: centerPoint,
            view: batch.views[viewIndex],
            radius: batch.patchRadiusMByScale.first,
            quantizeInputs: true,
          ),
        },
    ],
  };
}

({BcdStructuralBirthResult result, Map<String, Object?> shader})
_runBatchWithShaderReadback({
  required BcdPlaneSweepBatch batch,
  required int sourceCandidateIndex,
  required Map<String, int> frameIdByPath,
}) {
  final session = StructuralPlaneSweepSession.create(
    pointsXyz: batch.pointsXyz,
    candidateCount: batch.candidateCount,
    hypothesesPerCandidate: batch.hypothesesPerCandidate,
    patchN: batch.patchN,
    maxViews: batch.views.length,
    scaleCount: batch.birthOptionsByScale.length,
    basisU: batch.basisU,
    basisV: batch.basisV,
  );
  try {
    for (var viewIndex = 0; viewIndex < batch.views.length; viewIndex++) {
      final view = batch.views[viewIndex];
      session.addJpegViewAllScales(
        viewIndex: viewIndex,
        jpegPath: view.jpegPath,
        projection3x4: Float32List.fromList(view.projection3x4),
        cameraCenter: Float32List.fromList(view.cameraCenter),
        patchRadiusMByScale: batch.patchRadiusMByScale,
        minimumStdU8ByScale: batch.minimumStdU8ByScale,
      );
    }
    final readback = session.debugReadback();
    final finish = session.finishWithRgb(
      candidateViewMasks: batch.candidateViewMasks,
      scales: batch.birthOptionsByScale,
    );
    final localResult = BcdFinalizeCoordinator.assembleStructuralBirths(
      pointsXyz: batch.pointsXyz,
      hypothesesPerCandidate: batch.hypothesesPerCandidate,
      finish: finish,
    );
    final result = BcdStructuralBirthResult(
      cloud: localResult.cloud,
      evaluatedCandidateIndices: List.unmodifiable(
        batch.sourceCandidateIndices,
      ),
      acceptedCandidateIndices: List.unmodifiable([
        for (final index in localResult.acceptedCandidateIndices)
          batch.sourceCandidateIndices[index],
      ]),
      evidence: localResult.evidence,
    );
    final local = batch.sourceCandidateIndices.indexOf(sourceCandidateIndex);
    final centerPoint = local * batch.hypothesesPerCandidate;
    final pointCount = batch.candidateCount * batch.hypothesesPerCandidate;
    final sampleCount = batch.patchN * batch.patchN;
    final scales = <Map<String, Object?>>[];
    for (var scale = 0; scale < batch.birthOptionsByScale.length; scale++) {
      final viewRows = <Map<String, Object?>>[];
      for (var view = 0; view < batch.views.length; view++) {
        final slot = scale * batch.views.length + view;
        final centerValueIndex = slot * pointCount + centerPoint;
        final patchOffset = centerValueIndex * sampleCount;
        viewRows.add({
          'batch_view_index': view,
          'frame_id': frameIdByPath[batch.views[view].jpegPath],
          'center_valid': readback.valid[centerValueIndex],
          'center_stddev_u8': readback.stddevU8[centerValueIndex],
          'center_normalized_patch': readback.normalized.sublist(
            patchOffset,
            patchOffset + sampleCount,
          ),
          'hypotheses': [
            for (
              var hypothesis = 0;
              hypothesis < batch.hypothesesPerCandidate;
              hypothesis++
            )
              {
                'hypothesis': hypothesis,
                'valid': readback
                    .valid[slot * pointCount + centerPoint + hypothesis],
                'stddev_u8': readback
                    .stddevU8[slot * pointCount + centerPoint + hypothesis],
                'normalized_patch': readback.normalized.sublist(
                  (slot * pointCount + centerPoint + hypothesis) * sampleCount,
                  (slot * pointCount + centerPoint + hypothesis + 1) *
                      sampleCount,
                ),
              },
          ],
        });
      }
      final pairwise = <Map<String, Object?>>[];
      for (var left = 0; left < viewRows.length; left++) {
        if (viewRows[left]['center_valid'] != 1) continue;
        final leftPatch = viewRows[left]['center_normalized_patch']! as List;
        for (var right = left + 1; right < viewRows.length; right++) {
          if (viewRows[right]['center_valid'] != 1) continue;
          final rightPatch =
              viewRows[right]['center_normalized_patch']! as List;
          var dot = 0.0;
          for (var sample = 0; sample < sampleCount; sample++) {
            dot +=
                (leftPatch[sample] as num).toDouble() *
                (rightPatch[sample] as num).toDouble();
          }
          pairwise.add({
            'frame_ids': [
              viewRows[left]['frame_id'],
              viewRows[right]['frame_id'],
            ],
            'ncc': dot,
          });
        }
      }
      scales.add({
        'scale_index': scale,
        'views': viewRows,
        'pairwise_ncc': pairwise,
      });
    }
    return (result: result, shader: {'scales': scales});
  } finally {
    session.dispose();
  }
}

void main(List<String> args) {
  if (args.length != 6 && args.length != 7) {
    stderr.writeln(
      'usage: dart run tool/bcd_boundary_diagnostic.dart '
      'MANIFEST CAPTURE FLOOR_GRID_INDEX WALL_ENVELOPE_INDEX '
      'WALL_GRID_INDEX OUTPUT [FLOOR_GRID_M]',
    );
    exitCode = 64;
    return;
  }
  final manifest = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final scene = (manifest['scenes'] as List).cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
  );
  final targetFloorGridIndex = int.parse(args[2]);
  final targetWallIndex = int.parse(args[3]);
  final targetWallGridIndex = int.parse(args[4]);
  final floorGridM = args.length == 7 ? double.parse(args[6]) : 0.10;
  final xyz = _readFloat32(scene['sparse_xyz_f32'] as String);
  final views = <BcdPlaneSweepView>[
    for (final raw in (scene['views'] as List).cast<Map>())
      BcdPlaneSweepView(
        jpegPath: raw['jpeg_path'] as String,
        projection3x4: Float64List.fromList(
          (raw['projection_3x4'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        cameraCenter: Float64List.fromList(
          (raw['camera_center'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        width: raw['width'] as int,
        height: raw['height'] as int,
      ),
  ];
  final frameIdByPath = {
    for (final raw in (scene['views'] as List).cast<Map>())
      raw['jpeg_path'] as String: raw['frame_id'] as int,
  };
  final minimumCameraHeight = views
      .map((view) => view.cameraCenter[1])
      .reduce((left, right) => left < right ? left : right);
  final expected = scene['expected'] as Map;
  final floorProposalIndex = expected['floor_winner_proposal_index'] as int;
  final floorProposal = StructuralPlaneFit.proposeFloors(
    xyz: xyz,
    minimumCameraHeight: minimumCameraHeight,
  ).singleWhere((proposal) => proposal.index == floorProposalIndex);
  final floorRequest = BcdFinalizeCoordinator.floorSurfaceRequest(
    proposal: floorProposal,
    frames: views,
    gridM: floorGridM,
  );
  final floorBatch =
      BcdFinalizeCoordinator.prepareStructuralBatches(floorRequest).singleWhere(
        (batch) => batch.sourceCandidateIndices.contains(targetFloorGridIndex),
      );
  final floorExecution = _runBatchWithShaderReadback(
    batch: floorBatch,
    sourceCandidateIndex: targetFloorGridIndex,
    frameIdByPath: frameIdByPath,
  );
  final floorResult = floorExecution.result;
  final floorLocal = floorResult.evaluatedCandidateIndices.indexOf(
    targetFloorGridIndex,
  );

  final selectedFloor = StructuralFloorDomain(
    certified: true,
    normal: floorProposal.normal,
    basisU: floorProposal.basisU,
    basisV: floorProposal.basisV,
    planeValue: floorProposal.planeValue,
    boundsU: floorProposal.boundsU,
    boundsV: floorProposal.boundsV,
  );
  final cameraCenters = Float64List(views.length * 3);
  for (var index = 0; index < views.length; index++) {
    cameraCenters.setRange(index * 3, index * 3 + 3, views[index].cameraCenter);
  }
  final wallProposal = StructuralPlaneFit.proposeEnvelopeWalls(
    xyz: xyz,
    cameraCentersXyz: cameraCenters,
    floorNormal: selectedFloor.normal,
    floorValue: selectedFloor.planeValue,
  ).singleWhere((proposal) => proposal.index == targetWallIndex);
  final wallRequest = BcdFinalizeCoordinator.wallSurfaceRequest(
    proposal: wallProposal,
    selectedFloor: selectedFloor,
    frames: views,
  );
  final wallBatch = BcdFinalizeCoordinator.prepareStructuralBatches(wallRequest)
      .singleWhere(
        (batch) => batch.sourceCandidateIndices.contains(targetWallGridIndex),
      );
  final wallExecution = _runBatchWithShaderReadback(
    batch: wallBatch,
    sourceCandidateIndex: targetWallGridIndex,
    frameIdByPath: frameIdByPath,
  );
  final wallResult = wallExecution.result;
  final wallLocal = wallResult.evaluatedCandidateIndices.indexOf(
    targetWallGridIndex,
  );
  final output = <String, Object?>{
    'schema': 'pocketworld_bcd_boundary_diagnostic_v1',
    'capture': args[1],
    'floor': {
      'proposal_index': floorProposalIndex,
      'target_grid_index': targetFloorGridIndex,
      'batch_candidate_indices': floorResult.evaluatedCandidateIndices,
      'target_evidence': _evidenceJson(floorResult.evidence[floorLocal]),
      'batch_diagnostic': _batchDiagnostic(
        batch: floorBatch,
        sourceCandidateIndex: targetFloorGridIndex,
        frameIdByPath: frameIdByPath,
      ),
      'shader_readback': floorExecution.shader,
    },
    'wall': {
      'envelope_index': targetWallIndex,
      'target_grid_index': targetWallGridIndex,
      'target_evidence': _evidenceJson(wallResult.evidence[wallLocal]),
      'batch_diagnostic': _batchDiagnostic(
        batch: wallBatch,
        sourceCandidateIndex: targetWallGridIndex,
        frameIdByPath: frameIdByPath,
      ),
      'shader_readback': wallExecution.shader,
    },
  };
  File(args[5])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  stdout.writeln(
    'BCD_BOUNDARY_RESULT capture=${args[1]} '
    'floor_${targetFloorGridIndex}_accepted='
    '${floorResult.evidence[floorLocal].accepted} '
    'wall_${targetWallIndex}_${targetWallGridIndex}_accepted='
    '${wallResult.evidence[wallLocal].accepted}',
  );
}
