// Product JPEG asset reader for detector-free B/C/D finalize.
//
// Decode, INTER_AREA resize, RGB->gray conversion, and intrinsic scaling all
// happen in the shared native C++ core. This file deliberately has no
// package:image fallback: a missing symbol or malformed asset makes that frame
// unavailable to D instead of changing the certified photometric contract.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../detector_free_depth_ffi.dart';
import 'bcd_detector_free_job_builder.dart';
import 'bcd_finalize_coordinator.dart';
import 'bcd_finalize_input_builder.dart';

typedef BcdDetectorFreeJpegBytesLoader =
    Uint8List? Function(BcdFinalizeRegisteredFrameInput input);

const String bcdNativeDetectorFreeAssetReaderFactoryId =
    'aether.jpeg-area.128x72.v1';

/// Native, fail-closed implementation of [BcdDetectorFreeAssetReader].
///
/// Use [BcdNativeDetectorFreeAssetReader.path] for native app containers. It
/// passes the JPEG path directly across the C ABI and never materializes the
/// compressed or full-resolution image in Dart. Web/Wasm can use [bytes] with
/// bytes supplied by its platform asset layer.
final class BcdNativeDetectorFreeAssetReader
    implements BcdDetectorFreeAssetReader {
  static const String factoryId = bcdNativeDetectorFreeAssetReaderFactoryId;

  const BcdNativeDetectorFreeAssetReader.path() : _jpegBytesLoader = null;

  const BcdNativeDetectorFreeAssetReader.bytes({
    required BcdDetectorFreeJpegBytesLoader loadJpegBytes,
  }) : _jpegBytesLoader = loadJpegBytes;

  final BcdDetectorFreeJpegBytesLoader? _jpegBytesLoader;

  @override
  BcdDetectorFreeSolveAsset? readSolveAsset(
    BcdFinalizeRegisteredFrameInput input, {
    required int width,
    required int height,
  }) {
    if (width != detectorFreeImageWidth || height != detectorFreeImageHeight) {
      return null;
    }
    final frame = input.cameraFrame;
    if (!_validFrame(frame)) return null;

    final sourceK = <double>[
      frame.grayFx * frame.imageWidth / frame.grayWidth,
      0,
      frame.grayCx * frame.imageWidth / frame.grayWidth,
      0,
      frame.grayFy * frame.imageHeight / frame.grayHeight,
      frame.grayCy * frame.imageHeight / frame.grayHeight,
      0,
      0,
      1,
    ];
    try {
      final bytesLoader = _jpegBytesLoader;
      final DetectorFreePreprocessedImage decoded;
      if (bytesLoader == null) {
        decoded = DetectorFreeImagePreprocessor.fromJpegPath(
          jpegPath: frame.jpegPath,
          sourceK: sourceK,
        );
      } else {
        final bytes = bytesLoader(input);
        if (bytes == null) return null;
        decoded = DetectorFreeImagePreprocessor.fromJpegBytes(
          jpegBytes: bytes,
          sourceK: sourceK,
        );
      }
      if (!_matchesFrameContract(decoded, frame, sourceK)) return null;
      final rgb = Uint8List.fromList(decoded.rgbU8);
      final gray = Uint8List.fromList(decoded.grayU8);
      return BcdDetectorFreeSolveAsset(
        frameId: frame.frameId,
        width: detectorFreeImageWidth,
        height: detectorFreeImageHeight,
        gray: gray,
        rgb: rgb,
        grayDigest: sha256.convert(gray).toString(),
        rgbDigest: sha256.convert(rgb).toString(),
        provenance: BcdDetectorFreePhotometricProvenance.jpegRgbArea,
      );
    } on Object {
      // Missing native symbols, corrupt/truncated files, invalid native
      // metadata, and platform asset failures are all the same product truth:
      // this frame has no certified D photometric asset. Never substitute a
      // different decoder or durable gray source under certified provenance.
      return null;
    }
  }

  static bool _validFrame(BcdRegisteredCameraFrame frame) {
    final intrinsics = <double>[
      frame.grayFx,
      frame.grayFy,
      frame.grayCx,
      frame.grayCy,
    ];
    return frame.frameId >= 0 &&
        frame.jpegPath.isNotEmpty &&
        !frame.jpegPath.contains('\u0000') &&
        frame.imageWidth >= detectorFreeImageWidth &&
        frame.imageHeight >= detectorFreeImageHeight &&
        frame.imageWidth <= detectorFreeMaximumSourceSide &&
        frame.imageHeight <= detectorFreeMaximumSourceSide &&
        frame.grayWidth > 1 &&
        frame.grayHeight > 1 &&
        frame.grayWidth <= detectorFreeMaximumSourceSide &&
        frame.grayHeight <= detectorFreeMaximumSourceSide &&
        intrinsics.every((value) => value.isFinite) &&
        frame.grayFx > 0 &&
        frame.grayFy > 0;
  }

  static bool _matchesFrameContract(
    DetectorFreePreprocessedImage decoded,
    BcdRegisteredCameraFrame frame,
    List<double> sourceK,
  ) {
    if (decoded.sourceWidth != frame.imageWidth ||
        decoded.sourceHeight != frame.imageHeight ||
        decoded.width != detectorFreeImageWidth ||
        decoded.height != detectorFreeImageHeight ||
        decoded.rgbU8.length != detectorFreeImageRgbBytes ||
        decoded.grayU8.length != detectorFreeImagePixels ||
        decoded.scaledK.length != 9) {
      return false;
    }
    final scaleX = _float32(detectorFreeImageWidth / frame.imageWidth);
    final scaleY = _float32(detectorFreeImageHeight / frame.imageHeight);
    final expectedK = Float32List(9);
    for (var index = 0; index < expectedK.length; index++) {
      final rowScale = index ~/ 3 == 0
          ? scaleX
          : (index ~/ 3 == 1 ? scaleY : 1.0);
      expectedK[index] = _float32(_float32(sourceK[index]) * rowScale);
      if (!decoded.scaledK[index].isFinite ||
          decoded.scaledK[index] != expectedK[index]) {
        return false;
      }
    }
    return true;
  }

  static double _float32(double value) {
    final rounded = Float32List(1)..[0] = value;
    return rounded[0];
  }
}
