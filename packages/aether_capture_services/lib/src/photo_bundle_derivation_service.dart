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

    final tier = _asString(manifest['processingTier'], fallback: 'high');
    final model = policyService.modelPolicy.resolveDa3Model(tier: tier);
    final modelPolicy = policyService.modelPolicy.buildLicenseReport(
      tier: tier,
    );
    await File(_join(bundleDirectory.path, 'model_policy.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(modelPolicy),
    );
    written.add('model_policy.json');

    final kWindows = policyService.buildKWindowPlan(
      manifest,
      viewGraph,
      tier: tier,
      targetBridgeOverlap: targetBridgeOverlap,
    );
    await File(_join(bundleDirectory.path, 'da3_k_windows.json')).writeAsString(
      const JsonEncoder.withIndent('  ').convert(kWindows),
    );
    written.add('da3_k_windows.json');

    final da3InputManifest = await _deriveDa3InputImages(
      bundleDirectory: bundleDirectory,
      manifest: manifest,
      model: model,
    );
    await File(
      _join(bundleDirectory.path, 'da3_input_manifest.json'),
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(da3InputManifest),
    );
    written.add('da3_input_manifest.json');
    written.addAll(
      _maps(da3InputManifest['frames'])
          .map((frame) =>
              _asString(frame['depthImageRelativePath'], fallback: ''))
          .where((path) => path.isNotEmpty),
    );

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

Future<Map<String, Object?>> _deriveDa3InputImages({
  required Directory bundleDirectory,
  required Map<String, Object?> manifest,
  required AetherDa3ModelSpec model,
}) async {
  final inputWidth = model.inputWidth;
  final inputHeight = model.inputHeight;
  if (inputWidth == null || inputHeight == null) {
    throw StateError('DA3 model policy did not lock inputWidth/inputHeight');
  }

  const photosDepthDir = 'photos_depth';
  final photosHighresDir = _asString(
    manifest['photosHighresDir'],
    fallback: 'photos_highres',
  );
  final outputDir = Directory(_join(bundleDirectory.path, photosDepthDir));
  outputDir.createSync(recursive: true);

  final frames = _frames(manifest);
  final entries = <Map<String, Object?>>[];
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
    final sourceRelativePath = '$photosHighresDir/$highresFilename';
    final sourceFile = File(_join(bundleDirectory.path, sourceRelativePath));
    if (!sourceFile.existsSync()) {
      throw FileSystemException(
          'missing high-res source image', sourceFile.path);
    }

    final decoded = image.decodeImage(await sourceFile.readAsBytes());
    if (decoded == null) {
      throw FormatException('could not decode high-res source image: '
          '${sourceFile.path}');
    }

    final resized = image.copyResize(
      decoded,
      width: inputWidth,
      height: inputHeight,
      interpolation: image.Interpolation.cubic,
    );
    final depthFilename = '${_safeFilename(id)}.jpg';
    final depthRelativePath = '$photosDepthDir/$depthFilename';
    await File(_join(bundleDirectory.path, depthRelativePath)).writeAsBytes(
      image.encodeJpg(resized, quality: 95),
      flush: true,
    );

    final sourceWidth =
        _positiveInt(frame['imageWidth'], fallback: decoded.width);
    final sourceHeight =
        _positiveInt(frame['imageHeight'], fallback: decoded.height);
    final scaleX =
        inputWidth / (sourceWidth <= 0 ? decoded.width : sourceWidth);
    final scaleY =
        inputHeight / (sourceHeight <= 0 ? decoded.height : sourceHeight);
    entries.add({
      'id': id,
      'sourceHighresRelativePath': sourceRelativePath,
      'depthImageRelativePath': depthRelativePath,
      'sourceWidth': sourceWidth,
      'sourceHeight': sourceHeight,
      'inputWidth': inputWidth,
      'inputHeight': inputHeight,
      'resize': {
        'mode': 'direct_stretch',
        'interpolation': 'cubic',
        'colorSpace': 'sRGB',
        'jpegQuality': 95,
      },
      'transform': {
        'scaleX': scaleX,
        'scaleY': scaleY,
        'offsetX': 0.0,
        'offsetY': 0.0,
        'cropX': 0.0,
        'cropY': 0.0,
        'cropWidth': sourceWidth,
        'cropHeight': sourceHeight,
      },
      'intrinsicsTransform': {
        'fxScale': scaleX,
        'fyScale': scaleY,
        'cxScale': scaleX,
        'cyScale': scaleY,
        'cxOffset': 0.0,
        'cyOffset': 0.0,
      },
    });
  }

  return {
    'schemaVersion': 'aether_da3_input_manifest_v1',
    'sourceManifest': 'photo_bundle.json',
    'photosDepthDir': photosDepthDir,
    'model': model.toJson(),
    'inputSizeLocked': true,
    'inputWidth': inputWidth,
    'inputHeight': inputHeight,
    'preprocessOwner': 'Flutter/Dart photo bundle derivation service',
    'nativeRunnerContract':
        'native receives already-resized DA3 images and only decodes tensor bytes',
    'frameCount': entries.length,
    'frames': entries,
  };
}

List<Map<String, Object?>> _frames(Map<String, Object?> manifest) {
  final frames = manifest['frames'];
  if (frames is! List) return const <Map<String, Object?>>[];
  return [
    for (final frame in frames)
      if (frame is Map) frame.cast<String, Object?>(),
  ];
}

List<Map<String, Object?>> _maps(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return [
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
  ];
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return fallback;
}

int _positiveInt(Object? value, {required int fallback}) {
  final parsed = _asInt(value, fallback: fallback);
  return parsed > 0 ? parsed : fallback;
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

String _safeFilename(String value) {
  final buffer = StringBuffer();
  for (final codeUnit in value.codeUnits) {
    final isDigit = codeUnit >= 48 && codeUnit <= 57;
    final isUpper = codeUnit >= 65 && codeUnit <= 90;
    final isLower = codeUnit >= 97 && codeUnit <= 122;
    if (isDigit || isUpper || isLower || codeUnit == 45 || codeUnit == 95) {
      buffer.writeCharCode(codeUnit);
    } else {
      buffer.write('_');
    }
  }
  final text = buffer.toString();
  return text.isEmpty ? 'frame' : text;
}

String _join(String left, String right) {
  final normalizedRight = right.split('/').join(Platform.pathSeparator);
  if (left.endsWith(Platform.pathSeparator)) return '$left$normalizedRight';
  return '$left${Platform.pathSeparator}$normalizedRight';
}
