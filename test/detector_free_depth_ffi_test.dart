import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/detector_free_depth_ffi.dart';

DetectorFreeDepthOptions _options({
  int imageWidth = 8,
  int imageHeight = 6,
  int maxTileWidth = 4,
  int maxTileHeight = 3,
  int depthCount = 48,
  int sourceCount = 1,
  int patchN = 5,
  int minimumViews = 1,
  int exclusionRadiusSamples = 2,
  double minimumStdU8 = 6,
  double nccMin = 0.75,
  double uniqueDepthMargin = 0.03,
  double inverseDepthFirst = 0.25,
  double inverseDepthStep = 0.1,
  List<double> referenceInverseK = const [1, 0, 0, 0, 1, 0, 0, 0, 1],
}) => DetectorFreeDepthOptions(
  imageWidth: imageWidth,
  imageHeight: imageHeight,
  maxTileWidth: maxTileWidth,
  maxTileHeight: maxTileHeight,
  depthCount: depthCount,
  sourceCount: sourceCount,
  patchN: patchN,
  minimumViews: minimumViews,
  exclusionRadiusSamples: exclusionRadiusSamples,
  minimumStdU8: minimumStdU8,
  nccMin: nccMin,
  uniqueDepthMargin: uniqueDepthMargin,
  inverseDepthFirst: inverseDepthFirst,
  inverseDepthStep: inverseDepthStep,
  referenceInverseK: referenceInverseK,
);

Never _expectInvalidMetric({
  int imageWidth = 3,
  int imageHeight = 3,
  Float32List? referenceInverseK,
  Float32List? referenceDepthM,
  Uint8List? referenceAccepted,
  int reciprocalViewCount = 1,
  Float32List? reciprocalDepthsM,
  Uint8List? reciprocalAccepted,
  Float32List? referenceToReciprocalProjections,
  Float32List? reciprocalCameraCentersInReference,
  DetectorFreeReciprocalOptions options = const DetectorFreeReciprocalOptions(
    minimumReciprocalViews: 1,
    minimumParallaxDeg: 0,
  ),
}) {
  final pixels = imageWidth > 0 && imageHeight > 0
      ? imageWidth * imageHeight
      : 0;
  DetectorFreeReciprocalBirth.filterMetricDepths(
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    referenceInverseK:
        referenceInverseK ??
        Float32List.fromList(const [1, 0, 0, 0, 1, 0, 0, 0, 1]),
    referenceDepthM: referenceDepthM ?? Float32List(pixels),
    referenceAccepted: referenceAccepted ?? Uint8List(pixels),
    reciprocalViewCount: reciprocalViewCount,
    reciprocalDepthsM:
        reciprocalDepthsM ?? Float32List(reciprocalViewCount * pixels),
    reciprocalAccepted:
        reciprocalAccepted ?? Uint8List(reciprocalViewCount * pixels),
    referenceToReciprocalProjections:
        referenceToReciprocalProjections ??
        Float32List(reciprocalViewCount * 12),
    reciprocalCameraCentersInReference:
        reciprocalCameraCentersInReference ??
        Float32List(reciprocalViewCount * 3),
    options: options,
  );
  throw StateError('invalid metric input unexpectedly reached native');
}

