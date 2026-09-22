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

Map<String, Object?> _snapshot(BcdStructuralBirthResult result) => {
  'evaluated': result.evaluatedCandidateIndices,
  'accepted': result.acceptedCandidateIndices,
  'xyz_f32_bytes': base64Encode(result.cloud.xyz.buffer.asUint8List()),
  'rgb': base64Encode(result.cloud.rgb),
  'evidence': [
    for (final row in result.evidence)
      [
        row.accepted,
        row.supportingViews,
        row.medianNcc.toString(),
        row.maxParallaxDeg.toString(),
        row.observedDepthMargin.toString(),
      ],
  ],
};

void main(List<String> args) {
  if (args.length != 4) {
    stderr.writeln(
      'usage: dart run tool/bcd_shared_image_wave_check.dart '
      'FIXTURE JPEG_ROOT REPEATS OUTPUT',
    );
    exitCode = 64;
    return;
  }
  final fixture = Directory(args[0]);
  final jpegRoot = Directory(args[1]);
  final repeats = int.parse(args[2]);
  if (repeats < 2) throw ArgumentError('REPEATS must be at least two');
  final manifest =
      jsonDecode(
            File('${fixture.path}/fixture_manifest.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final rawFrames = (manifest['frames']! as List).cast<Map>();
  final views = <BcdPlaneSweepView>[];
  for (final raw in rawFrames) {
    final jpegPath = '${jpegRoot.path}/${raw['source_photo']}';
    final decoded = StructuralPlaneSweepImage.decodeJpeg(jpegPath);
    final projection = Float64List.fromList(
      (raw['projection_row_major_f32']! as List)
          .cast<num>()
          .map((value) => value.toDouble())
          .toList(),
    );
    final crop = (raw['crop_xyxy']! as List).cast<num>();
    for (var column = 0; column < 4; column++) {
      projection[column] += crop[0].toDouble() * projection[8 + column];
      projection[4 + column] += crop[1].toDouble() * projection[8 + column];
    }
    views.add(
      BcdPlaneSweepView(
        jpegPath: jpegPath,
        projection3x4: projection,
        cameraCenter: Float64List.fromList(
          (raw['camera_center_f32']! as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        width: decoded.width,
        height: decoded.height,
      ),
    );
    decoded.dispose();
  }
  final scales = (manifest['scales']! as List).cast<Map>();
  final pointCount = manifest['point_count']! as int;
  final viewCount = views.length;
  final masks = Uint8List(scales.length * pointCount * viewCount);
  final tables =
      (manifest['candidate_resource_frame_indices_by_scale']! as List)
          .cast<List>();
  for (var scale = 0; scale < scales.length; scale++) {
    final table = tables[scale];
    for (var point = 0; point < table.length; point++) {
      for (final view in (table[point] as List).cast<int>()) {
        masks[(scale * pointCount + point) * viewCount + view] = 1;
      }
    }
  }
  final batch = BcdPlaneSweepBatch(
    pointsXyz: _readFloat32('${fixture.path}/points.f32'),
    candidateCount: manifest['candidate_count']! as int,
    hypothesesPerCandidate: manifest['hypothesis_count']! as int,
    patchN: manifest['patch_n']! as int,
    basisU: (manifest['basis_u_f32']! as List)
        .cast<num>()
        .map((value) => value.toDouble())
        .toList(),
    basisV: (manifest['basis_v_f32']! as List)
        .cast<num>()
        .map((value) => value.toDouble())
        .toList(),
    views: views,
    patchRadiusMByScale: [
      for (final scale in scales) (scale['patch_radius_m']! as num).toDouble(),
    ],
    minimumStdU8ByScale: [
      for (final scale in scales) (scale['min_std_u8']! as num).toDouble(),
    ],
    candidateViewMasks: masks,
    birthOptionsByScale: [
      for (final scale in scales)
        PlaneSweepBirthOptions(
          minimumViews: scale['min_views']! as int,
          nccMin: (scale['ncc_min']! as num).toDouble(),
          minimumParallaxDeg: (scale['min_parallax_deg']! as num).toDouble(),
          uniqueDepthMargin: (scale['depth_ncc_margin']! as num).toDouble(),
          postMinNcc: (scale['post_min_ncc'] as num?)?.toDouble() ?? 0,
          postMinimumViews: scale['post_min_views'] as int? ?? 0,
          postMinimumParallaxDeg:
              (scale['post_min_parallax_deg'] as num?)?.toDouble() ?? 0,
        ),
    ],
    sourceCandidateIndices: List<int>.generate(
      manifest['candidate_count']! as int,
      (index) => index,
    ),
  );

  final oldWatch = Stopwatch()..start();
  final independent = [
    for (var index = 0; index < repeats; index++)
      BcdFinalizeCoordinator.runStructuralBatch(batch),
  ];
  oldWatch.stop();
  final newWatch = Stopwatch()..start();
  final shared = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
    List<BcdPlaneSweepBatch>.filled(repeats, batch),
  );
  newWatch.stop();
  final reference = jsonEncode(_snapshot(independent.first));
  final exact = [
    ...independent,
    ...shared,
  ].every((result) => jsonEncode(_snapshot(result)) == reference);
  final oldMs = oldWatch.elapsedMicroseconds / 1000.0;
  final newMs = newWatch.elapsedMicroseconds / 1000.0;
  final output = <String, Object?>{
    'schema': 'pocketworld_dart_shared_image_wave_check_v1',
    'decision': exact && newMs <= oldMs
        ? 'PASS_DART_EXACT_SHARED_IMAGE_WAVE_SPEED'
        : 'FAIL',
    'repeats': repeats,
    'accepted_candidates': independent.first.acceptedCandidateIndices.length,
    'all_results_ncc_rgb_exact': exact,
    'independent_ms': oldMs,
    'shared_image_wave_ms': newMs,
    'speedup_ratio': oldMs / newMs,
    'time_saved_percent': (oldMs - newMs) / oldMs * 100,
    'bounded_residency': 'one_decoded_and_one_gpu_image_at_a_time',
  };
  File(args[3])
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(output)}\n',
    );
  stdout.writeln(jsonEncode(output));
  if (output['decision'] != 'PASS_DART_EXACT_SHARED_IMAGE_WAVE_SPEED') {
    exitCode = 1;
  }
}
