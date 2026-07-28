import 'dart:math' as math;

typedef RelativeFileExists = bool Function(String relativePath);

/// Shared, platform-neutral service for Aether photo bundles.
///
/// Native capture adapters should write high-res photos and pose metadata.
/// Flutter/Dart owns dimension-independent validation and pose-only view graph
/// generation so iOS, Android, and other mobile shells use the same contract.
final class PhotoBundleService {
  const PhotoBundleService();

  Map<String, Object?> buildViewGraph(
    Map<String, Object?> manifest, {
    int maxNeighborsPerNode = 8,
  }) {
    final frames = _frames(manifest);
    final nodes = frames.map(_nodeFromFrame).toList(growable: false);
    final candidates = <_EdgeCandidate>[];

    for (var i = 0; i < frames.length - 1; i += 1) {
      for (var j = i + 1; j < frames.length; j += 1) {
        final edge = _makeEdge(frames[i], frames[j]);
        if (edge != null) {
          candidates.add(_EdgeCandidate(i, j, edge));
        }
      }
    }

    candidates.sort((a, b) {
      final scoreA = _asDouble(a.edge['score']);
      final scoreB = _asDouble(b.edge['score']);
      return scoreB.compareTo(scoreA);
    });

    final degree = List<int>.filled(frames.length, 0);
    final edges = <Map<String, Object?>>[];
    for (final candidate in candidates) {
      if (degree[candidate.sourceIndex] >= maxNeighborsPerNode ||
          degree[candidate.targetIndex] >= maxNeighborsPerNode) {
        continue;
      }
      edges.add(candidate.edge);
      degree[candidate.sourceIndex] += 1;
      degree[candidate.targetIndex] += 1;
    }

    final summary = _summary(
      frames.map((frame) => _asString(frame['id'])).toList(growable: false),
      edges,
    );

    return {
      'schemaVersion': 'aether_view_graph_v1',
      'graphKind': 'pose_quality_proxy_v1',
      'sourceManifest': 'official_photo_bundle.json',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'nodeCount': nodes.length,
      'edgeCount': edges.length,
      'maxNeighborsPerNode': maxNeighborsPerNode,
      'featureMatchStatus': 'not_computed_on_mobile_pose_only_graph',
      'nodes': nodes,
      'edges': edges,
      'summary': summary,
    };
  }

  String colmapSparseDir(Map<String, Object?> manifest) {
    return _asString(manifest['colmapSparseDir'], fallback: 'colmap/sparse/0');
  }

  Map<String, String> buildColmapTextSidecar(Map<String, Object?> manifest) {
    final frames = _frames(manifest);
    final photosHighresDir = _asString(
      manifest['photosHighresDir'],
      fallback: 'photos_highres',
    );
    final cameras = <String>[
      '# Camera list with one line of data per camera:',
      '# CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]',
    ];
    final images = <String>[
      '# Image list with two lines of data per image:',
      '# IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME',
      '# POINTS2D[] as (X, Y, POINT3D_ID)',
    ];
    const points3D = [
      '# 3D point list with one line of data per point:',
      '# POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)',
      '# Number of points: 0, mean track length: 0',
    ];

    var sidecarFrameCount = 0;
    for (var offset = 0; offset < frames.length; offset += 1) {
      final frame = frames[offset];
      final imageID = offset + 1;
      final cameraID = imageID;
      final intrinsics = _asNumList(frame['intrinsics']);
      final transform = _asNumList(frame['cameraTransform']);
      final imageWidth = _asInt(frame['imageWidth']);
      final imageHeight = _asInt(frame['imageHeight']);
      if (intrinsics.length < 4 ||
          transform.length != 16 ||
          intrinsics.take(4).any((value) => !value.isFinite) ||
          imageWidth <= 0 ||
          imageHeight <= 0) {
        continue;
      }

      cameras.add([
        '$cameraID',
        'PINHOLE',
        '$imageWidth',
        '$imageHeight',
        _formatColmapNumber(intrinsics[0]),
        _formatColmapNumber(intrinsics[1]),
        _formatColmapNumber(intrinsics[2]),
        _formatColmapNumber(intrinsics[3]),
      ].join(' '));

      final pose = _colmapPose(fromCameraToWorld: transform);
      if (pose == null) {
        continue;
      }
      sidecarFrameCount += 1;
      final imageName =
          '$photosHighresDir/${_asString(frame['highresFilename'])}';
      images.add([
        '$imageID',
        _formatColmapNumber(pose.qw),
        _formatColmapNumber(pose.qx),
        _formatColmapNumber(pose.qy),
        _formatColmapNumber(pose.qz),
        _formatColmapNumber(pose.tx),
        _formatColmapNumber(pose.ty),
        _formatColmapNumber(pose.tz),
        '$cameraID',
        imageName,
      ].join(' '));
      images.add('');
    }

    cameras.insert(2, '# Number of cameras: $sidecarFrameCount');
    images.insert(
      3,
      '# Number of images: $sidecarFrameCount, mean observations per image: 0',
    );

    return {
      'cameras.txt': '${cameras.join('\n')}\n',
      'images.txt': '${images.join('\n')}\n',
      'points3D.txt': '${points3D.join('\n')}\n',
    };
  }

