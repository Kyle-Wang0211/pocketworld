import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('aether_arkit');
  const poseEvents = EventChannel('aether_arkit/pose_stream');

  testWidgets('ARKit high-res still returns gray1024 quality plane', (
    tester,
  ) async {
    final isAvailable = await method.invokeMethod<bool>('isAvailable');
    if (isAvailable != true) {
      return;
    }

    await method.invokeMethod<void>('startSession');
    addTearDown(() async {
      try {
        await method.invokeMethod<void>('stopSession');
      } on Object {
        // Test teardown should not hide the actual smoke-test failure.
      }
    });

    final poseSub = poseEvents.receiveBroadcastStream();
    await poseSub.first.timeout(const Duration(seconds: 8));

    final temp = await getTemporaryDirectory();
    final outDir = Directory(
      '${temp.path}/arkit_highres_gray1024_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    addTearDown(() async {
      if (await outDir.exists()) {
        await outDir.delete(recursive: true);
      }
    });

    final highresPath = '${outDir.path}/photos_highres/smoke.jpg';
    final previewPath = '${outDir.path}/previews/smoke.jpg';
    final result = await method
        .invokeMapMethod<String, dynamic>(
          'captureHighResolutionStill',
          <String, Object?>{
            'highresPath': highresPath,
            'previewPath': previewPath,
            'quality': 0.92,
          },
        )
        .timeout(const Duration(seconds: 10));

    expect(result, isNotNull);
    expect(await File(highresPath).exists(), isTrue);
    expect(await File(previewPath).exists(), isTrue);
    expect(result!['captureKind'], 'arkit_high_res_still');
    expect(result['poseSyncQuality'], 'ar_session_high_res_frame');
    expect(result['q_gray1024W'], 1024);
    expect(result['q_gray1024H'], 1024);
    expect((result['imageWidth'] as num?)?.toInt(), greaterThan(0));
    expect((result['imageHeight'] as num?)?.toInt(), greaterThan(0));

    final gray1024 = result['q_gray1024'];
    if (gray1024 is Uint8List) {
      expect(gray1024.length, 1024 * 1024);
    } else if (gray1024 is List) {
      expect(gray1024.length, 1024 * 1024);
    } else {
      fail('q_gray1024 missing or not a byte list: ${gray1024.runtimeType}');
    }
  });
}
