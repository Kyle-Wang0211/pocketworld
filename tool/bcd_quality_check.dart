import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_structural_quality_runner.dart';

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

bool _sameStringSet(Object? rawExpected, List<String> actual) {
  if (rawExpected is! List || rawExpected.length != actual.length) {
    return false;
  }
  final expected = rawExpected.cast<String>().toSet();
  final observed = actual.toSet();
  return expected.length == rawExpected.length &&
      observed.length == actual.length &&
      expected.containsAll(observed);
}

int _pointCount(List<BcdStructuralBirthResult> births) =>
    births.fold<int>(0, (sum, birth) => sum + birth.cloud.pointCount);

List<int> _acceptedIndices(List<BcdStructuralBirthResult> births) => [
  for (final birth in births) ...birth.acceptedCandidateIndices,
];

Map<String, Object?> _summaryJson(BcdStructuralEvidenceSummary summary) => {
  'evaluated': summary.evaluated,
  'accepted': summary.accepted,
  'coverage_cells_5cm': summary.coverageCells5cm,
  'median_ncc': summary.medianNcc,
  'ncc_p10': summary.nccP10,
  'median_supporting_views': summary.medianSupportingViews,
  'median_parallax_deg': summary.medianParallaxDeg,
  'depth_margin_min': summary.depthMarginMin,
  'depth_margin_median': summary.depthMarginMedian,
};