  Map<String, Object?> validateBundle(
    Map<String, Object?> manifest, {
    Map<String, Object?>? viewGraph,
    RelativeFileExists? fileExists,
  }) {
    final frames = _frames(manifest);
    final checks = <Map<String, Object?>>[];
    final errors = <String>[];
    final warnings = <String>[];

    void addCheck(
      String id,
      bool passed,
      String message, {
      bool warningOnly = false,
    }) {
      checks.add({
        'id': id,
        'status': passed ? 'pass' : (warningOnly ? 'warn' : 'fail'),
        'message': message,
      });
      if (!passed) {
        if (warningOnly) {
          warnings.add(message);
        } else {
          errors.add(message);
        }
      }
    }

    final schema = _asString(manifest['schemaVersion']);
    addCheck(
      'schema',
      schema == 'aether_photo_bundle_v1',
      'unexpected schemaVersion: $schema',
    );

    final photosHighresDir = _asString(
      manifest['photosHighresDir'],
      fallback: 'photos_highres',
    );
    final previewsDir = _asString(manifest['previewsDir']);
    final hasPreviewContract = previewsDir.isNotEmpty;
    final colmapSparseDir = _asString(
      manifest['colmapSparseDir'],
      fallback: 'colmap/sparse/0',
    );

    var duplicateIDCount = 0;
    var invalidPoseCount = 0;
    var invalidIntrinsicsCount = 0;
    var invalidImageSizeCount = 0;
    var principalPointWarningCount = 0;
    var missingHighresCount = 0;
    var missingPreviewCount = 0;
    final seenIDs = <String>{};

    for (final frame in frames) {
      final id = _asString(frame['id']);
      if (!seenIDs.add(id)) {
        duplicateIDCount += 1;
      }

      final width = _asInt(frame['imageWidth']);
      final height = _asInt(frame['imageHeight']);
      if (width <= 0 || height <= 0) {
        invalidImageSizeCount += 1;
      }

      final transform = _asNumList(frame['cameraTransform']);
      if (transform.length != 16 || transform.any((value) => !value.isFinite)) {
        invalidPoseCount += 1;
      }

      final intrinsics = _asNumList(frame['intrinsics']);
      if (intrinsics.length < 4 ||
          intrinsics[0] <= 0 ||
          intrinsics[1] <= 0 ||
          intrinsics.take(4).any((value) => !value.isFinite)) {
        invalidIntrinsicsCount += 1;
      } else if (width > 0 && height > 0) {
        final maxImageAxis = math.max(width, height).toDouble();
        if (intrinsics[2] < 0 ||
            intrinsics[2] > maxImageAxis ||
            intrinsics[3] < 0 ||
            intrinsics[3] > maxImageAxis) {
          principalPointWarningCount += 1;
        }
      }

      if (fileExists != null) {
        final highresFilename = _asString(frame['highresFilename']);
        if (!fileExists('$photosHighresDir/$highresFilename')) {
          missingHighresCount += 1;
        }
        if (hasPreviewContract) {
          final previewFilename = _asString(frame['previewFilename']);
          if (previewFilename.isEmpty ||
              !fileExists('$previewsDir/$previewFilename')) {
            missingPreviewCount += 1;
          }
        }
      }
    }

    addCheck(
      'frame_ids',
      duplicateIDCount == 0,
      'duplicate frame ids: $duplicateIDCount',
    );
    addCheck(
      'image_sizes',
      invalidImageSizeCount == 0,
      'invalid image sizes: $invalidImageSizeCount',
    );
    addCheck(
      'poses',
      invalidPoseCount == 0,
      'invalid camera transforms: $invalidPoseCount',
    );
    addCheck(
      'intrinsics',
      invalidIntrinsicsCount == 0,
      'invalid intrinsics: $invalidIntrinsicsCount',
    );
    addCheck(
      'principal_points',
      principalPointWarningCount == 0,
      'principal points outside image bounds: $principalPointWarningCount',
      warningOnly: true,
    );

    if (fileExists == null) {
      checks.add({
        'id': 'file_presence',
        'status': 'skipped',
        'message': 'file presence callback was not provided',
      });
    } else {
      addCheck(
        'highres_files',
        missingHighresCount == 0,
        'missing highres files: $missingHighresCount',
      );
      if (hasPreviewContract) {
        addCheck(
          'preview_files',
          missingPreviewCount == 0,
          'missing preview files: $missingPreviewCount',
        );
      }
      for (final filename in ['cameras.txt', 'images.txt', 'points3D.txt']) {
        addCheck(
          'colmap_$filename',
          fileExists('$colmapSparseDir/$filename'),
          'missing COLMAP sidecar: $filename',
        );
      }
    }

    final graph = viewGraph ?? buildViewGraph(manifest);
    final nodeCount = _asInt(graph['nodeCount']);
    final edgeCount = _asInt(graph['edgeCount']);
    addCheck(
      'view_graph_nodes',
      nodeCount == frames.length,
      'view graph node count mismatch: $nodeCount vs ${frames.length}',
    );
    addCheck(
      'view_graph_edges',
      frames.length < 2 || edgeCount > 0,
      'view graph has no edges for ${frames.length} frames',
      warningOnly: true,
    );

    final summary = graph['summary'];
    if (summary is Map) {
      final isolated = _asInt(summary['isolatedNodeCount']);
      if (isolated > 0) {
        warnings.add('view graph isolated nodes: $isolated');
      }
    }

    final status =
        errors.isNotEmpty ? 'fail' : (warnings.isNotEmpty ? 'warn' : 'pass');
    return {
      'schemaVersion': 'aether_bundle_validation_v1',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'status': status,
      'frameCount': frames.length,
      'rejectedStillCount': _asInt(manifest['rejectedStillCount']),
      'filePresenceMode': fileExists == null ? 'skipped' : 'checked',
      'checks': checks,
      'errors': errors,
      'warnings': warnings,
    };
  }

