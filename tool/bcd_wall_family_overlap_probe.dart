import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

const _epsilon = 1e-12;

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

double _dot(List<double> a, List<double> b) =>
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

List<double> _add(List<double> a, List<double> b) => [
  a[0] + b[0],
  a[1] + b[1],
  a[2] + b[2],
];

List<double> _subtract(List<double> a, List<double> b) => [
  a[0] - b[0],
  a[1] - b[1],
  a[2] - b[2],
];

List<double> _scale(List<double> vector, double scale) => [
  vector[0] * scale,
  vector[1] * scale,
  vector[2] * scale,
];

List<double> _cross(List<double> a, List<double> b) => [
  a[1] * b[2] - a[2] * b[1],
  a[2] * b[0] - a[0] * b[2],
  a[0] * b[1] - a[1] * b[0],
];

double _norm(List<double> vector) => math.sqrt(_dot(vector, vector));

List<double> _unit(List<double> vector) {
  final length = _norm(vector);
  if (!length.isFinite || length <= _epsilon) {
    throw StateError('wall candidate contains a degenerate basis vector');
  }
  return _scale(vector, 1 / length);
}

double _distance(List<double> a, List<double> b) => _norm(_subtract(a, b));

double _clamp(double value, double low, double high) =>
    math.max(low, math.min(high, value));

List<double> _solvePlaneCoordinates({
  required List<double> normal,
  required double planeValue,
  required List<double> basisU,
  required double u,
  required List<double> basisV,
  required double v,
}) {
  final bCrossV = _cross(basisU, basisV);
  final determinant = _dot(normal, bCrossV);
  if (!determinant.isFinite || determinant.abs() <= _epsilon) {
    throw StateError('wall candidate basis is singular');
  }
  return _scale(
    _add(
      _add(_scale(bCrossV, planeValue), _scale(_cross(basisV, normal), u)),
      _scale(_cross(normal, basisU), v),
    ),
    1 / determinant,
  );
}

class _WallRectangle {
  _WallRectangle({
    required this.id,
    required this.thetaDeg,
    required List<double> normal,
    required List<double> basisU,
    required List<double> basisV,
    required double planeValue,
    required List<double> boundsU,
    required List<double> boundsV,
    required this.source,
  }) : normal = _unit(normal),
       basisU = _unit(basisU),
       basisV = _unit(basisV),
       planeValue = planeValue / _norm(normal),
       boundsU = List<double>.unmodifiable(boundsU),
       boundsV = List<double>.unmodifiable(boundsV) {
    if (boundsU.length != 2 ||
        boundsV.length != 2 ||
        boundsU.any((value) => !value.isFinite) ||
        boundsV.any((value) => !value.isFinite) ||
        boundsU[0] > boundsU[1] ||
        boundsV[0] > boundsV[1] ||
        !this.planeValue.isFinite) {
      throw StateError('wall candidate contains invalid finite-domain bounds');
    }
  }

  final String id;
  final String source;
  final double thetaDeg;
  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final List<double> boundsU;
  final List<double> boundsV;

  late final List<List<double>> corners = List.unmodifiable([
    for (final v in boundsV)
      for (final u in boundsU)
        List<double>.unmodifiable(
          _solvePlaneCoordinates(
            normal: normal,
            planeValue: planeValue,
            basisU: basisU,
            u: u,
            basisV: basisV,
            v: v,
          ),
        ),
  ]);

  late final List<List<double>> edges = List.unmodifiable(
    [
      [0, 1],
      [1, 3],
      [3, 2],
      [2, 0],
    ].map(
      (indices) => <double>[...corners[indices[0]], ...corners[indices[1]]],
    ),
  );

  late final List<double> center = _solvePlaneCoordinates(
    normal: normal,
    planeValue: planeValue,
    basisU: basisU,
    u: (boundsU[0] + boundsU[1]) / 2,
    basisV: basisV,
    v: (boundsV[0] + boundsV[1]) / 2,
  );

  late final Map<String, List<double>> aabb = {
    'min': [
      for (var axis = 0; axis < 3; axis++)
        corners.map((point) => point[axis]).reduce(math.min),
    ],
    'max': [
      for (var axis = 0; axis < 3; axis++)
        corners.map((point) => point[axis]).reduce(math.max),
    ],
  };

  double signedPlaneDistance(List<double> point) =>
      _dot(normal, point) - planeValue;

