import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:aether_capture_services/aether_capture_services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/pipeline/local_pipeline_runner.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'DA3 Stage 1 runs native CoreML on local MSD benchmark K35 bundle',
    (tester) async {
      final temp = await getTemporaryDirectory();
      final cap = Directory(
        '${temp.path}/da3_depth_real_benchmark_'
        '${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(() async {
        if (await cap.exists()) {
          await cap.delete(recursive: true);
        }
      });

      await _writeBenchmarkPhotoBundle(cap);
      final derivation = await const PhotoBundleDerivationService()
          .deriveDirectory(cap);

      expect(derivation.frameCount, _benchmarkFiles.length);
      expect(derivation.writtenRelativePaths, contains('model_policy.json'));
      expect(derivation.writtenRelativePaths, contains('da3_k_windows.json'));
      expect(
        derivation.writtenRelativePaths,
        contains('da3_input_manifest.json'),
      );
      expect(File('${cap.path}/photos_depth/msd_000.jpg').existsSync(), isTrue);

      final kWindows =
          jsonDecode(
                await File('${cap.path}/da3_k_windows.json').readAsString(),
              )
              as Map<String, dynamic>;
      expect(kWindows['windowSize'], 35);
      expect(kWindows['inputWidth'], 742);
      expect(kWindows['inputHeight'], 476);
      expect(kWindows['windowCount'], 1);

      final runner = LocalPipelineRunner(
        captureDir: cap,
        stages: const [DepthStage(stubDelay: Duration(microseconds: 4))],
      );
      addTearDown(runner.dispose);

      final events = <PipelineEvent>[];
      final sub = runner.stream.listen(events.add);
      await runner.run();
      await sub.cancel();

      final depthIndexFile = File('${cap.path}/stages/depth/depth_index.json');
      final reportFile = File(
        '${cap.path}/stages/depth/depth_runner_report.json',
      );
      expect(depthIndexFile.existsSync(), isTrue);
      expect(reportFile.existsSync(), isTrue);

      final depthIndex =
          jsonDecode(await depthIndexFile.readAsString())
              as Map<String, dynamic>;
      final report =
          jsonDecode(await reportFile.readAsString()) as Map<String, dynamic>;
      if (depthIndex['status'] != 'completed') {
        final debugFrames = depthIndex['frames'];
        final firstFrame = debugFrames is List && debugFrames.isNotEmpty
            ? debugFrames.first
            : null;
        fail(
          'DA3 real benchmark failed:\n'
          '${const JsonEncoder.withIndent('  ').convert({'status': depthIndex['status'], 'frameCount': depthIndex['frame_count'], 'completedCount': depthIndex['completed_count'], 'pendingCount': depthIndex['pending_count'], 'failedCount': depthIndex['failed_count'], 'windows': report['windows'], 'firstFrame': firstFrame})}',
        );
      }
      expect(depthIndex['status'], 'completed');
      expect(depthIndex['model']['id'], 'DA3-BASE');
      expect(depthIndex['model']['license'], 'Apache-2.0');
      expect(depthIndex['input_size_locked'], isTrue);
      expect(depthIndex['input_width'], 742);
      expect(depthIndex['input_height'], 476);
      expect(depthIndex['frame_count'], _benchmarkFiles.length);
      expect(depthIndex['completed_count'], _benchmarkFiles.length);
      expect(depthIndex['pending_count'], 0);
      expect(depthIndex['failed_count'], 0);

      final frames = (depthIndex['frames'] as List)
          .cast<Map<String, dynamic>>();
      expect(frames, hasLength(_benchmarkFiles.length));
      for (final frame in frames) {
        expect(frame['status'], 'completed');
        expect(frame['imageRelativePath'], startsWith('photos_depth/'));
        expect(frame['relativeDepthPath'], startsWith('relative_depth/'));
        expect(frame['confidencePath'], startsWith('confidence/'));
        expect(frame['predExtrinsicsPath'], startsWith('pred_pose/'));
        expect(frame['predIntrinsicsPath'], startsWith('pred_pose/'));
        expect(frame['depthWidth'], 742);
        expect(frame['depthHeight'], 476);
      }

      final first = frames.first;
      expect(
        File(
          '${cap.path}/stages/depth/${first['relativeDepthPath']}',
        ).existsSync(),
        isTrue,
      );
      expect(
        File(
          '${cap.path}/stages/depth/${first['confidencePath']}',
        ).existsSync(),
        isTrue,
      );

      expect(events.whereType<PipelineCompletedEvent>(), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

const _assetRoot = 'assets/benchmarks/da3_msd';

const _benchmarkFiles = <String>[
  '1001_512x640.jpg',
  '101_512x640.jpg',
  '1025_512x640.jpg',
  '1036_512x640.jpg',
  '1043_512x640.jpg',
  '1050_512x640.jpg',
  '111_512x640.jpg',
  '119_512x640.jpg',
  '138_512x640.jpg',
  '160_640x512.jpg',
  '1647_512x640.jpg',
  '1649_512x640.jpg',
  '1652_512x640.jpg',
  '1654_512x640.jpg',
  '1656_512x640.jpg',
  '1657_640x512.jpg',
  '1668_512x640.jpg',
  '1677_640x512.jpg',
  '1678_512x640.jpg',
  '1680_512x640.jpg',
  '1682_512x640.jpg',
  '1683_512x640.jpg',
  '1684_512x640.jpg',
  '1685_512x640.jpg',
  '1687_512x640.jpg',
  '1688_512x640.jpg',
  '1690_512x640.jpg',
  '1691_512x640.jpg',
  '1693_512x640.jpg',
  '1694_512x640.jpg',
  '1695_512x640.jpg',
  '1696_640x512.jpg',
  '1697_512x640.jpg',
  '1699_512x640.jpg',
  '1700_512x640.jpg',
];

Future<void> _writeBenchmarkPhotoBundle(Directory cap) async {
  final highres = Directory('${cap.path}/photos_highres');
  final previews = Directory('${cap.path}/previews');
  await highres.create(recursive: true);
  await previews.create(recursive: true);

  final frames = <Map<String, Object?>>[];
  for (var i = 0; i < _benchmarkFiles.length; i += 1) {
    final filename = _benchmarkFiles[i];
    final bytes = await _loadAssetBytes('$_assetRoot/$filename');
    await File('${highres.path}/$filename').writeAsBytes(bytes, flush: true);
    await File('${previews.path}/$filename').writeAsBytes(bytes, flush: true);

    final decoded = image.decodeImage(bytes);
    if (decoded == null) {
      throw FormatException(
        'Could not decode benchmark image asset: $filename',
      );
    }
    frames.add(
      _photoBundleFrame(
        index: i,
        filename: filename,
        width: decoded.width,
        height: decoded.height,
      ),
    );
  }

  await File('${cap.path}/photo_bundle.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 'aether_photo_bundle_v1',
      'processingTier': 'high',
      'captureKind': 'benchmark_asset_photo_bundle',
      'sourceDataset': 'MSD/test/image local benchmark subset',
      'photosHighresDir': 'photos_highres',
      'previewsDir': 'previews',
      'colmapSparseDir': 'colmap/sparse/0',
      'frames': frames,
    }),
    flush: true,
  );
}

