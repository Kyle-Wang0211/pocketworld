import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
  if (args.length != 2) {
    stderr.writeln(
      'usage: dart run tool/bcd_sparse_proposal_check.dart MANIFEST CAPTURE',
    );
    exitCode = 64;
    return;
  }
  final manifest = jsonDecode(File(args[0]).readAsStringSync()) as Map;
  final scene = (manifest['scenes'] as List).cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
  );
  final xyz = _readFloat32(scene['sparse_xyz_f32'] as String);
  final minimumCameraHeight = (scene['views'] as List)
      .cast<Map>()
      .map((view) => (view['camera_center'] as List)[1] as num)
      .map((value) => value.toDouble())
      .reduce((left, right) => left < right ? left : right);
  final floors = StructuralPlaneFit.proposeFloors(
    xyz: xyz,
    minimumCameraHeight: minimumCameraHeight,
  );
  final legacyFloor = StructuralPlaneFit.fitFloor(xyz: xyz);
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'capture': args[1],
      'minimum_camera_height': minimumCameraHeight,
      'legacy_floor': {
        'normal': legacyFloor.normal,
        'plane_value': legacyFloor.planeValue,
        'support': legacyFloor.supportPoints,
        'coverage': legacyFloor.coverageCells10cm,
        'rms': legacyFloor.rmsErrorM,
        'certified': legacyFloor.certified,
        'walls': [
          for (final wall in StructuralPlaneFit.fitWalls(
            xyz: xyz,
            floorNormal: legacyFloor.normal,
            floorValue: legacyFloor.planeValue,
          ))
            {
              'index': wall.index,
              'theta_deg': wall.thetaDeg,
              'normal': wall.normal,
              'plane_value': wall.planeValue,
              'support': wall.supportPoints35mm,
              'score': wall.score,
              'certified': wall.certified,
            },
        ],
      },
      'floors': [
        for (final floor in floors)
          {
            'index': floor.index,
            'normal': floor.normal,
            'plane_value': floor.planeValue,
            'basis_u': floor.basisU,
            'basis_v': floor.basisV,
            'bounds_u': floor.boundsU,
            'bounds_v': floor.boundsV,
            'support': floor.supportPoints20mm,
            'coverage': floor.coverageCells10cm,
            'walls': [
              for (final wall in StructuralPlaneFit.fitWalls(
                xyz: xyz,
                floorNormal: floor.normal,
                floorValue: floor.planeValue,
              ))
                {
                  'index': wall.index,
                  'theta_deg': wall.thetaDeg,
                  'normal': wall.normal,
                  'plane_value': wall.planeValue,
                  'bounds_u': wall.boundsU,
                  'bounds_height': wall.boundsHeight,
                  'support': wall.supportPoints35mm,
                  'score': wall.score,
                  'certified': wall.certified,
                  'support_prominence_vs_5cm': wall.supportProminenceVs5cm,
                  'coverage_prominence_vs_5cm': wall.coverageProminenceVs5cm,
                },
            ],
            'gravity_walls': [
              for (final wall in StructuralPlaneFit.fitWalls(
                xyz: xyz,
                floorNormal: const [0.0, 1.0, 0.0],
                floorValue: floor.planeValue,
              ))
                {
                  'index': wall.index,
                  'theta_deg': wall.thetaDeg,
                  'normal': wall.normal,
                  'plane_value': wall.planeValue,
                  'support': wall.supportPoints35mm,
                  'score': wall.score,
                  'certified': wall.certified,
                },
            ],
          },
      ],
    }),
  );
}