  static List<Map<String, Object?>> _frames(Map<String, Object?> manifest) {
    final frames = manifest['frames'];
    if (frames is! List) {
      return const [];
    }
    return frames
        .whereType<Map>()
        .map((frame) => frame.cast<String, Object?>())
        .toList(growable: false);
  }

  static Map<String, Object?> _nodeFromFrame(Map<String, Object?> frame) {
    final quality = _asMap(frame['quality']);
    return {
      'id': _asString(frame['id']),
      'highresFilename': _asString(frame['highresFilename']),
      'timestamp': _asDouble(frame['timestamp']),
      'azimuthDeg': _asDouble(frame['azimuth']) * 180 / math.pi,
      'elevationDeg': _asDouble(frame['elevation']) * 180 / math.pi,
      'cameraRadiusM': _asDouble(frame['cameraRadiusM']),
      'radiusShellID': _asString(frame['radiusShellID']),
      'qualityScore': _asDouble(quality['score']),
      'viewGraphWeight': _qualityWeight(quality, 'viewGraphWeight'),
      'kWindowWeight': _qualityWeight(quality, 'kWindowWeight'),
      'textureBestViewWeight': _qualityWeight(quality, 'textureBestViewWeight'),
      'laplacianVariance': _asDouble(quality['laplacianVariance']),
      'tenengradMean': _asDouble(quality['tenengradMean']),
      'localContrast': _asDouble(quality['localContrast']),
      'saturationRatio': _asDouble(quality['saturationRatio']),
      'centerRoiLaplacianVariance':
          _asDouble(quality['centerRoiLaplacianVariance']),
      'imageWidth': _asInt(frame['imageWidth']),
      'imageHeight': _asInt(frame['imageHeight']),
    };
  }

