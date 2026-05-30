import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/pipeline/local_pipeline_runner.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('DA3 Stage 1 Flutter contract completes with native adapter mock', (
    tester,
  ) async {
    final temp = await getTemporaryDirectory();
    final cap = Directory(
      '${temp.path}/da3_depth_dry_run_${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      if (await cap.exists()) {
        await cap.delete(recursive: true);
      }
    });

    await _writePhotoBundleFixture(cap);

    final channel = const MethodChannel('pocketworld/da3_depth');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'runDa3DepthWindow');
      final args = (call.arguments as Map).cast<String, Object?>();
      expect(args['inputSizePolicy'], containsPair('locked', true));
      expect(args['inputSizePolicy'], containsPair('width', 742));
      expect(args['inputSizePolicy'], containsPair('height', 476));
      expect(
        args['runtimeContract'],
        containsPair('schemaVersion', 'aether_da3_runtime_contract_v1'),
      );
      final frames = (args['frames'] as List).cast<Map<Object?, Object?>>();
      expect(frames, hasLength(35));
      expect(frames.first['imageRelativePath'], 'photos_depth/a.jpg');
      expect(frames.first['sourceImageRelativePath'], 'photos_highres/a.jpg');

      final outputDir = args['outputDir']! as String;
      await Directory('$outputDir/relative_depth').create(recursive: true);
      await Directory('$outputDir/confidence').create(recursive: true);
      await Directory('$outputDir/pred_pose').create(recursive: true);
      return <String, Object?>{
        'windowID': args['windowID'],
        'status': 'completed',
        'frames': [
          for (var i = 0; i < frames.length; i++)
            <String, Object?>{
              'frameID': frames[i]['frameID'],
              'windowID': args['windowID'],
              'status': 'completed',
              'relativeDepthPath': 'relative_depth/mock_$i.bin',
              'confidencePath': 'confidence/mock_$i.bin',
              'predExtrinsicsPath': 'pred_pose/mock_${i}_extrinsics.bin',
              'predIntrinsicsPath': 'pred_pose/mock_${i}_intrinsics.bin',
              'depthWidth': 742,
              'depthHeight': 476,
              'inferenceMs': 0.0,
              'confMedian': 1.2,
              'confMean': 1.2,
              'confMin': 1.2,
              'confMax': 1.2,
            },
        ],
      };
    });

    final runner = LocalPipelineRunner(
      captureDir: cap,
      stages: const [DepthStage(stubDelay: Duration(microseconds: 4))],
    );
    addTearDown(runner.dispose);

    final events = <PipelineEvent>[];
    final sub = runner.stream.listen(events.add);
    await runner.run();
    await sub.cancel();

    final depthDir = Directory('${cap.path}/stages/depth');
    final depthIndexFile = File('${depthDir.path}/depth_index.json');
    final reportFile = File('${depthDir.path}/depth_runner_report.json');
    expect(depthIndexFile.existsSync(), isTrue);
    expect(reportFile.existsSync(), isTrue);

    final depthIndex =
        jsonDecode(await depthIndexFile.readAsString()) as Map<String, dynamic>;
    expect(depthIndex['status'], 'completed');
    expect(depthIndex['model']['id'], 'DA3-BASE');
    expect(depthIndex['input_size_locked'], isTrue);
    expect(depthIndex['input_width'], 742);
    expect(depthIndex['input_height'], 476);
    expect(depthIndex['completed_count'], 2);
    expect(depthIndex['pending_count'], 0);
    expect(depthIndex['failed_count'], 0);

    final frames = (depthIndex['frames'] as List).cast<Map<String, dynamic>>();
    expect(frames, hasLength(2));
    for (final frame in frames) {
      expect(frame['status'], 'completed');
      final relativeDepthPath = frame['relativeDepthPath'] as String;
      final confidencePath = frame['confidencePath'] as String;
      expect(relativeDepthPath, startsWith('relative_depth/'));
      expect(confidencePath, startsWith('confidence/'));
      expect(frame['predExtrinsicsPath'], startsWith('pred_pose/'));
      expect(frame['predIntrinsicsPath'], startsWith('pred_pose/'));
    }

    final completed = events.whereType<PipelineCompletedEvent>().toList();
    expect(completed, hasLength(1));
  });
}

Future<void> _writePhotoBundleFixture(Directory cap) async {
  final highres = Directory('${cap.path}/photos_highres');
  final previews = Directory('${cap.path}/previews');
  await highres.create(recursive: true);
  await previews.create(recursive: true);
  for (final id in ['a', 'b']) {
    final jpeg = _jpegFixture(id == 'a' ? 24 : 48);
    await File('${highres.path}/$id.jpg').writeAsBytes(jpeg);
    await File('${previews.path}/$id.jpg').writeAsBytes(jpeg);
  }
  await File('${cap.path}/photo_bundle.json').writeAsString(
    jsonEncode({
      'schemaVersion': 'aether_photo_bundle_v1',
      'photosHighresDir': 'photos_highres',
      'previewsDir': 'previews',
      'frames': [
        _photoBundleFrame('a', 0, 0, 0, 0),
        _photoBundleFrame('b', 0.14, 0, 0.12, 0.02),
      ],
    }),
  );
}

List<int> _jpegFixture(int seed) {
  final img = image.Image(width: 32, height: 24);
  for (var y = 0; y < img.height; y += 1) {
    for (var x = 0; x < img.width; x += 1) {
      img.setPixelRgb(x, y, (x * 3 + seed) % 255, (y * 5 + seed) % 255, 160);
    }
  }
  return image.encodeJpg(img, quality: 90);
}

Map<String, Object?> _photoBundleFrame(
  String id,
  double azimuth,
  double elevation,
  double x,
  double z,
) {
  return {
    'id': id,
    'highresFilename': '$id.jpg',
    'previewFilename': '$id.jpg',
    'timestamp': id == 'a' ? 1.0 : 2.0,
    'azimuth': azimuth,
    'elevation': elevation,
    'cameraRadiusM': 1.0,
    'radiusShellID': 'r_1.00_1.25m',
    'imageWidth': 4032,
    'imageHeight': 3024,
    'quality': {'score': 0.9, 'laplacianVariance': 500.0},
    'cameraTransform': [
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
      x,
      0.0,
      z,
      1.0,
    ],
    'intrinsics': [2200.0, 2200.0, 2016.0, 1512.0],
  };
}