Map<String, Object?> _wallJson(BcdWallCandidateMetrics row) => {
  'candidate_id': row.candidateId,
  'theta_deg': row.thetaDeg,
  'plane_value': row.planeValue,
  'sparse_score': row.sparseScore,
  'sparse_support_points': row.sparseSupportPoints,
  'accepted': row.accepted,
  'coverage_cells_5cm': row.coverageCells5cm,
  'median_ncc': row.medianNcc,
  'ncc_p10': row.nccP10,
  'incumbent': row.incumbent,
  'birth_support_point_count': (row.birthSupportXyz?.length ?? 0) ~/ 3,
  'birth_support_xyz': row.birthSupportXyz,
  'strict': row.strict == null
      ? null
      : {
          'eligible': row.strict!.eligible,
          'accepted': row.strict!.accepted,
          'coverage_cells_5cm': row.strict!.coverageCells5cm,
          'median_ncc': row.strict!.medianNcc,
          'ncc_p10': row.strict!.nccP10,
        },
};

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/bcd_quality_check.dart MANIFEST CAPTURE OUTPUT',
    );
    exitCode = 64;
    return;
  }
  final manifest = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final scenes = (manifest['scenes'] as List).cast<Map>();
  final scene = scenes.cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
    orElse: () => throw StateError('capture absent from manifest: ${args[1]}'),
  );
  final xyz = _readFloat32(scene['sparse_xyz_f32'] as String);
  final before = Float32List.fromList(xyz);
  final views = <BcdPlaneSweepView>[
    for (final raw in (scene['views'] as List).cast<Map>())
      BcdPlaneSweepView(
        jpegPath: raw['jpeg_path'] as String,
        projection3x4: Float64List.fromList(
          (raw['projection_3x4'] as List)
              .cast<num>()
              .map((v) => v.toDouble())
              .toList(),
        ),
        cameraCenter: Float64List.fromList(
          (raw['camera_center'] as List)
              .cast<num>()
              .map((v) => v.toDouble())
              .toList(),
        ),
        width: raw['width'] as int,
        height: raw['height'] as int,
      ),
  ];
  final rawKnownFloor = scene['known_floor'];
  final knownFloor = rawKnownFloor is Map
      ? BcdKnownFloorPlane.fromSignedDistanceMetadata(
          normal: (rawKnownFloor['plane_n'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
          rawPlaneD: (rawKnownFloor['plane_d'] as num).toDouble(),
          sparseXyz: xyz,
        )
      : null;
  final stopwatch = Stopwatch()..start();
  final result = const BcdStructuralQualityRunner().run(
    sparseXyz: xyz,
    registeredViews: views,
    knownFloorPlane: knownFloor,
    onProgress: (stage, completed, total) {
      stdout.writeln(
        'BCD_PROGRESS capture=${args[1]} stage=$stage $completed/$total '
        'elapsed_ms=${stopwatch.elapsedMilliseconds}',
      );
    },
  );
  stopwatch.stop();
  var originalUntouched = xyz.length == before.length;
  for (var index = 0; originalUntouched && index < xyz.length; index++) {
    originalUntouched = xyz[index] == before[index];
  }
  final floorPoints = _pointCount(result.floorBirths);
  final wallPoints = _pointCount(result.wallBirths);
  final structuralPoints = _pointCount(result.structuralBirths);
  final expected = scene['expected'] as Map;
  final expectedOwnersMatched =
      result.floorDecision.winnerProposalIndex ==
          expected['floor_winner_proposal_index'] &&
      _sameStringSet(
        expected['wall_selected_candidate_ids'],
        result.wallDecision?.selectedCandidateIds ?? const <String>[],
      );
  final expectedBirthCountMatched =
      floorPoints == expected['floor_births'] &&
      wallPoints == expected['wall_births'] &&
      structuralPoints == expected['structural_birth_points'];
  final output = <String, Object?>{
    'schema': 'pocketworld_dart_bcd_structural_quality_v1',
    'capture': args[1],
    'quality_passed': result.qualityPassed,
    'expected_owners_matched_exact': expectedOwnersMatched,
    'expected_birth_count_matched_exact': expectedBirthCountMatched,
    'rejected_reason': result.rejectedReason,
    'original_sparse_points': xyz.length ~/ 3,
    'original_sparse_untouched_exact': originalUntouched,
    'registered_views': views.length,
    'known_floor_plane': knownFloor == null
        ? null
        : {'normal': knownFloor.normal, 'plane_value': knownFloor.planeValue},
    'floor': {
      'decisive': result.floorDecision.decisive,
      'stage': result.floorDecision.stage.name,
      'winner_proposal_index': result.floorDecision.winnerProposalIndex,
      'plane_value': result.selectedFloor?.planeValue,
      'accepted_candidate_indices': _acceptedIndices(result.floorBirths),
      'coarse_summaries': {
        for (final entry in result.floorCoarseSummaries.entries)
          '${entry.key}': _summaryJson(entry.value),
      },
      'fine_summaries': {
        for (final entry in result.floorFineSummaries.entries)
          '${entry.key}': _summaryJson(entry.value),
      },
    },
    'walls': {
      'selected_candidate_ids':
          result.wallDecision?.selectedCandidateIds ?? const [],
      'required_strict_candidate_ids':
          result.wallDecision?.requiredStrictCandidateIds ?? const [],
      'unresolved_family_count': result.wallDecision?.unresolvedFamilyCount,
      'certified_count': result.certifiedWalls.length,
      'candidates': [for (final row in result.wallCandidates) _wallJson(row)],
      'plane_calibrations': [
        for (final calibration in result.wallPlaneCalibrations)
          {
            'wall_index': calibration.wallIndex,
            'certified': calibration.certified,
            'best_offset_m': calibration.bestOffsetM,
            'best_accepted': calibration.bestAccepted,
            'second_accepted': calibration.secondAccepted,
            'unique_count_peak': calibration.uniqueCountPeak,
            'sparse_agrees': calibration.sparseAgrees,
            'offsets': {
              for (final entry in calibration.summariesByOffsetM.entries)
                '${entry.key}': _summaryJson(entry.value),
            },
          },
      ],
      'accepted_candidate_indices': _acceptedIndices(result.wallBirths),
    },
    'birth_points': {
      'floor': floorPoints,
      'wall': wallPoints,
      'structural_total': structuralPoints,
    },
    'elapsed_ms': stopwatch.elapsedMilliseconds,
    'forbidden_inputs_consumed': {
      'learned_matcher': false,
      'lidar': false,
      'scene_depth': false,
    },
    'expected': expected,
  };
  File(args[2])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  stdout.writeln('BCD_RESULT=${jsonEncode(output)}');
  if (!result.qualityPassed ||
      !originalUntouched ||
      !expectedOwnersMatched ||
      !expectedBirthCountMatched) {
    exitCode = 1;
  }
}
