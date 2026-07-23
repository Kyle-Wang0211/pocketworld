import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('pocketworld_official_arkit');
  const poseEvents = EventChannel('pocketworld_official_arkit/pose_stream');

  testWidgets('official route completes 20 sequential 12MP transactions', (
    tester,
  ) async {
    expect(await method.invokeMethod<bool>('isAvailable'), isTrue);
    await method.invokeMethod<void>('startSession', <String, Object?>{
      'videoFormatMode': 'hires43',
    });
    addTearDown(() async {
      try {
        await method.invokeMethod<void>('stopSession');
      } on Object {
        // Preserve the actual test result if teardown cannot reach the device.
      }
    });

    final poseSub = poseEvents.receiveBroadcastStream();
    await poseSub.first.timeout(const Duration(seconds: 8));

    final temp = await getTemporaryDirectory();
    final outDir = Directory(
      '${temp.path}/official_highres_reliability_'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await outDir.create(recursive: true);
    addTearDown(() async {
      if (await outDir.exists()) {
        await outDir.delete(recursive: true);
      }
    });

    final deltas = <double>[];
    for (var index = 0; index < 20; index++) {
      final highresPath = '${outDir.path}/shot_$index.jpg';
      final result = await method
          .invokeMapMethod<String, dynamic>(
            'captureHighResolutionStill',
            <String, Object?>{
              'highresPath': highresPath,
              'previewPath': '${outDir.path}/unused_preview_$index.jpg',
              'quality': 0.92,
              'deriveAuxiliary': false,
              'feedSfm': false,
            },
          )
          .timeout(const Duration(seconds: 10));

      expect(result, isNotNull, reason: 'shot $index returned no ARFrame');
      expect(
        (result!['imageWidth'] as num?)?.toInt(),
        4032,
        reason: 'shot $index width',
      );
      expect(
        (result['imageHeight'] as num?)?.toInt(),
        3024,
        reason: 'shot $index height',
      );
      expect(
        await File(highresPath).exists(),
        isTrue,
        reason: 'shot $index JPEG',
      );
      expect(
        (result['cameraTransform'] as List?)?.length,
        16,
        reason: 'shot $index pose',
      );
      expect(
        (result['intrinsics'] as List?)?.length,
        greaterThanOrEqualTo(4),
        reason: 'shot $index intrinsics',
      );
      expect(
        (result['requestTimestamp'] as num?)?.toDouble().isFinite,
        isTrue,
        reason: 'shot $index request timestamp',
      );
      expect(
        (result['timestamp'] as num?)?.toDouble().isFinite,
        isTrue,
        reason: 'shot $index capture timestamp',
      );
      deltas.add((result['timestampDelta'] as num).toDouble());
    }

    expect(deltas, hasLength(20));
  });
}