  static Map<String, Object?>? _makeEdge(
    Map<String, Object?> source,
    Map<String, Object?> target,
  ) {
    final sourceCenter = _cameraCenter(source['cameraTransform']);
    final targetCenter = _cameraCenter(target['cameraTransform']);
    if (sourceCenter == null || targetCenter == null) {
      return null;
    }

    final angularGapDeg = _angularGapDegrees(
      _asDouble(source['azimuth']),
      _asDouble(source['elevation']),
      _asDouble(target['azimuth']),
      _asDouble(target['elevation']),
    );
    final baselineM = _distance(sourceCenter, targetCenter);
    if (!angularGapDeg.isFinite || !baselineM.isFinite) {
      return null;
    }

    final sourceRadius = _asDouble(source['cameraRadiusM']);
    final targetRadius = _asDouble(target['cameraRadiusM']);
    final maxRadius = math.max(math.max(sourceRadius, targetRadius), 0.0001);
    final radiusRatio = (sourceRadius - targetRadius).abs() / maxRadius;
    final sameRadiusShell = _asString(source['radiusShellID']) ==
            _asString(target['radiusShellID']) ||
        radiusRatio <= 0.25;
    final temporalGapSec =
        (_asDouble(target['timestamp']) - _asDouble(source['timestamp'])).abs();
    final radiusScore = _clamp01(1 - radiusRatio / 0.60);
    final overlapProxy = _clamp01((80 - angularGapDeg) / 80) * radiusScore;
    final angleScore = angularGapDeg < 3
        ? angularGapDeg / 3 * 0.25
        : (angularGapDeg <= 24 ? 1.0 : _clamp01(1 - (angularGapDeg - 24) / 60));
    final baselineScore = baselineM < 0.03
        ? baselineM / 0.03 * 0.35
        : (baselineM <= 0.55 ? 1.0 : _clamp01(1 - (baselineM - 0.55) / 1.45));
    final qualityScore = 0.5 *
        (_qualityWeight(_asMap(source['quality']), 'viewGraphWeight') +
            _qualityWeight(_asMap(target['quality']), 'viewGraphWeight'));
    final score = _clamp01(
      0.30 * overlapProxy +
          0.25 * angleScore +
          0.20 * baselineScore +
          0.15 * radiusScore +
          0.10 * qualityScore,
    );

    if (angularGapDeg < 2 ||
        angularGapDeg > 85 ||
        baselineM < 0.015 ||
        radiusRatio > 0.65 ||
        score < 0.25) {
      return null;
    }

    final reasons = <String>[
      angularGapDeg <= 35 ? 'nearby_view_angle' : 'wide_view_support',
      sameRadiusShell ? 'same_radius_shell' : 'nearby_radius_shell',
      if (baselineM >= 0.03) 'usable_pose_baseline',
      if (overlapProxy >= 0.35) 'overlap_proxy',
    ];

    return {
      'sourceID': _asString(source['id']),
      'targetID': _asString(target['id']),
      'score': score,
      'angularGapDeg': angularGapDeg,
      'baselineM': baselineM,
      'radiusRatio': radiusRatio,
      'temporalGapSec': temporalGapSec,
      'overlapProxy': overlapProxy,
      'sameRadiusShell': sameRadiusShell,
      'supportKind': 'pose_quality_proxy',
      'reasons': reasons,
    };
  }

