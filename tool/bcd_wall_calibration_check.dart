import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/structural_candidate_ffi.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

Float32List _readFloat32(String path) {
  final bytes = File(path).readAsBytesSync();
  final data = ByteData.sublistView(bytes);
  return Float32List.fromList([
    for (var offset = 0; offset < bytes.length; offset += 4)
      data.getFloat32(offset, Endian.little),
  ]);
}

void main(List<String> args) {
  if (args.length != 5) {
    stderr.writeln(
      'usage: dart run tool/bcd_wall_calibration_check.dart '
      'MANIFEST CAPTURE FLOOR_INDEX WALL_INDEX OUTPUT',
    );
    exitCode = 64;
    return;
  }
  final manifest = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final scene = (manifest['scenes'] as List).cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
  );
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
  final minimumCameraHeight = views
      .map((view) => view.cameraCenter[1])
      .reduce(math.min);
  final floor = StructuralPlaneFit.proposeFloors(
    xyz: xyz,
    minimumCameraHeight: minimumCameraHeight,
  ).firstWhere((proposal) => proposal.index == int.parse(args[2]));
  final wall = StructuralPlaneFit.fitWalls(
    xyz: xyz,
    floorNormal: floor.normal,
    floorValue: floor.planeValue,
  ).firstWhere((proposal) => proposal.index == int.parse(args[3]));
  const offsets = <double>[-0.10, -0.06, -0.05, -0.04, 0, 0.05, 0.10];
  final rows = <Map<String, Object?>>[];
  final stopwatch = Stopwatch()..start();
  for (final offset in offsets) {
    final request = BcdStructuralSurfaceRequest(
      grid: StructuralCandidateGridSpec(
        normal: wall.normal,
        basisU: wall.basisU,
        basisV: floor.normal,
        planeValue: wall.planeValue + offset,
        basisVOriginValue: floor.planeValue,
        boundsU: wall.boundsU,
        boundsV: wall.boundsHeight,
        gridM: 0.20,
      ),
      depthOffsetsM: const [0],
      tilePoints: 64,
      viewMode: StructuralViewMode.perTile,
      maximumViews: math.min(10, views.length),
      patchN: 9,
      frames: views,
      patchRadiusMByScale: const [0.03],
      minimumStdU8ByScale: const [6],
      birthOptionsByScale: const [
        PlaneSweepBirthOptions(
          minimumViews: 4,
          nccMin: 0.80,
          minimumParallaxDeg: 10,
          uniqueDepthMargin: 0,
        ),
      ],
    );
    final births = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
      BcdFinalizeCoordinator.prepareStructuralBatches(request),
    );
    final summary = BcdFinalizeCoordinator.aggregateStructuralEvidence(
      batches: births,
      basisU: wall.basisU,
      basisV: floor.normal,
    );
    rows.add({
      'offset_m': offset,
      'accepted': summary.accepted,
      'coverage_cells_5cm': summary.coverageCells5cm,
      'median_ncc': summary.medianNcc,
      'ncc_p10': summary.nccP10,
      'elapsed_ms': stopwatch.elapsedMilliseconds,
    });
  }
  stopwatch.stop();
  final ranked = List<Map<String, Object?>>.of(rows)
    ..sort(
      (left, right) =>
          (right['accepted'] as int).compareTo(left['accepted'] as int),
    );
  final output = {
    'capture': args[1],
    'source_floor_index': floor.index,
    'source_wall_index': wall.index,
    'source_theta_deg': wall.thetaDeg,
    'source_plane_value': wall.planeValue,
    'rows': rows,
    'best_offset_m': ranked.first['offset_m'],
    'best_accepted': ranked.first['accepted'],
    'second_accepted': ranked[1]['accepted'],
    'elapsed_ms': stopwatch.elapsedMilliseconds,
  };
  File(args[4])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  stdout.writeln(jsonEncode(output));
}