void main() {
  test('native JPEG preprocessing freezes the 128x72 product grid', () {
    final jpeg = base64Decode(
      '/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCACQAQABAREA/8QAFQABAQAAAAAAAAAAAAAAAAAAAAH/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAA/AIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD//2Q==',
    );
    final image = DetectorFreeImagePreprocessor.fromJpegBytes(
      jpegBytes: jpeg,
      sourceK: const [200, 0, 128, 0, 180, 72, 0, 0, 1],
    );
    expect(image.sourceWidth, 256);
    expect(image.sourceHeight, 144);
    expect(image.width, detectorFreeImageWidth);
    expect(image.height, detectorFreeImageHeight);
    expect(image.rgbU8.length, detectorFreeImageRgbBytes);
    expect(image.grayU8.length, detectorFreeImagePixels);
    expect(image.scaleX, 0.5);
    expect(image.scaleY, 0.5);
    expect(
      image.scaledK,
      Float32List.fromList(const [100, 0, 64, 0, 90, 36, 0, 0, 1]),
    );
  });

  test('JPEG preprocessing rejects malformed inputs before publication', () {
    expect(
      () => DetectorFreeImagePreprocessor.fromJpegBytes(
        jpegBytes: Uint8List(0),
        sourceK: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
      ),
      throwsArgumentError,
    );
    expect(
      () => DetectorFreeImagePreprocessor.fromJpegBytes(
        jpegBytes: Uint8List.fromList(const [0xff, 0xd8, 0xff, 0xd9]),
        sourceK: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
      ),
      throwsStateError,
    );
    expect(
      () => DetectorFreeImagePreprocessor.fromJpegPath(
        jpegPath: 'bad\u0000path.jpg',
        sourceK: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
      ),
      throwsArgumentError,
    );
  });

  test('Dart depth options accept the exact native boundaries', () {
    expect(
      () => _options(
        imageWidth: 3,
        imageHeight: 3,
        maxTileWidth: 3,
        maxTileHeight: 3,
        depthCount: 2,
        patchN: 1,
        exclusionRadiusSamples: 0,
        nccMin: 0,
        uniqueDepthMargin: 2,
      ).validate(),
      returnsNormally,
    );
    expect(
      () => _options(
        imageWidth: 8192,
        imageHeight: 8192,
        maxTileWidth: 128,
        maxTileHeight: 72,
        depthCount: 64,
        patchN: 5,
        exclusionRadiusSamples: 63,
      ).validate(),
      returnsNormally,
    );
  });

  test('Dart depth options reject every widened native boundary', () {
    final invalid = <DetectorFreeDepthOptions>[
      _options(imageWidth: 2),
      _options(imageWidth: 8193),
      _options(imageHeight: 2),
      _options(imageHeight: 8193),
      _options(depthCount: 1),
      _options(depthCount: 65),
      _options(patchN: 0),
      _options(patchN: 2),
      _options(patchN: 7),
      _options(exclusionRadiusSamples: -1),
      _options(depthCount: 4, exclusionRadiusSamples: 4),
      _options(nccMin: -0.0001),
      _options(nccMin: 1.0001),
      _options(uniqueDepthMargin: 2.0001),
      _options(minimumStdU8: 1.7976931348623157e308),
      _options(
        referenceInverseK: const [
          1.7976931348623157e308,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
        ],
      ),
    ];

    for (final options in invalid) {
      expect(options.validate, throwsArgumentError);
    }
  });

  test('Dart rejects malformed detector-free dimensions before native', () {
    const options = DetectorFreeDepthOptions(
      imageWidth: 8,
      imageHeight: 6,
      sourceCount: 1,
      inverseDepthFirst: 0.25,
      inverseDepthStep: 0.1,
      referenceInverseK: [1, 0, 0, 0, 1, 0, 0, 0, 1],
      maxTileWidth: 4,
      maxTileHeight: 3,
      minimumViews: 1,
    );

    expect(
      () => DetectorFreeDepthSession.create(
        options: options,
        grayFrames: Float32List(8 * 6 * 2 - 1),
        sourceProjections: Float32List(12),
      ),
      throwsArgumentError,
    );
  });

  test('Dart rejects non-finite detector-free buffers before native', () {
    final options = _options();
    final gray = Float32List(8 * 6 * 2)..[0] = double.nan;
    final projections = Float32List(12);
    expect(
      () => DetectorFreeDepthSession.create(
        options: options,
        grayFrames: gray,
        sourceProjections: projections,
      ),
      throwsArgumentError,
    );

    gray[0] = 0;
    projections[0] = double.infinity;
    expect(
      () => DetectorFreeDepthSession.create(
        options: options,
        grayFrames: gray,
        sourceProjections: projections,
      ),
      throwsArgumentError,
    );
  });

  test('metric reciprocal preflight mirrors native value constraints', () {
    final accepted = Uint8List(9)..[4] = 1;
    final invalidDepth = Float32List(9)..[4] = 0.05;
    expect(
      () => _expectInvalidMetric(
        referenceDepthM: invalidDepth,
        referenceAccepted: accepted,
      ),
      throwsArgumentError,
    );

    final reciprocalAccepted = Uint8List(9)..[4] = 1;
    final reciprocalDepth = Float32List(9)..[4] = double.nan;
    expect(
      () => _expectInvalidMetric(
        reciprocalDepthsM: reciprocalDepth,
        reciprocalAccepted: reciprocalAccepted,
      ),
      throwsArgumentError,
    );

    expect(
      () => _expectInvalidMetric(referenceAccepted: Uint8List(9)..[0] = 2),
      throwsArgumentError,
    );
    expect(
      () => _expectInvalidMetric(reciprocalAccepted: Uint8List(9)..[0] = 2),
      throwsArgumentError,
    );
    expect(
      () => _expectInvalidMetric(
        referenceInverseK: Float32List.fromList(const [
          double.nan,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          1,
        ]),
      ),
      throwsArgumentError,
    );
    expect(
      () => _expectInvalidMetric(
        referenceToReciprocalProjections: Float32List(12)
          ..[0] = double.infinity,
      ),
      throwsArgumentError,
    );
    expect(
      () => _expectInvalidMetric(
        reciprocalCameraCentersInReference: Float32List(3)..[0] = double.nan,
      ),
      throwsArgumentError,
    );
    expect(
      () => _expectInvalidMetric(reciprocalViewCount: 256),
      throwsArgumentError,
    );
  });

  test('metric reciprocal birth requires independent depth agreement', () {
    const width = 3;
    const height = 3;
    const pixels = width * height;
    final referenceDepth = Float32List(pixels)..[4] = 2;
    final referenceAccepted = Uint8List(pixels)..[4] = 1;
    final reciprocalDepth = Float32List(pixels)..[4] = 2;
    final reciprocalAccepted = Uint8List(pixels)..[4] = 1;
    final result = DetectorFreeReciprocalBirth.filterMetricDepths(
      imageWidth: width,
      imageHeight: height,
      referenceInverseK: Float32List.fromList(const [
        1,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
      ]),
      referenceDepthM: referenceDepth,
      referenceAccepted: referenceAccepted,
      reciprocalViewCount: 1,
      reciprocalDepthsM: reciprocalDepth,
      reciprocalAccepted: reciprocalAccepted,
      referenceToReciprocalProjections: Float32List.fromList(const [
        1,
        0,
        0,
        -0.5,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      reciprocalCameraCentersInReference: Float32List.fromList(const [
        0.5,
        0,
        0,
      ]),
      options: const DetectorFreeReciprocalOptions(
        minimumReciprocalViews: 1,
        minimumParallaxDeg: 0,
      ),
    );

    expect(result.consistentViews[4], 1);
    expect(result.born[4], 1);
    expect(result.born.where((value) => value != 0).length, 1);

    reciprocalDepth[4] = 1;
    final conflict = DetectorFreeReciprocalBirth.filterMetricDepths(
      imageWidth: width,
      imageHeight: height,
      referenceInverseK: Float32List.fromList(const [
        1,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
      ]),
      referenceDepthM: referenceDepth,
      referenceAccepted: referenceAccepted,
      reciprocalViewCount: 1,
      reciprocalDepthsM: reciprocalDepth,
      reciprocalAccepted: reciprocalAccepted,
      referenceToReciprocalProjections: Float32List.fromList(const [
        1,
        0,
        0,
        -0.5,
        0,
        1,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      reciprocalCameraCentersInReference: Float32List.fromList(const [
        0.5,
        0,
        0,
      ]),
      options: const DetectorFreeReciprocalOptions(
        minimumReciprocalViews: 1,
        minimumParallaxDeg: 0,
      ),
    );

    expect(conflict.consistentViews[4], 0);
    expect(conflict.born[4], 0);
  });
}