Future<Uint8List> _loadAssetBytes(String assetPath) async {
  final data = await rootBundle.load(assetPath);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Map<String, Object?> _photoBundleFrame({
  required int index,
  required String filename,
  required int width,
  required int height,
}) {
  final count = _benchmarkFiles.length;
  final theta = index * 2 * math.pi / count;
  final radius = 1.15;
  final x = math.cos(theta) * radius;
  final z = math.sin(theta) * radius;
  final quality = 0.92 - index * 0.001;
  final focal = math.max(width, height) * 1.1;

  return {
    'id': 'msd_${index.toString().padLeft(3, '0')}',
    'highresFilename': filename,
    'previewFilename': filename,
    'timestamp': index / 6.0,
    'azimuth': theta,
    'elevation': 0.0,
    'cameraRadiusM': radius,
    'radiusShellID': 'r_1.00_1.25m',
    'imageWidth': width,
    'imageHeight': height,
    'quality': {
      'score': quality,
      'viewGraphWeight': quality,
      'kWindowWeight': quality,
      'textureBestViewWeight': quality,
      'laplacianVariance': 850.0 - index,
      'tenengradMean': 42.0 - index * 0.1,
      'localContrast': 0.42,
      'saturationRatio': 0.03,
      'centerRoiLaplacianVariance': 780.0 - index,
    },
    'cameraTransform': _cameraToWorld(centerX: x, centerY: 0.0, centerZ: z),
    'intrinsics': [focal, focal, width / 2.0, height / 2.0],
  };
}

List<double> _cameraToWorld({
  required double centerX,
  required double centerY,
  required double centerZ,
}) {
  return [
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    centerX,
    centerY,
    centerZ,
    1.0,
  ];
}