  double pointDistance(List<double> point) {
    final signed = signedPlaneDistance(point);
    final projected = _subtract(point, _scale(normal, signed));
    final u = _clamp(_dot(basisU, projected), boundsU[0], boundsU[1]);
    final v = _clamp(_dot(basisV, projected), boundsV[0], boundsV[1]);
    final closest = _solvePlaneCoordinates(
      normal: normal,
      planeValue: planeValue,
      basisU: basisU,
      u: u,
      basisV: basisV,
      v: v,
    );
    return _distance(point, closest);
  }

  Map<String, Object?> toJson() => {
    'candidate_id': id,
    'source': source,
    'theta_deg': thetaDeg,
    'normal': normal,
    'plane_value': planeValue,
    'basis_u': basisU,
    'basis_v': basisV,
    'bounds_u_m': boundsU,
    'bounds_height_m': boundsV,
    'width_m': boundsU[1] - boundsU[0],
    'height_m': boundsV[1] - boundsV[0],
    'center_xyz': center,
    'corners_xyz': corners,
    'aabb_xyz': aabb,
  };
}

double _segmentDistance(List<double> packedA, List<double> packedB) {
  final p1 = packedA.sublist(0, 3);
  final q1 = packedA.sublist(3, 6);
  final p2 = packedB.sublist(0, 3);
  final q2 = packedB.sublist(3, 6);
  final d1 = _subtract(q1, p1);
  final d2 = _subtract(q2, p2);
  final r = _subtract(p1, p2);
  final a = _dot(d1, d1);
  final e = _dot(d2, d2);
  final f = _dot(d2, r);
  double s;
  double t;
  if (a <= _epsilon && e <= _epsilon) return _distance(p1, p2);
  if (a <= _epsilon) {
    s = 0;
    t = _clamp(f / e, 0, 1);
  } else {
    final c = _dot(d1, r);
    if (e <= _epsilon) {
      t = 0;
      s = _clamp(-c / a, 0, 1);
    } else {
      final b = _dot(d1, d2);
      final denominator = a * e - b * b;
      s = denominator.abs() > _epsilon
          ? _clamp((b * f - c * e) / denominator, 0, 1)
          : 0;
      t = (b * s + f) / e;
      if (t < 0) {
        t = 0;
        s = _clamp(-c / a, 0, 1);
      } else if (t > 1) {
        t = 1;
        s = _clamp((b - c) / a, 0, 1);
      }
    }
  }
  return _distance(_add(p1, _scale(d1, s)), _add(p2, _scale(d2, t)));
}

double _finiteRectangleDistance(_WallRectangle a, _WallRectangle b) {
  var best = double.infinity;
  for (final corner in a.corners) {
    best = math.min(best, b.pointDistance(corner));
  }
  for (final corner in b.corners) {
    best = math.min(best, a.pointDistance(corner));
  }
  for (final edgeA in a.edges) {
    for (final edgeB in b.edges) {
      best = math.min(best, _segmentDistance(edgeA, edgeB));
    }
  }
  return best;
}

Map<String, Object?> _intervalOverlap(
  List<double> reference,
  Iterable<double> projected,
) {
  final values = projected.toList(growable: false);
  final candidate = [values.reduce(math.min), values.reduce(math.max)];
  final overlap = math.max(
    0.0,
    math.min(reference[1], candidate[1]) - math.max(reference[0], candidate[0]),
  );
  final referenceLength = math.max(0.0, reference[1] - reference[0]);
  final candidateLength = math.max(0.0, candidate[1] - candidate[0]);
  final union = referenceLength + candidateLength - overlap;
  return {
    'reference_interval_m': reference,
    'projected_other_interval_m': candidate,
    'overlap_m': overlap,
    'reference_coverage_ratio': referenceLength > _epsilon
        ? overlap / referenceLength
        : 0.0,
    'other_coverage_ratio': candidateLength > _epsilon
        ? overlap / candidateLength
        : 0.0,
    'shorter_interval_coverage_ratio':
        math.min(referenceLength, candidateLength) > _epsilon
        ? overlap / math.min(referenceLength, candidateLength)
        : 0.0,
    'interval_iou': union > _epsilon ? overlap / union : 0.0,
  };
}

Map<String, Object?> _directedOverlap(
  _WallRectangle reference,
  _WallRectangle other,
) => {
  'reference_candidate_id': reference.id,
  'other_candidate_id': other.id,
  'horizontal_projection': _intervalOverlap(
    reference.boundsU,
    other.corners.map((point) => _dot(reference.basisU, point)),
  ),
  'height_projection': _intervalOverlap(
    reference.boundsV,
    other.corners.map((point) => _dot(reference.basisV, point)),
  ),
};

