import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_worker.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';

const _smallJpegBase64 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCACQAQABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//2Q==';

void main() {
  SfmLiveSnapshot snapshot({Float32List? xyz, Uint8List? rgb}) {
    final points = (xyz?.length ?? 6) ~/ 3;
    return SfmLiveSnapshot(
      xyz: xyz ?? Float32List.fromList(const <double>[1, 2, 3, 4, 5, 6]),
      rgb: rgb ?? Uint8List.fromList(const <int>[10, 20, 30, 40, 50, 60]),
      posesPacked: Float64List.fromList(const <double>[
        7,
        1,
        1,
        0,
        0,
        0,
        0,
        0,
        0,
      ]),
      summary: const <String, dynamic>{
        'result': 'refined',
        'nested': <String, Object?>{'registered': 1},
      },
      refined: true,
      obsOffsets: Int32List(points + 1),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
  }

  SfmDurableFedFrameInput frame(int id) => SfmDurableFedFrameInput(
    sequence: id,
    frameId: id,
    grayPath: '/capture/spool/$id.gray',
    meta: SfmFedFrameMeta(
      jpegPath: '/capture/photos_highres/$id.jpg',
      imageW: 640,
      imageH: 480,
      grayW: 320,
      grayH: 240,
      fx: 200,
      fy: 201,
      cx: 160,
      cy: 120,
      arkitQuatWxyz: const <double>[1, 0, 0, 0],
      arkitTransTxyz: <double>[0, 0, -id.toDouble()],
      arkitCameraCenterWorld: <double>[0, 0, id.toDouble()],
    ),
  );

  Uint8List floatBytes(Float32List values) => values.buffer.asUint8List();

  test(
    'copies request data before spawn and preserves sparse byte prefix',
    () async {
      final xyz = Float32List.fromList(const <double>[1, 2, 3, 4, 5, 6]);
      final rgb = Uint8List.fromList(const <int>[10, 20, 30, 40, 50, 60]);
      final originalXyzBytes = Uint8List.fromList(floatBytes(xyz));
      final originalRgb = Uint8List.fromList(rgb);

      final task = BcdFinalizeWorker.startForTesting(
        captureId: 'copy-prefix',
        snapshot: snapshot(xyz: xyz, rgb: rgb),
        durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
        options: const BcdFinalizeWorkerTestOptions(
          busyFor: Duration(milliseconds: 80),
          structuralBirthXyz: <double>[7, 8, 9],
          structuralBirthRgb: <int>[70, 80, 90],
          detectorFreeBirthXyz: <double>[10, 11, 12],
          detectorFreeBirthRgb: <int>[100, 110, 120],
        ),
      );
      xyz.fillRange(0, xyz.length, 99);
      rgb.fillRange(0, rgb.length, 255);

      final result = await task.result;
      expect(result.status, BcdFinalizeWorkerStatus.completed);
      expect(result.publication, 'structuralAndDetectorFree');
      expect(result.originalPointCount, 2);
      expect(result.structuralBirthCount, 1);
      expect(result.detectorFreeBirthCount, 1);
      expect(
        floatBytes(result.snapshot.xyz).sublist(0, originalXyzBytes.length),
        originalXyzBytes,
      );
      expect(result.snapshot.rgb.sublist(0, originalRgb.length), originalRgb);
      expect(result.snapshot.xyz.sublist(6), <double>[7, 8, 9, 10, 11, 12]);
      expect(result.snapshot.obsOffsets, <int>[0, 0, 0, 0, 0]);
      expect(result.snapshot.toSnapshot().ghostSpatialKeepIdx, isNull);
    },
  );

  test(
    '1000-frame protocol and blocking work do not stall caller ticker',
    () async {
      var ticks = 0;
      final ticker = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => ticks++,
      );
      final task = BcdFinalizeWorker.startForTesting(
        captureId: 'one-thousand',
        snapshot: snapshot(),
        durableFedFrames: <SfmDurableFedFrameInput>[
          for (var id = 0; id < 1000; id++) frame(id),
        ],
        options: const BcdFinalizeWorkerTestOptions(
          busyFor: Duration(milliseconds: 220),
        ),
      );
      final result = await task.result;
      ticker.cancel();

      expect(result.status, BcdFinalizeWorkerStatus.completed);
      expect(result.stat('input_frames')?.value, 1000);
      expect(result.stats.map((item) => item.name), <String>[
        'input_frames',
        'original_points',
        'structural_births',
        'detector_free_births',
        'output_points',
        'elapsed_us',
      ]);
      expect(
        ticks,
        greaterThan(10),
        reason: 'UI/caller event loop was blocked',
      );
    },
  );

  test('D failure retains accepted B and reports an ordered failure', () async {
    final task = BcdFinalizeWorker.startForTesting(
      captureId: 'd-failure',
      snapshot: snapshot(),
      durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
      options: const BcdFinalizeWorkerTestOptions(
        structuralBirthXyz: <double>[7, 8, 9],
        structuralBirthRgb: <int>[70, 80, 90],
        detectorFreeBirthXyz: <double>[10, 11, 12],
        detectorFreeBirthRgb: <int>[100, 110, 120],
        detectorFreeFailure: 'native reader unavailable',
      ),
    );
    final result = await task.result;

    expect(result.status, BcdFinalizeWorkerStatus.completed);
    expect(result.publication, 'structural');
    expect(result.structuralBirthCount, 1);
    expect(result.detectorFreeBirthCount, 0);
    expect(result.snapshot.xyz.sublist(6), <double>[7, 8, 9]);
    expect(result.failures, hasLength(1));
    expect(result.failures.single.stage, 'detector_free');
    expect(result.failures.single.message, 'native reader unavailable');
  });

  test(
    'B failure and uncaught worker exception both return exact sparse',
    () async {
      final source = snapshot();
      final bFailure = await BcdFinalizeWorker.startForTesting(
        captureId: 'b-failure',
        snapshot: source,
        durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
        options: const BcdFinalizeWorkerTestOptions(
          structuralBirthXyz: <double>[7, 8, 9],
          structuralBirthRgb: <int>[70, 80, 90],
          structuralFailure: 'B quality gate rejected',
        ),
      ).result;
      expect(bFailure.publication, 'sparseOnly');
      expect(bFailure.snapshot.xyz, source.xyz);
      expect(bFailure.snapshot.rgb, source.rgb);
      expect(bFailure.failures.single.stage, 'structural');

      final uncaught = await BcdFinalizeWorker.startForTesting(
        captureId: 'uncaught-failure',
        snapshot: source,
        durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
        options: const BcdFinalizeWorkerTestOptions(
          uncaughtFailure: 'synthetic crash',
        ),
      ).result;
      expect(uncaught.status, BcdFinalizeWorkerStatus.failed);
      expect(uncaught.publication, 'sparseOnly');
      expect(uncaught.snapshot.xyz, source.xyz);
      expect(uncaught.failures.single.stage, 'worker_exception');
      expect(uncaught.failures.single.message, contains('synthetic crash'));
    },
  );

  test('one worker per capture and cancellation are explicit', () async {
    final source = snapshot();
    final first = BcdFinalizeWorker.startForTesting(
      captureId: 'same-capture',
      snapshot: source,
      durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
      options: const BcdFinalizeWorkerTestOptions(
        busyFor: Duration(seconds: 2),
      ),
    );
    expect(BcdFinalizeWorker.isActive('same-capture'), isTrue);
    expect(
      () => BcdFinalizeWorker.startForTesting(
        captureId: 'same-capture',
        snapshot: source,
        durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
      ),
      throwsStateError,
    );

    await first.cancel('test requested cancellation');
    final cancelled = await first.result;
    expect(cancelled.status, BcdFinalizeWorkerStatus.cancelled);
    expect(cancelled.publication, 'sparseOnly');
    expect(cancelled.snapshot.xyz, source.xyz);
    expect(cancelled.failures.single.stage, 'cancelled');
    expect(BcdFinalizeWorker.isActive('same-capture'), isFalse);

    final replacement = BcdFinalizeWorker.startForTesting(
      captureId: 'same-capture',
      snapshot: source,
      durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
    );
    expect(
      (await replacement.result).status,
      BcdFinalizeWorkerStatus.completed,
    );
  });

  test(
    'strict production registry constructs native JPEG path reader in isolate',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'bcd-worker-native-reader-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final jpeg = File('${directory.path}/frame.jpg')
        ..writeAsBytesSync(base64Decode(_smallJpegBase64), flush: true);

      final result = await BcdFinalizeWorker.startForTesting(
        captureId: 'native-reader-probe',
        snapshot: snapshot(),
        durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
        options: BcdFinalizeWorkerTestOptions(
          nativeReaderProbe: BcdFinalizeWorkerNativeReaderProbe(
            jpegPath: jpeg.path,
          ),
        ),
      ).result;

      expect(result.status, BcdFinalizeWorkerStatus.completed);
      expect(
        result.stat('native_asset_reader_factory')?.value,
        'aether.jpeg-area.128x72.v1',
      );
      expect(
        result.stat('native_asset_rgb_digest')?.value,
        isA<String>().having((value) => value.length, 'length', 64),
      );
      expect(
        result.stat('native_asset_gray_digest')?.value,
        isA<String>().having((value) => value.length, 'length', 64),
      );
    },
    skip: Platform.environment['AETHER3D_FFI_DYLIB'] == null
        ? 'requires the exact current native test dylib'
        : false,
  );

  test(
    'null or unknown native reader IDs are explicitly unsupported',
    () async {
      final source = snapshot();
      for (final entry
          in <({String captureId, String? factoryId, String text})>[
            (
              captureId: 'null-native-reader',
              factoryId: null,
              text: 'is not installed',
            ),
            (
              captureId: 'unknown-native-reader',
              factoryId: 'experimental.reader.must-not-enter-product',
              text: 'experimental.reader.must-not-enter-product',
            ),
          ]) {
        final result = await BcdFinalizeWorker.startForTesting(
          captureId: entry.captureId,
          snapshot: source,
          durableFedFrames: <SfmDurableFedFrameInput>[frame(1)],
          options: BcdFinalizeWorkerTestOptions(
            nativeReaderProbe: BcdFinalizeWorkerNativeReaderProbe(
              jpegPath: '/unused.jpg',
              factoryId: entry.factoryId,
            ),
          ),
        ).result;

        expect(result.status, BcdFinalizeWorkerStatus.failed);
        expect(result.snapshot.xyz, source.xyz);
        expect(result.structuralBirthCount, 0);
        expect(result.detectorFreeBirthCount, 0);
        expect(result.failures.single.stage, 'worker_exception');
        expect(
          result.failures.single.message,
          allOf(
            contains('Unsupported operation'),
            contains(entry.text),
            contains('Dart/experimental asset readers disabled'),
          ),
        );
      }
    },
  );
}