  static Map<String, Object?> _summary(
    List<String> nodeIDs,
    List<Map<String, Object?>> edges,
  ) {
    if (nodeIDs.isEmpty) {
      return {
        'connectedNodeCount': 0,
        'isolatedNodeCount': 0,
        'componentCount': 0,
        'averageDegree': 0.0,
        'warnings': ['empty_view_graph'],
      };
    }

    final indexByID = <String, int>{
      for (var i = 0; i < nodeIDs.length; i += 1) nodeIDs[i]: i,
    };
    final adjacency = List.generate(nodeIDs.length, (_) => <int>[]);
    for (final edge in edges) {
      final a = indexByID[_asString(edge['sourceID'])];
      final b = indexByID[_asString(edge['targetID'])];
      if (a == null || b == null) {
        continue;
      }
      adjacency[a].add(b);
      adjacency[b].add(a);
    }

    final connectedNodeCount =
        adjacency.where((neighbors) => neighbors.isNotEmpty).length;
    final isolatedNodeCount = nodeIDs.length - connectedNodeCount;
    final visited = List<bool>.filled(nodeIDs.length, false);
    var componentCount = 0;

    for (var i = 0; i < nodeIDs.length; i += 1) {
      if (visited[i]) {
        continue;
      }
      componentCount += 1;
      final stack = <int>[i];
      visited[i] = true;
      while (stack.isNotEmpty) {
        final current = stack.removeLast();
        for (final next in adjacency[current]) {
          if (!visited[next]) {
            visited[next] = true;
            stack.add(next);
          }
        }
      }
    }

    final warnings = <String>[
      if (nodeIDs.length >= 2 && edges.isEmpty) 'no_pose_supported_edges',
      if (isolatedNodeCount > 0) 'isolated_nodes:$isolatedNodeCount',
      if (componentCount > 1) 'disconnected_components:$componentCount',
    ];

    return {
      'connectedNodeCount': connectedNodeCount,
      'isolatedNodeCount': isolatedNodeCount,
      'componentCount': componentCount,
      'averageDegree': edges.length * 2 / math.max(1, nodeIDs.length),
      'warnings': warnings,
    };
  }

  static List<double>? _cameraCenter(Object? value) {
    final values = _asNumList(value);
    if (values.length != 16 || values.any((entry) => !entry.isFinite)) {
      return null;
    }
    return [values[12], values[13], values[14]];
  }

  static _ColmapPose? _colmapPose({required List<double> fromCameraToWorld}) {
    final values = fromCameraToWorld;
    if (values.length != 16 || values.any((entry) => !entry.isFinite)) {
      return null;
    }

    final rW2C = [
      [values[0], values[1], values[2]],
      [values[4], values[5], values[6]],
      [values[8], values[9], values[10]],
    ];
    final center = [values[12], values[13], values[14]];
    final tW2C = [
      -(rW2C[0][0] * center[0] +
          rW2C[0][1] * center[1] +
          rW2C[0][2] * center[2]),
      -(rW2C[1][0] * center[0] +
          rW2C[1][1] * center[1] +
          rW2C[1][2] * center[2]),
      -(rW2C[2][0] * center[0] +
          rW2C[2][1] * center[1] +
          rW2C[2][2] * center[2]),
    ];

    final rOpenCV = [
      rW2C[0],
      [-rW2C[1][0], -rW2C[1][1], -rW2C[1][2]],
      [-rW2C[2][0], -rW2C[2][1], -rW2C[2][2]],
    ];
    final tOpenCV = [tW2C[0], -tW2C[1], -tW2C[2]];
    final q = _quaternionWxyzFromRotation(rOpenCV);
    return _ColmapPose(
      qw: q[0],
      qx: q[1],
      qy: q[2],
      qz: q[3],
      tx: tOpenCV[0],
      ty: tOpenCV[1],
      tz: tOpenCV[2],
    );
  }

