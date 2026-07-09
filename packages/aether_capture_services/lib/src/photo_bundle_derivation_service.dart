import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as image;

import 'photo_bundle_pipeline_policy_service.dart';
import 'photo_bundle_service.dart';

final class PhotoBundleDerivationResult {
  const PhotoBundleDerivationResult({
    required this.bundleDirectory,
    required this.status,
    required this.frameCount,
    required this.edgeCount,
    required this.colmapFrameCount,
    required this.writtenRelativePaths,
  });

  final Directory bundleDirectory;
  final String status;
  final int frameCount;
  final int edgeCount;
  final int colmapFrameCount;
  final List<String> writtenRelativePaths;
}

final class PhotoBundleDerivationService {
  const PhotoBundleDerivationService({
    this.photoBundleService = const PhotoBundleService(),
    this.policyService = const PhotoBundlePipelinePolicyService(),
  });

  final PhotoBundleService photoBundleService;
  final PhotoBundlePipelinePolicyService policyService;

  Future<PhotoBundleDerivationResult> deriveDirectory(
    Directory bundleDirectory, {
    int? targetBridgeOverlap,
  }) async {
    final manifestFile = File(_join(bundleDirectory.path, 'photo_bundle.json'));
    if (!manifestFile.existsSync()) {
      throw FileSystemException(
        'missing photo_bundle.json',
        manifestFile.path,
      );
    }

    final manifestJson = jsonDecode(await manifestFile.readAsString());
    if (manifestJson is! Map) {
      throw const FormatException('photo_bundle.json is not a JSON object');
    }
    var manifest = manifestJson.cast<String, Object?>();

    final written = <String>[];
    final repairReport = await _repairManifestAssets(
      bundleDirectory: bundleDirectory,
      manifest: manifest,
    );
    if (_asBool(repairReport['changed'])) {
      manifest = repairReport['manifest']! as Map<String, Object?>;
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
        flush: true,
      );
      await File(
        _join(bundleDirectory.path, 'photo_bundle_repair_report.json'),
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          ...repairReport,
          'manifest': null,
        }..remove('manifest')),
        flush: true,
      );
      written.add('photo_bundle.json');
      written.add('photo_bundle_repair_report.json');
    }

    final colmapSidecar = photoBundleService.buildColmapTextSidecar(manifest);
    final colmapRelativeDir = photoBundleService.colmapSparseDir(manifest);
    final colmapDir = Directory(_join(bundleDirectory.path, colmapRelativeDir));
    colmapDir.createSync(recursive: true);
    for (final entry in colmapSidecar.entries) {
      await File(_join(colmapDir.path, entry.key)).writeAsString(entry.value);
      written.add('$colmapRelativeDir/${entry.key}');
    }

    final viewGraph = photoBundleService.buildViewGraph(manifest);
    final validation = photoBundleService.validateBundle(
      manifest,
      viewGraph: viewGraph,
      fileExists: (relativePath) =>
          File(_join(bundleDirectory.path, relativePath)).existsSync(),
    );

    await File(_join(bundleDirectory.path, 'view_graph.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(viewGraph),
    );
    written.add('view_graph.json');

    await File(
      _join(bundleDirectory.path, 'bundle_validation.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(validation));
    written.add('bundle_validation.json');

    final sparseAudit = await _deriveArkitSparsePointCloudAudit(
      bundleDirectory: bundleDirectory,
      manifest: manifest,
    );
    written.addAll(sparseAudit);

    final tier = _asString(manifest['processingTier'], fallback: 'high');

    // DA3 depth sidecars (model_policy.json / da3_k_windows.json /
    // da3_input_manifest.json + per-frame depth JPEGs) were retired with the
    // on-device DA3 mesh pipeline. Reconstruction is streaming SfM + server
    // recon; the server derives its own depth. Only the COLMAP / view-graph /
    // texture / transport sidecars below remain.

    final preflight = policyService.buildPreflightPlan(manifest, viewGraph);
    await File(
      _join(bundleDirectory.path, 'pointcloud_preflight_plan.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(preflight));
    written.add('pointcloud_preflight_plan.json');

    final texture = policyService.buildTexturePlan(
      manifest,
      viewGraph,
      tier: tier,
    );
    await File(_join(bundleDirectory.path, 'texture_plan.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(texture),
    );
    written.add('texture_plan.json');

    final transport = policyService.buildTransportManifest(manifest);
    await File(
      _join(bundleDirectory.path, 'bundle_transport.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(transport));
    written.add('bundle_transport.json');

    final policyBundle = policyService.buildPolicyBundle(
      manifest,
      viewGraph,
      tier: tier,
    );
    await File(
      _join(bundleDirectory.path, 'local_policy_bundle.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(policyBundle));
    written.add('local_policy_bundle.json');

    return PhotoBundleDerivationResult(
      bundleDirectory: bundleDirectory,
      status: _asString(validation['status'], fallback: 'unknown'),
      frameCount: _asInt(validation['frameCount']),
      edgeCount: _asInt(viewGraph['edgeCount']),
      colmapFrameCount: _colmapFrameCount(colmapSidecar['images.txt'] ?? ''),
      writtenRelativePaths: List.unmodifiable(written),
    );
  }

  static int _colmapFrameCount(String imagesText) {
    var count = 0;
    for (final line in const LineSplitter().convert(imagesText)) {
      if (line.isEmpty || line.startsWith('#')) continue;
      final first = line.split(' ').firstOrNull;
      if (first != null && int.tryParse(first) != null) {
        count += 1;
      }
    }
    return count;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static String _asString(Object? value, {required String fallback}) {
    if (value is String && value.isNotEmpty) return value;
    return fallback;
  }
}

Future<Map<String, Object?>> _repairManifestAssets({
  required Directory bundleDirectory,
  required Map<String, Object?> manifest,
}) async {
  final photosHighresDir = _asString(
    manifest['photosHighresDir'],
    fallback: 'photos_highres',
  );
  final previewsDir = _asString(
    manifest['previewsDir'],
    fallback: 'previews',
  );
  final frames = _frames(manifest);
  var changed = false;
  var repairedImageSizeCount = 0;
  var generatedPreviewCount = 0;
  var repairedMetadataCount = 0;
  final repairedFrameIDs = <String>[];
  final generatedPreviewFrameIDs = <String>[];
  final repairedMetadataFrameIDs = <String>[];
  final repairedFrames = <Map<String, Object?>>[];
  final previewDir = Directory(_join(bundleDirectory.path, previewsDir));
  previewDir.createSync(recursive: true);

  for (var i = 0; i < frames.length; i += 1) {
    final frame = Map<String, Object?>.from(frames[i]);
    final id = _asString(
      frame['id'],
      fallback: 'frame_${i.toString().padLeft(4, '0')}',
    );
    final highresFilename = _asString(
      frame['highresFilename'],
      fallback: '$id.jpg',
    );
    final previewFilename = _asString(
      frame['previewFilename'],
      fallback: highresFilename,
    );
    final highresFile = File(
      _join(bundleDirectory.path, '$photosHighresDir/$highresFilename'),
    );
    final metadataFile = File(
      _join(
        bundleDirectory.path,
        '$photosHighresDir/${_stripExtension(highresFilename)}.json',
      ),
    );
    final previewFile = File(
      _join(bundleDirectory.path, '$previewsDir/$previewFilename'),
    );
    final metadata = await _readSidecarMetadata(metadataFile);
    var metadataChanged = false;
    final sidecarTimestamp = _asDouble(metadata['t']);
    if (_asDouble(frame['timestamp']) < 100000 && sidecarTimestamp > 100000) {
      frame['timestamp'] = sidecarTimestamp;
      frame['captureKind'] = 'arkit_frame_fallback_jpeg';
      frame['poseSyncQuality'] = 'nearest_ar_frame_snapshot';
      metadataChanged = true;
    }
    if (_asInt(frame['imageWidth']) <= 0 && _asInt(metadata['image_w']) > 0) {
      frame['imageWidth'] = _asInt(metadata['image_w']);
      metadataChanged = true;
    }
    if (_asInt(frame['imageHeight']) <= 0 && _asInt(metadata['image_h']) > 0) {
      frame['imageHeight'] = _asInt(metadata['image_h']);
      metadataChanged = true;
    }
    if (_asDoubleList(frame['cameraTransform']).length != 16 &&
        _asDoubleList(metadata['extrinsic']).length == 16) {
      frame['cameraTransform'] = _asDoubleList(metadata['extrinsic']);
      metadataChanged = true;
    }
    if (_asDoubleList(frame['intrinsics']).length != 4 &&
        _asDoubleList(metadata['intrinsics_fxfycxcy']).length == 4) {
      frame['intrinsics'] = _asDoubleList(metadata['intrinsics_fxfycxcy']);
      metadataChanged = true;
    }
    if (metadataChanged) {
      repairedMetadataCount += 1;
      repairedMetadataFrameIDs.add(id);
      changed = true;
    }
    final needsSizeRepair =
        _asInt(frame['imageWidth']) <= 0 || _asInt(frame['imageHeight']) <= 0;
    final needsPreviewRepair = !previewFile.existsSync();
    image.Image? decoded;
    if ((needsSizeRepair || needsPreviewRepair) && highresFile.existsSync()) {
      decoded = image.decodeImage(await highresFile.readAsBytes());
    }
    if (needsSizeRepair && decoded != null) {
      frame['imageWidth'] = decoded.width;
      frame['imageHeight'] = decoded.height;
      repairedImageSizeCount += 1;
      repairedFrameIDs.add(id);
      changed = true;
    }
    if (needsPreviewRepair && decoded != null) {
      final preview = _makePreview(decoded);
      await previewFile.writeAsBytes(
        image.encodeJpg(preview, quality: 82),
        flush: true,
      );
      frame['previewFilename'] = previewFilename;
      generatedPreviewCount += 1;
      generatedPreviewFrameIDs.add(id);
      changed = true;
    }
    repairedFrames.add(frame);
  }

  final repairedManifest = {
    ...manifest,
    'frames': repairedFrames,
    'assetRepair': {
      'schemaVersion': 'aether_photo_bundle_asset_repair_v1',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'repairedImageSizeCount': repairedImageSizeCount,
      'generatedPreviewCount': generatedPreviewCount,
      'repairedMetadataCount': repairedMetadataCount,
      'repairedFrameIDs': repairedFrameIDs,
      'generatedPreviewFrameIDs': generatedPreviewFrameIDs,
      'repairedMetadataFrameIDs': repairedMetadataFrameIDs,
    },
  };
  return {
    'schemaVersion': 'aether_photo_bundle_asset_repair_v1',
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'changed': changed,
    'repairedImageSizeCount': repairedImageSizeCount,
    'generatedPreviewCount': generatedPreviewCount,
    'repairedMetadataCount': repairedMetadataCount,
    'repairedFrameIDs': repairedFrameIDs,
    'generatedPreviewFrameIDs': generatedPreviewFrameIDs,
    'repairedMetadataFrameIDs': repairedMetadataFrameIDs,
    'manifest': changed ? repairedManifest : manifest,
  };
}

image.Image _makePreview(image.Image source) {
  const maxSide = 768;
  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= maxSide) return source;
  final scale = maxSide / longest;
  return image.copyResize(
    source,
    width: (source.width * scale).round(),
    height: (source.height * scale).round(),
    interpolation: image.Interpolation.cubic,
  );
}


Future<List<String>> _deriveArkitSparsePointCloudAudit({
  required Directory bundleDirectory,
  required Map<String, Object?> manifest,
}) async {
  const auditDirRelative = 'stages/capture_audit';
  const anchorsPlyRelative = '$auditDirRelative/arkit_sparse_anchors_world.ply';
  const cameraPlyRelative = '$auditDirRelative/arkit_camera_path_world.ply';
  const reportRelative = '$auditDirRelative/arkit_sparse_pointcloud_audit.json';
  final auditDir = Directory(_join(bundleDirectory.path, auditDirRelative));
  auditDir.createSync(recursive: true);

  final photosHighresDir = _asString(
    manifest['photosHighresDir'],
    fallback: 'photos_highres',
  );
  final frames = _frames(manifest);
  final anchorVertices = <_PlyVertex>[];
  final cameraVertices = <_PlyVertex>[];
  final frameReports = <Map<String, Object?>>[];
  final trackingCounts = <String, int>{};
  final saveDts = <double>[];
  final anchorCounts = <int>[];
  final bounds = _Bounds3();
  var completeSidecarCount = 0;
  var missingSidecarCount = 0;
  var incompleteSidecarCount = 0;
  var totalAnchorsAvailable = 0;
  var exportedAnchorCount = 0;

  for (var i = 0; i < frames.length; i += 1) {
    final frame = frames[i];
    final id = _asString(
      frame['id'],
      fallback: 'frame_${i.toString().padLeft(4, '0')}',
    );
    final highresFilename = _asString(
      frame['highresFilename'],
      fallback: '$id.jpg',
    );
    final sidecarRelativePath =
        '$photosHighresDir/${_stripExtension(highresFilename)}.json';
    final sidecarFile = File(_join(bundleDirectory.path, sidecarRelativePath));
    if (!sidecarFile.existsSync()) {
      missingSidecarCount += 1;
      frameReports.add({
        'id': id,
        'status': 'missing_sidecar',
        'sidecarRelativePath': sidecarRelativePath,
      });
      continue;
    }
    final sidecar = await _readSidecarMetadata(sidecarFile);
    final trackingState = _asString(
      sidecar['trackingStateName'] ?? sidecar['tracking_state'],
      fallback: 'unknown',
    );
    trackingCounts[trackingState] = (trackingCounts[trackingState] ?? 0) + 1;
    final anchors = _worldAnchors(sidecar['anchors_world']);
    final transform = _asDoubleList(sidecar['extrinsic']);
    final intrinsics = _asDoubleList(sidecar['intrinsics_fxfycxcy']);
    final saveDt = _asDouble(sidecar['save_dt'], fallback: double.nan);
    if (saveDt.isFinite) saveDts.add(saveDt);
    final premetrics = sidecar['scale_align_premetrics'];
    final anchorDepthCount = premetrics is Map
        ? _asInt(premetrics['anchor_depth_count'])
        : anchors.length;
    final complete = _asDouble(sidecar['t'], fallback: double.nan).isFinite &&
        _asInt(sidecar['image_w']) > 0 &&
        _asInt(sidecar['image_h']) > 0 &&
        transform.length == 16 &&
        intrinsics.length >= 4 &&
        trackingState == 'normal' &&
        sidecar['is_tracking'] == true &&
        anchors.isNotEmpty &&
        anchorDepthCount > 0;
    if (!complete) {
      incompleteSidecarCount += 1;
      frameReports.add({
        'id': id,
        'status': 'incomplete_sidecar',
        'sidecarRelativePath': sidecarRelativePath,
        'trackingState': trackingState,
        'isTracking': sidecar['is_tracking'],
        'anchorCount': anchors.length,
        'anchorDepthCount': anchorDepthCount,
        'extrinsicLength': transform.length,
        'intrinsicsLength': intrinsics.length,
        'saveDt': saveDt.isFinite ? saveDt : null,
      });
      continue;
    }

    completeSidecarCount += 1;
    totalAnchorsAvailable += anchors.length;
    anchorCounts.add(anchors.length);
    final color = _frameColor(i, frames.length);
    var exportedForFrame = 0;
    for (final p in anchors) {
      final vertex = _PlyVertex(p[0], p[1], p[2], color.$1, color.$2, color.$3);
      anchorVertices.add(vertex);
      bounds.include(vertex.x, vertex.y, vertex.z);
      exportedForFrame += 1;
    }
    exportedAnchorCount += exportedForFrame;
    final camera = _cameraCenter(transform);
    if (camera != null) {
      final vertex = _PlyVertex(camera[0], camera[1], camera[2], 255, 32, 32);
      cameraVertices.add(vertex);
      bounds.include(vertex.x, vertex.y, vertex.z);
    }
    frameReports.add({
      'id': id,
      'status': 'complete',
      'sidecarRelativePath': sidecarRelativePath,
      'trackingState': trackingState,
      'anchorCount': anchors.length,
      'exportedAnchorCount': exportedForFrame,
      'anchorExportPolicy': 'all anchors from complete sidecar',
      'anchorDepthCount': anchorDepthCount,
      'saveDt': saveDt.isFinite ? saveDt : null,
    });
  }

  await File(_join(bundleDirectory.path, anchorsPlyRelative)).writeAsString(
    _plyText(
      anchorVertices,
      comment:
          'ARKit/VIO rawFeaturePoints from per-photo sidecars, world coordinates in meters. Diagnostic visual audit only.',
    ),
    flush: true,
  );
  await File(_join(bundleDirectory.path, cameraPlyRelative)).writeAsString(
    _plyText(
      cameraVertices,
      comment:
          'ARKit camera centers from per-photo sidecars, world coordinates in meters. Diagnostic visual audit only.',
    ),
    flush: true,
  );

  final completeRatio =
      frames.isEmpty ? 0.0 : completeSidecarCount / frames.length;
  final report = {
    'schemaVersion': 'aether_arkit_sparse_pointcloud_audit_v1',
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'sourceManifest': 'photo_bundle.json',
    'purpose':
        'visual audit of ARKit/VIO metric sparse anchors before DA3 metric alignment',
    'interpretation':
        'PLY is not ground truth; it lets humans quickly inspect ARKit scale, drift, camera path, and gross geometry collapse.',
    'outputs': {
      'anchorsPly': anchorsPlyRelative,
      'cameraPathPly': cameraPlyRelative,
    },
    'frameCount': frames.length,
    'completeSidecarFrameCount': completeSidecarCount,
    'completeSidecarRatio': completeRatio,
    'missingSidecarFrameCount': missingSidecarCount,
    'incompleteSidecarFrameCount': incompleteSidecarCount,
    'totalAnchorsAvailable': totalAnchorsAvailable,
    'exportedAnchorCount': exportedAnchorCount,
    'anchorExportPolicy': 'all anchors from complete sidecars, no sampling',
    'cameraPoseCount': cameraVertices.length,
    'trackingStateCounts': trackingCounts,
    'anchorCountStats': _intStats(anchorCounts),
    'saveDtStatsSec': _doubleStats(saveDts),
    'boundsWorldMeters': bounds.toJson(),
    'hardGateExpectation':
        'In new captures, completeSidecarFrameCount should equal frameCount; otherwise a frame was promoted without full AR/VIO metadata.',
    'frames': frameReports,
  };
  await File(_join(bundleDirectory.path, reportRelative)).writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  return [anchorsPlyRelative, cameraPlyRelative, reportRelative];
}

List<Map<String, Object?>> _frames(Map<String, Object?> manifest) {
  final frames = manifest['frames'];
  if (frames is! List) return const <Map<String, Object?>>[];
  return [
    for (final frame in frames)
      if (frame is Map) frame.cast<String, Object?>(),
  ];
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}

bool _asBool(Object? value) => value == true;

double _asDouble(Object? value, {double fallback = 0.0}) {
  if (value is num) return value.toDouble();
  return fallback;
}

List<double> _asDoubleList(Object? value) {
  if (value is! List) return const <double>[];
  return [
    for (final item in value)
      if (item is num) item.toDouble()
  ];
}

List<List<double>> _worldAnchors(Object? value) {
  if (value is! List) return const <List<double>>[];
  final anchors = <List<double>>[];
  for (final item in value) {
    if (item is! List || item.length < 3) continue;
    final x = item[0];
    final y = item[1];
    final z = item[2];
    if (x is! num || y is! num || z is! num) continue;
    final px = x.toDouble();
    final py = y.toDouble();
    final pz = z.toDouble();
    if (px.isFinite && py.isFinite && pz.isFinite) {
      anchors.add([px, py, pz]);
    }
  }
  return anchors;
}

List<double>? _cameraCenter(List<double> transform) {
  if (transform.length != 16) return null;
  final x = transform[12];
  final y = transform[13];
  final z = transform[14];
  if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
  return [x, y, z];
}

(int, int, int) _frameColor(int index, int count) {
  final t = count <= 1 ? 0.0 : index / (count - 1);
  final r = (40 + 180 * t).round().clamp(0, 255);
  final g = (190 - 120 * t).round().clamp(0, 255);
  final b = (255 - 160 * t).round().clamp(0, 255);
  return (r, g, b);
}

Map<String, Object?> _intStats(List<int> values) {
  if (values.isEmpty) {
    return const {
      'count': 0,
      'min': null,
      'p10': null,
      'p50': null,
      'p90': null,
      'max': null,
      'mean': null,
    };
  }
  final sorted = [...values]..sort();
  final sum = values.fold<int>(0, (acc, value) => acc + value);
  return {
    'count': values.length,
    'min': sorted.first,
    'p10': _percentileInt(sorted, 0.10),
    'p50': _percentileInt(sorted, 0.50),
    'p90': _percentileInt(sorted, 0.90),
    'max': sorted.last,
    'mean': sum / values.length,
  };
}

Map<String, Object?> _doubleStats(List<double> values) {
  final finite = values.where((value) => value.isFinite).toList()..sort();
  if (finite.isEmpty) {
    return const {
      'count': 0,
      'min': null,
      'p50': null,
      'p90': null,
      'max': null,
      'mean': null,
    };
  }
  final sum = finite.fold<double>(0, (acc, value) => acc + value);
  return {
    'count': finite.length,
    'min': finite.first,
    'p50': _percentileDouble(finite, 0.50),
    'p90': _percentileDouble(finite, 0.90),
    'max': finite.last,
    'mean': sum / finite.length,
  };
}

int _percentileInt(List<int> sorted, double p) {
  final index = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[index];
}

double _percentileDouble(List<double> sorted, double p) {
  final index = ((sorted.length - 1) * p).round().clamp(0, sorted.length - 1);
  return sorted[index];
}

String _plyText(List<_PlyVertex> vertices, {required String comment}) {
  final buffer = StringBuffer()
    ..writeln('ply')
    ..writeln('format ascii 1.0')
    ..writeln('comment $comment')
    ..writeln('element vertex ${vertices.length}')
    ..writeln('property float x')
    ..writeln('property float y')
    ..writeln('property float z')
    ..writeln('property uchar red')
    ..writeln('property uchar green')
    ..writeln('property uchar blue')
    ..writeln('end_header');
  for (final vertex in vertices) {
    buffer
      ..write(_formatPlyNumber(vertex.x))
      ..write(' ')
      ..write(_formatPlyNumber(vertex.y))
      ..write(' ')
      ..write(_formatPlyNumber(vertex.z))
      ..write(' ')
      ..write(vertex.r)
      ..write(' ')
      ..write(vertex.g)
      ..write(' ')
      ..writeln(vertex.b);
  }
  return buffer.toString();
}

String _formatPlyNumber(double value) {
  if (!value.isFinite) return '0';
  return value.toStringAsFixed(6);
}

final class _PlyVertex {
  const _PlyVertex(this.x, this.y, this.z, this.r, this.g, this.b);

  final double x;
  final double y;
  final double z;
  final int r;
  final int g;
  final int b;
}

final class _Bounds3 {
  double minX = double.infinity;
  double minY = double.infinity;
  double minZ = double.infinity;
  double maxX = double.negativeInfinity;
  double maxY = double.negativeInfinity;
  double maxZ = double.negativeInfinity;

  void include(double x, double y, double z) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) return;
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (z < minZ) minZ = z;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
    if (z > maxZ) maxZ = z;
  }

  Map<String, Object?> toJson() {
    if (!minX.isFinite) {
      return const {
        'min': null,
        'max': null,
        'size': null,
      };
    }
    return {
      'min': [minX, minY, minZ],
      'max': [maxX, maxY, maxZ],
      'size': [maxX - minX, maxY - minY, maxZ - minZ],
    };
  }
}

String _asString(Object? value, {String fallback = ''}) {
  if (value is String && value.isNotEmpty) return value;
  return fallback;
}

String _stripExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot <= 0) return filename;
  return filename.substring(0, dot);
}

Future<Map<String, Object?>> _readSidecarMetadata(File file) async {
  if (!file.existsSync()) return const <String, Object?>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map) return decoded.cast<String, Object?>();
  } catch (_) {
    // Malformed per-photo sidecars should not block bundle derivation; the
    // image decode path below can still repair dimensions/previews.
  }
  return const <String, Object?>{};
}

String _join(String left, String right) {
  final normalizedRight = right.split('/').join(Platform.pathSeparator);
  if (left.endsWith(Platform.pathSeparator)) return '$left$normalizedRight';
  return '$left${Platform.pathSeparator}$normalizedRight';
}
