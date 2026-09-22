import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_input_builder.dart';
import 'package:pocketworld_flutter/capture/bcd_native_asset_reader.dart';
import 'package:pocketworld_flutter/detector_free_depth_ffi.dart';

const _smallJpegBase64 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCACQAQABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//2Q==';

const _realJpegRelativePath =
    '.config/superpowers/worktrees/'
    'pocketworld_research_benchmarks/pocketworld-repro-contract-20260714/'
    'data/pocketworld_captures/cap41/device_2026-07-16/photos_highres/'
    'cell_97_slot_5.jpg';

BcdFinalizeRegisteredFrameInput _input(
  String jpegPath, {
  int imageWidth = 256,
  int imageHeight = 144,
  int grayWidth = 256,
  int grayHeight = 144,
  double grayFx = 200,
  double grayFy = 180,
  double grayCx = 128,
  double grayCy = 72,
  String grayPath = '/must-not-be-used.sfm-gray',
}) => BcdFinalizeRegisteredFrameInput(
  cameraFrame: BcdRegisteredCameraFrame(
    frameId: 23,
    jpegPath: jpegPath,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    grayWidth: grayWidth,
    grayHeight: grayHeight,
    grayFx: grayFx,
    grayFy: grayFy,
    grayCx: grayCx,
    grayCy: grayCy,
    cameraFromWorldQuaternionWxyz: const <double>[1, 0, 0, 0],
    cameraFromWorldTranslation: const <double>[0, 0, 0],
  ),
  grayPath: grayPath,
);

void main() {
  late Directory temporaryDirectory;
  late Uint8List smallJpeg;
  late File smallJpegFile;

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync(
      'bcd-native-reader-',
    );
    smallJpeg = base64Decode(_smallJpegBase64);
    smallJpegFile = File('${temporaryDirectory.path}/frame.jpg')
      ..writeAsBytesSync(smallJpeg, flush: true);
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  test('native path and Web bytes routes publish the same certified asset', () {
    final input = _input(smallJpegFile.path);
    final pathAsset = const BcdNativeDetectorFreeAssetReader.path()
        .readSolveAsset(input, width: 128, height: 72);
    final bytesAsset = BcdNativeDetectorFreeAssetReader.bytes(
      loadJpegBytes: (_) => smallJpeg,
    ).readSolveAsset(input, width: 128, height: 72);

    expect(pathAsset, isNotNull);
    expect(bytesAsset, isNotNull);
    expect(pathAsset!.width, 128);
    expect(pathAsset.height, 72);
    expect(pathAsset.rgb, orderedEquals(bytesAsset!.rgb!));
    expect(pathAsset.gray, orderedEquals(bytesAsset.gray));
    expect(pathAsset.rgbDigest, bytesAsset.rgbDigest);
    expect(pathAsset.grayDigest, bytesAsset.grayDigest);
    expect(pathAsset.rgb, hasLength(128 * 72 * 3));
    expect(pathAsset.gray, hasLength(128 * 72));
  });

  test('native reader fails closed for corrupt, absent, and empty JPEGs', () {
    final corrupt = File('${temporaryDirectory.path}/corrupt.jpg')
      ..writeAsBytesSync(const <int>[0xff, 0xd8, 0xff, 0xd9], flush: true);
    final empty = File('${temporaryDirectory.path}/empty.jpg')
      ..writeAsBytesSync(const <int>[], flush: true);
    final oversized = File('${temporaryDirectory.path}/oversized.jpg');
    final oversizedHandle = oversized.openSync(mode: FileMode.write);
    oversizedHandle.truncateSync(detectorFreeMaximumJpegBytes + 1);
    oversizedHandle.closeSync();
    final validGray = File('${temporaryDirectory.path}/fallback.sfm-gray')
      ..writeAsBytesSync(List<int>.filled(256 * 144, 91), flush: true);
    const reader = BcdNativeDetectorFreeAssetReader.path();

    for (final path in <String>[
      corrupt.path,
      empty.path,
      oversized.path,
      '${temporaryDirectory.path}/missing.jpg',
    ]) {
      expect(
        reader.readSolveAsset(
          _input(path, grayPath: validGray.path),
          width: 128,
          height: 72,
        ),
        isNull,
        reason: 'certified product must not fall back to durable gray: $path',
      );
    }
    final bytesReader = BcdNativeDetectorFreeAssetReader.bytes(
      loadJpegBytes: (_) => Uint8List(0),
    );
    expect(
      bytesReader.readSolveAsset(
        _input('/browser/frame.jpg'),
        width: 128,
        height: 72,
      ),
      isNull,
    );
  });

  test(
    'declared/decoded dimension drift and oversized metadata fail closed',
    () {
      const reader = BcdNativeDetectorFreeAssetReader.path();
      expect(
        reader.readSolveAsset(
          _input(smallJpegFile.path, imageWidth: 3840, imageHeight: 2160),
          width: 128,
          height: 72,
        ),
        isNull,
      );
      expect(
        reader.readSolveAsset(
          _input(smallJpegFile.path, imageWidth: 8193),
          width: 128,
          height: 72,
        ),
        isNull,
      );
      expect(
        reader.readSolveAsset(
          _input(smallJpegFile.path),
          width: 127,
          height: 72,
        ),
        isNull,
      );
      expect(
        reader.readSolveAsset(
          _input(smallJpegFile.path, grayFx: double.nan),
          width: 128,
          height: 72,
        ),
        isNull,
      );
    },
  );

  final home = Platform.environment['HOME'];
  final realJpeg = home == null ? null : File('$home/$_realJpegRelativePath');
  test(
    'real cap41 JPEG is byte-exact with frozen Pillow/OpenCV golden',
    () {
      final direct = DetectorFreeImagePreprocessor.fromJpegPath(
        jpegPath: realJpeg!.path,
        sourceK: const <double>[3000, 0, 1920, 0, 3000, 1080, 0, 0, 1],
      );
      expect(direct.sourceWidth, 3840);
      expect(direct.sourceHeight, 2160);
      final input = _input(
        realJpeg.path,
        imageWidth: 3840,
        imageHeight: 2160,
        grayWidth: 3840,
        grayHeight: 2160,
        grayFx: 3000,
        grayFy: 3000,
        grayCx: 1920,
        grayCy: 1080,
      );
      final asset = const BcdNativeDetectorFreeAssetReader.path()
          .readSolveAsset(input, width: 128, height: 72);
      expect(asset, isNotNull);
      expect(
        asset!.rgbDigest,
        '35f73c82b473ebdc60bbc944349d23d88d4cadb384b3b8cf49b03adc46664ad3',
      );
      expect(
        asset.grayDigest,
        'c343797dd66c0df3c04b31faccc94d322d750b9148494ee31733231eb0277e5e',
      );
    },
    skip: realJpeg?.existsSync() != true
        ? 'cap41 DVC JPEG is not materialized in this checkout'
        : false,
  );

  test(
    'missing preprocess symbols fail closed without Dart decoder fallback',
    () {
      final asset = const BcdNativeDetectorFreeAssetReader.path()
          .readSolveAsset(_input(smallJpegFile.path), width: 128, height: 72);
      expect(asset, isNull);
    },
    skip: Platform.environment['BCD_TEST_MISSING_PREPROCESS_SYMBOLS'] != '1'
        ? 'run in a fresh process pinned to a pre-preprocess dylib'
        : false,
  );
}