  static List<double> _quaternionWxyzFromRotation(List<List<double>> r) {
    final m00 = r[0][0];
    final m01 = r[0][1];
    final m02 = r[0][2];
    final m10 = r[1][0];
    final m11 = r[1][1];
    final m12 = r[1][2];
    final m20 = r[2][0];
    final m21 = r[2][1];
    final m22 = r[2][2];

    double qw;
    double qx;
    double qy;
    double qz;
    final trace = m00 + m11 + m22;
    if (trace > 0) {
      final s = math.sqrt(trace + 1) * 2;
      qw = 0.25 * s;
      qx = (m21 - m12) / s;
      qy = (m02 - m20) / s;
      qz = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
      final s = math.sqrt(1 + m00 - m11 - m22) * 2;
      qw = (m21 - m12) / s;
      qx = 0.25 * s;
      qy = (m01 + m10) / s;
      qz = (m02 + m20) / s;
    } else if (m11 > m22) {
      final s = math.sqrt(1 + m11 - m00 - m22) * 2;
      qw = (m02 - m20) / s;
      qx = (m01 + m10) / s;
      qy = 0.25 * s;
      qz = (m12 + m21) / s;
    } else {
      final s = math.sqrt(1 + m22 - m00 - m11) * 2;
      qw = (m10 - m01) / s;
      qx = (m02 + m20) / s;
      qy = (m12 + m21) / s;
      qz = 0.25 * s;
    }

    final norm = math.max(
      0.000001,
      math.sqrt(qw * qw + qx * qx + qy * qy + qz * qz),
    );
    final sign = qw < 0 ? -1.0 : 1.0;
    return [
      sign * qw / norm,
      sign * qx / norm,
      sign * qy / norm,
      sign * qz / norm,
    ];
  }

  static double _angularGapDegrees(
    double azimuthA,
    double elevationA,
    double azimuthB,
    double elevationB,
  ) {
    final a = _directionVector(azimuthA, elevationA);
    final b = _directionVector(azimuthB, elevationB);
    final dot = _clamp(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1, 1);
    return math.acos(dot) * 180 / math.pi;
  }

  static List<double> _directionVector(double azimuth, double elevation) {
    final cosElevation = math.cos(elevation);
    return [
      cosElevation * math.cos(azimuth),
      math.sin(elevation),
      cosElevation * math.sin(azimuth),
    ];
  }

  static double _distance(List<double> a, List<double> b) {
    final dx = a[0] - b[0];
    final dy = a[1] - b[1];
    final dz = a[2] - b[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  static Map<String, Object?> _asMap(Object? value) {
    if (value is Map) {
      return value.cast<String, Object?>();
    }
    return const {};
  }

  static List<double> _asNumList(Object? value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<num>()
        .map((entry) => entry.toDouble())
        .toList(growable: false);
  }

  static String _asString(Object? value, {String fallback = ''}) {
    if (value is String) {
      return value;
    }
    return fallback;
  }

  static int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return 0;
  }

  static double _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return 0;
  }

  static double _clamp01(double value) => _clamp(value, 0, 1);

  static double _qualityWeight(Map<String, Object?> quality, String key) {
    final direct = _asDouble(quality[key]);
    if (direct > 0) return direct;
    final downstream = _asMap(quality['downstreamWeights']);
    final nestedKey = switch (key) {
      'viewGraphWeight' => 'viewGraph',
      'kWindowWeight' => 'kWindow',
      'textureBestViewWeight' => 'textureBestView',
      _ => key,
    };
    final nested = _asDouble(downstream[nestedKey]);
    if (nested > 0) return nested;
    return _asDouble(quality['score']);
  }

  static String _formatColmapNumber(double value) {
    return value.toStringAsPrecision(9);
  }

  static double _clamp(double value, double lower, double upper) {
    return math.min(upper, math.max(lower, value));
  }
}

final class _EdgeCandidate {
  const _EdgeCandidate(this.sourceIndex, this.targetIndex, this.edge);

  final int sourceIndex;
  final int targetIndex;
  final Map<String, Object?> edge;
}

final class _ColmapPose {
  const _ColmapPose({
    required this.qw,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.tx,
    required this.ty,
    required this.tz,
  });

  final double qw;
  final double qx;
  final double qy;
  final double qz;
  final double tx;
  final double ty;
  final double tz;
}
