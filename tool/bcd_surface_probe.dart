import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
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
  if (args.length < 4 || args.length > 6) {
    stderr.writeln(
      'usage: dart run tool/bcd_surface_probe.dart '
      'MANIFEST CAPTURE ENVELOPE_INDEX|floor OUTPUT '
      '[MINIMUM_STD_U8] [FLOOR_GRID_M]',
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
      .reduce((left, right) => left < right ? left : right);
  final floor =
      StructuralPlaneFit.proposeFloors(
        xyz: xyz,
        minimumCameraHeight: minimumCameraHeight,
      ).firstWhere(
        (proposal) =>
            proposal.index ==
            (scene['expected'] as Map)['floor_winner_proposal_index'],
      );
  final selectedFloor = StructuralFloorDomain(
    certified: true,
    normal: floor.normal,
    basisU: floor.basisU,
    basisV: floor.basisV,
    planeValue: floor.planeValue,
    boundsU: floor.boundsU,
    boundsV: floor.boundsV,
  );
  if (args[2] == 'floor') {
    final gridM = args.length == 6 ? double.parse(args[5]) : 0.10;
    final baseRequest = BcdFinalizeCoordinator.floorSurfaceRequest(
      proposal: floor,
      frames: views,
      gridM: gridM,
    );
    final minimumStd = args.length >= 5 ? double.parse(args[4]) : 6.0;
    final request = BcdStructuralSurfaceRequest(
      grid: baseRequest.grid,
      depthOffsetsM: baseRequest.depthOffsetsM,
      tilePoints: baseRequest.tilePoints,
      viewMode: baseRequest.viewMode,
      maximumViews: baseRequest.maximumViews,
      patchN: baseRequest.patchN,
      frames: baseRequest.frames,
      patchRadiusMByScale: baseRequest.patchRadiusMByScale,
      minimumStdU8ByScale: [minimumStd],
      birthOptionsByScale: baseRequest.birthOptionsByScale,
      imageMarginPx: baseRequest.imageMarginPx,
      maximumGrazeDeg: baseRequest.maximumGrazeDeg,
    );
    final births = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
      BcdFinalizeCoordinator.prepareStructuralBatches(request),
    );
    final accepted = <Map<String, Object?>>[];
    for (final birth in births) {
      for (var local = 0; local < birth.evidence.length; local++) {
        final evidence = birth.evidence[local];
        if (!evidence.accepted) continue;
        accepted.add({
          'surface_grid_index': birth.evaluatedCandidateIndices[local],
          'views': evidence.supportingViews,
          'ncc': evidence.medianNcc,
          'parallax_deg': evidence.maxParallaxDeg,
          'depth_margin': evidence.observedDepthMargin.isFinite
              ? evidence.observedDepthMargin
              : 'infinity',
        });
      }
    }
    final output = {
      'capture': args[1],
      'surface_id': 'floor_proposal_${floor.index}',
      'minimum_std_u8': minimumStd,
      'accepted': accepted,
    };
    File(args[3])
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(output)}\n',
      );
    stdout.writeln(jsonEncode(output));
    return;
  }
  final cameras = Float64List(views.length * 3);
  for (var index = 0; index < views.length; index++) {
    cameras.setRange(index * 3, index * 3 + 3, views[index].cameraCenter);
  }
  final proposal = StructuralPlaneFit.proposeEnvelopeWalls(
    xyz: xyz,
    cameraCentersXyz: cameras,
    floorNormal: selectedFloor.normal,
    floorValue: selectedFloor.planeValue,
  ).firstWhere((proposal) => proposal.index == int.parse(args[2]));
  final request = BcdFinalizeCoordinator.wallSurfaceRequest(
    proposal: proposal,
    selectedFloor: selectedFloor,
    frames: views,
  );
  final births = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
    BcdFinalizeCoordinator.prepareStructuralBatches(request),
  );
  final accepted = <Map<String, Object?>>[];
  for (final birth in births) {
    for (var local = 0; local < birth.evidence.length; local++) {
      final evidence = birth.evidence[local];
      if (!evidence.accepted) continue;
      accepted.add({
        'surface_grid_index': birth.evaluatedCandidateIndices[local],
        'views': evidence.supportingViews,
        'ncc': evidence.medianNcc,
        'parallax_deg': evidence.maxParallaxDeg,
        'depth_margin': evidence.observedDepthMargin.isFinite
            ? evidence.observedDepthMargin
            : 'infinity',
      });
    }
  }
  final output = {
    'capture': args[1],
    'surface_id': 'envelope__wall_envelope_${proposal.index}',
    'accepted': accepted,
  };
  File(args[3])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  stdout.writeln(jsonEncode(output));
}