Map<String, Object?> _otherCornersToPlane(
  _WallRectangle plane,
  _WallRectangle other,
) {
  final signed = [
    for (final corner in other.corners) plane.signedPlaneDistance(corner),
  ];
  final absolute = [for (final value in signed) value.abs()];
  return {
    'plane_candidate_id': plane.id,
    'other_candidate_id': other.id,
    'signed_distance_m': signed,
    'absolute_distance_m': absolute,
    'minimum_absolute_distance_m': absolute.reduce(math.min),
    'maximum_absolute_distance_m': absolute.reduce(math.max),
    'mean_absolute_distance_m':
        absolute.reduce((left, right) => left + right) / absolute.length,
  };
}

_WallRectangle _legacyRectangle(StructuralWall wall, String id) =>
    _WallRectangle(
      id: id,
      source: 'legacy_sparse_fit',
      thetaDeg: wall.thetaDeg.toDouble(),
      normal: wall.normal,
      basisU: wall.basisU,
      basisV: wall.basisV,
      planeValue: wall.planeValue,
      boundsU: wall.boundsU,
      boundsV: wall.boundsHeight,
    );

_WallRectangle _envelopeRectangle(
  StructuralEnvelopeWallProposal wall,
  String id,
) => _WallRectangle(
  id: id,
  source: 'camera_envelope_proposal',
  thetaDeg: wall.thetaDeg,
  normal: wall.normal,
  basisU: wall.basisU,
  basisV: wall.basisV,
  planeValue: wall.planeValue,
  boundsU: wall.boundsU,
  boundsV: wall.boundsHeight,
);

String _fixturePath(String manifestPath, Object? rawPath) {
  if (rawPath is! String || rawPath.isEmpty) {
    throw FormatException('scene sparse_xyz_f32 is absent');
  }
  if (rawPath.startsWith('/')) return rawPath;
  return '${File(manifestPath).parent.path}/$rawPath';
}

bool _isCandidateId(String value) =>
    RegExp(r'^(legacy__wall_\d+|envelope__wall_envelope_\d+)$').hasMatch(value);

Object _jsonNumber(double value) {
  if (value.isFinite) return value;
  if (value.isNaN) return 'nan';
  return value.isNegative ? '-infinity' : 'infinity';
}

Map<String, Object?> _baseProbe({
  required String capture,
  required String candidateId,
  required int floorProposalIndex,
  required _WallRectangle geometry,
  required BcdStructuralSurfaceRequest request,
}) {
  final stopwatch = Stopwatch()..start();
  final batches = BcdFinalizeCoordinator.runStructuralBatchesSharedImages(
    BcdFinalizeCoordinator.prepareStructuralBatches(request),
  );
  stopwatch.stop();
  final accepted = <Map<String, Object?>>[];
  var evaluated = 0;
  for (final batch in batches) {
    if (batch.evaluatedCandidateIndices.length != batch.evidence.length ||
        batch.acceptedCandidateIndices.length != batch.cloud.pointCount) {
      throw StateError('base probe returned inconsistent batch dimensions');
    }
    evaluated += batch.evidence.length;
    var acceptedPosition = 0;
    for (var local = 0; local < batch.evidence.length; local++) {
      final evidence = batch.evidence[local];
      if (!evidence.accepted) continue;
      final gridIndex = batch.evaluatedCandidateIndices[local];
      if (acceptedPosition >= batch.acceptedCandidateIndices.length ||
          batch.acceptedCandidateIndices[acceptedPosition] != gridIndex) {
        throw StateError('base probe accepted-index mapping is inconsistent');
      }
      final xyzOffset = acceptedPosition * 3;
      accepted.add({
        'surface_grid_index': gridIndex,
        'xyz': [
          batch.cloud.xyz[xyzOffset],
          batch.cloud.xyz[xyzOffset + 1],
          batch.cloud.xyz[xyzOffset + 2],
        ],
        'rgb': [
          batch.cloud.rgb[xyzOffset],
          batch.cloud.rgb[xyzOffset + 1],
          batch.cloud.rgb[xyzOffset + 2],
        ],
        'supporting_views': evidence.supportingViews,
        'median_ncc': evidence.medianNcc,
        'maximum_parallax_deg': evidence.maxParallaxDeg,
        'observed_depth_margin': _jsonNumber(evidence.observedDepthMargin),
      });
      acceptedPosition++;
    }
    if (acceptedPosition != batch.acceptedCandidateIndices.length) {
      throw StateError('base probe accepted cloud is truncated');
    }
  }
  return {
    'schema': 'pocketworld_bcd_wall_candidate_base_probe_v1',
    'capture': capture,
    'candidate_id': candidateId,
    'floor_proposal_index': floorProposalIndex,
    'candidate': geometry.toJson(),
    'base_request': {
      'patch_n': request.patchN,
      'maximum_views': request.maximumViews,
      'patch_radius_m_by_scale': request.patchRadiusMByScale,
      'minimum_std_u8_by_scale': request.minimumStdU8ByScale,
      'depth_offsets_m': request.depthOffsetsM,
      'grid_m': request.grid.gridM,
    },
    'evaluated_count': evaluated,
    'accepted_count': accepted.length,
    'accepted': accepted,
    'elapsed_ms': stopwatch.elapsedMilliseconds,
  };
}

void _emitJson(Map<String, Object?> output, String? outputPath) {
  final encoded = '${const JsonEncoder.withIndent('  ').convert(output)}\n';
  if (outputPath != null) {
    File(outputPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(encoded);
  }
  stdout.write(encoded);
}

void main(List<String> args) {
  if (args.length < 3 || args.length > 5) {
    stderr.writeln(
      'usage: dart run tool/bcd_wall_family_overlap_probe.dart '
      'MANIFEST CAPTURE CANDIDATE_ID [OUTPUT_JSON]\n'
      '   or: dart run tool/bcd_wall_family_overlap_probe.dart '
      'MANIFEST CAPTURE CANDIDATE_A CANDIDATE_B [OUTPUT_JSON]',
    );
    exitCode = 64;
    return;
  }

  final manifestPath = args[0];
  final manifest = jsonDecode(File(manifestPath).readAsStringSync()) as Map;
  final scene = (manifest['scenes'] as List).cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
    orElse: () => throw StateError('capture absent from manifest: ${args[1]}'),
  );
  final xyz = _readFloat32(_fixturePath(manifestPath, scene['sparse_xyz_f32']));
  final rawViews = (scene['views'] as List).cast<Map>();
  if (rawViews.length < 3) {
    throw StateError('capture needs at least three registered camera views');
  }
  final frames = <BcdPlaneSweepView>[];
  final cameraCenters = Float64List(rawViews.length * 3);
  for (var index = 0; index < rawViews.length; index++) {
    final raw = rawViews[index];
    final center = (raw['camera_center'] as List).cast<num>();
    if (center.length != 3) {
      throw FormatException('camera_center must contain three values');
    }
    for (var axis = 0; axis < 3; axis++) {
      cameraCenters[index * 3 + axis] = center[axis].toDouble();
    }
    frames.add(
      BcdPlaneSweepView(
        jpegPath: raw['jpeg_path'] as String,
        projection3x4: Float64List.fromList(
          (raw['projection_3x4'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        cameraCenter: Float64List.fromList(
          center.map((value) => value.toDouble()).toList(),
        ),
        width: raw['width'] as int,
        height: raw['height'] as int,
      ),
    );
  }
  final minimumCameraHeight = [
    for (var index = 0; index < rawViews.length; index++)
      cameraCenters[index * 3 + 1],
  ].reduce(math.min);
  final floorIndex =
      (scene['expected'] as Map)['floor_winner_proposal_index'] as int;
  final floor =
      StructuralPlaneFit.proposeFloors(
        xyz: xyz,
        minimumCameraHeight: minimumCameraHeight,
      ).firstWhere(
        (proposal) => proposal.index == floorIndex,
        orElse: () => throw StateError('selected floor proposal is absent'),
      );
  final legacy = StructuralPlaneFit.fitWalls(
    xyz: xyz,
    floorNormal: floor.normal,
    floorValue: floor.planeValue,
  );
  final envelope = StructuralPlaneFit.proposeEnvelopeWalls(
    xyz: xyz,
    cameraCentersXyz: cameraCenters,
    floorNormal: floor.normal,
    floorValue: floor.planeValue,
  );
  final candidates = <String, _WallRectangle>{
    for (final wall in legacy)
      'legacy__wall_${wall.index}': _legacyRectangle(
        wall,
        'legacy__wall_${wall.index}',
      ),
    for (final wall in envelope)
      'envelope__wall_envelope_${wall.index}': _envelopeRectangle(
        wall,
        'envelope__wall_envelope_${wall.index}',
      ),
  };
  final a = candidates[args[2]];
  if (a == null) {
    throw StateError(
      'candidate absent; requested=${args[2]} '
      'available=${candidates.keys.join(',')}',
    );
  }
  final pairMode = args.length >= 4 && _isCandidateId(args[3]);
  if (!pairMode) {
    if (args.length > 4) {
      throw ArgumentError('single-candidate probe accepts at most one output');
    }
    final selectedFloor = StructuralFloorDomain(
      certified: true,
      normal: floor.normal,
      basisU: floor.basisU,
      basisV: floor.basisV,
      planeValue: floor.planeValue,
      boundsU: floor.boundsU,
      boundsV: floor.boundsV,
    );
    final legacyById = {
      for (final wall in legacy) 'legacy__wall_${wall.index}': wall,
    };
    final envelopeById = {
      for (final wall in envelope)
        'envelope__wall_envelope_${wall.index}': wall,
    };
    final legacyProposal = legacyById[args[2]];
    final envelopeProposal = envelopeById[args[2]];
    final request = legacyProposal != null
        ? BcdFinalizeCoordinator.legacyWallSurfaceRequest(
            proposal: legacyProposal,
            selectedFloor: selectedFloor,
            frames: frames,
          )
        : BcdFinalizeCoordinator.wallSurfaceRequest(
            proposal: envelopeProposal!,
            selectedFloor: selectedFloor,
            frames: frames,
          );
    _emitJson(
      _baseProbe(
        capture: args[1],
        candidateId: args[2],
        floorProposalIndex: floor.index,
        geometry: a,
        request: request,
      ),
      args.length == 4 ? args[3] : null,
    );
    return;
  }
  final b = candidates[args[3]];
  if (b == null) {
    throw StateError(
      'candidate absent; requested=${args[3]} '
      'available=${candidates.keys.join(',')}',
    );
  }
  final dot = _clamp(_dot(a.normal, b.normal), -1, 1);
  final alignedSign = dot < 0 ? -1.0 : 1.0;
  final acuteAngleDeg = math.acos(dot.abs()) * 180 / math.pi;
  final thetaDifference = (a.thetaDeg - b.thetaDeg).abs() % 180;
  final thetaDistanceDeg = math.min(thetaDifference, 180 - thetaDifference);
  final rawPlaneDifference = (a.planeValue - b.planeValue).abs();
  final alignedPlaneDifference = (a.planeValue - alignedSign * b.planeValue)
      .abs();
  final finiteDistance = _finiteRectangleDistance(a, b);
  final output = <String, Object?>{
    'schema': 'pocketworld_bcd_wall_family_overlap_probe_v1',
    'capture': args[1],
    'floor_proposal_index': floor.index,
    'candidate_generation': {
      'legacy_count': legacy.length,
      'envelope_count': envelope.length,
      'api': 'StructuralPlaneFit',
    },
    'candidate_a': a.toJson(),
    'candidate_b': b.toJson(),
    'pair': {
      'acute_normal_angle_deg': acuteAngleDeg,
      'theta_distance_deg': thetaDistanceDeg,
      'normal_dot': dot,
      'orientation_alignment_sign': alignedSign,
      'raw_plane_value_difference_m': rawPlaneDifference,
      'orientation_aligned_plane_value_difference_m': alignedPlaneDifference,
      'candidate_a_center_to_candidate_b_plane_m': b
          .signedPlaneDistance(a.center)
          .abs(),
      'candidate_b_center_to_candidate_a_plane_m': a
          .signedPlaneDistance(b.center)
          .abs(),
      'nearest_finite_domain_distance_m': finiteDistance,
      'candidate_b_corners_to_candidate_a_plane': _otherCornersToPlane(a, b),
      'candidate_a_corners_to_candidate_b_plane': _otherCornersToPlane(b, a),
      'candidate_b_projected_into_candidate_a': _directedOverlap(a, b),
      'candidate_a_projected_into_candidate_b': _directedOverlap(b, a),
      'current_family_gate': {
        'angle_limit_deg': 15.0,
        'plane_value_limit_m': 0.75,
        'passes_theta_distance': thetaDistanceDeg <= 15.0,
        'passes_raw_plane_value_difference': rawPlaneDifference <= 0.75,
        'would_merge_exact_current_policy':
            thetaDistanceDeg <= 15.0 && rawPlaneDifference <= 0.75,
      },
      'orientation_invariant_plane_diagnostic': {
        'passes_acute_normal_angle': acuteAngleDeg <= 15.0,
        'passes_aligned_plane_value_difference': alignedPlaneDifference <= 0.75,
        'would_merge': acuteAngleDeg <= 15.0 && alignedPlaneDifference <= 0.75,
      },
    },
  };
  _emitJson(output, args.length == 5 ? args[4] : null);
}
