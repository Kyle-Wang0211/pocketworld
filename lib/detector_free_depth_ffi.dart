// Commercial-clean detector-free tiled depth C ABI.
//
// The numerical implementation lives in the shared C++/WGSL core. Dart owns
// only validated buffer transfer, capture-scoped lifetime, tile ordering, and
// the fail-closed reciprocal birth gate. Rejected samples never become product
// points, and this layer never mutates or removes an existing sparse point.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'aether_ffi.dart';

const int _maximumImageSide = 8192;
const double _minimumMetricDepthF32 = 0.05000000074505806;
const int detectorFreeImageWidth = 128;
const int detectorFreeImageHeight = 72;
const int detectorFreeImagePixels =
    detectorFreeImageWidth * detectorFreeImageHeight;
const int detectorFreeImageRgbBytes = detectorFreeImagePixels * 3;
const int detectorFreeMaximumSourceSide = 8192;
const int detectorFreeMaximumJpegBytes = 64 * 1024 * 1024;

double _asFloat32(double value) {
  final rounded = Float32List(1);
  rounded[0] = value;
  return rounded[0];
}

bool _isFiniteFloat32(double value) =>
    value.isFinite && _asFloat32(value).isFinite;

enum DetectorFreeDepthResult {
  ok,
  badArguments,
  unsupported,
  gpuFailure,
  bufferTooSmall,
  internalFailure,
}

enum DetectorFreeViewAggregation {
  topMinimum,
  trimmedAll,
  meanAll,
  topMinimumWithDissent,
}

DetectorFreeDepthResult _result(int code) {
  if (code < 0 || code >= DetectorFreeDepthResult.values.length) {
    return DetectorFreeDepthResult.internalFailure;
  }
  return DetectorFreeDepthResult.values[code];
}

final class _DetectorFreeOptions extends Struct {
  @Int32()
  external int imageWidth;
  @Int32()
  external int imageHeight;
  @Int32()
  external int maxTileWidth;
  @Int32()
  external int maxTileHeight;
  @Int32()
  external int depthCount;
  @Int32()
  external int sourceCount;
  @Int32()
  external int patchN;
  @Int32()
  external int minimumViews;
  @Int32()
  external int exclusionRadiusSamples;
  @Float()
  external double minimumStdU8;
  @Float()
  external double nccMin;
  @Float()
  external double uniqueDepthMargin;
  @Float()
  external double inverseDepthFirst;
  @Float()
  external double inverseDepthStep;
  @Array(9)
  external Array<Float> referenceInverseK;
}

final class _ReciprocalOptions extends Struct {
  @Int32()
  external int minimumReciprocalViews;
  @Float()
  external double absoluteDepthToleranceM;
  @Float()
  external double relativeDepthTolerance;
  @Float()
  external double minimumParallaxDeg;
}

final class _RefineOptions extends Struct {
  @Int32()
  external int fineDepthCount;
  @Float()
  external double coarseStepSpan;
  @Float()
  external double uniquenessAbsoluteM;
  @Float()
  external double uniquenessRelative;
}

final class _PreprocessedImage extends Struct {
  @Int32()
  external int sourceWidth;
  @Int32()
  external int sourceHeight;
  @Int32()
  external int outputWidth;
  @Int32()
  external int outputHeight;
  @Float()
  external double scaleX;
  @Float()
  external double scaleY;
  @Array(9)
  external Array<Float> scaledK;
}

typedef _OptionsDefaultC = Void Function(Pointer<_DetectorFreeOptions>);
typedef _OptionsDefaultDart = void Function(Pointer<_DetectorFreeOptions>);
typedef _ReciprocalDefaultC = Void Function(Pointer<_ReciprocalOptions>);
typedef _ReciprocalDefaultDart = void Function(Pointer<_ReciprocalOptions>);
typedef _RefineDefaultC = Void Function(Pointer<_RefineOptions>);
typedef _RefineDefaultDart = void Function(Pointer<_RefineOptions>);
typedef _SessionCreateC =
    Int32 Function(
      Pointer<_DetectorFreeOptions>,
      Pointer<Float>,
      UintPtr,
      Pointer<Float>,
      UintPtr,
      Pointer<Pointer<Void>>,
    );
typedef _SessionCreateDart =
    int Function(
      Pointer<_DetectorFreeOptions>,
      Pointer<Float>,
      int,
      Pointer<Float>,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _SetAggregationC = Int32 Function(Pointer<Void>, Int32);
typedef _SetAggregationDart = int Function(Pointer<Void>, int);
typedef _RunInterpolatedTileC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int32,
      Int32,
      Int32,
      Pointer<Uint16>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
    );
typedef _RunInterpolatedTileDart =
    int Function(
      Pointer<Void>,
      int,
      int,
      int,
      int,
      Pointer<Uint16>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
    );
typedef _RunRefinedTileC =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Int32,
      Int32,
      Int32,
      Pointer<Uint16>,
      Pointer<Uint8>,
      Pointer<_RefineOptions>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
    );
typedef _RunRefinedTileDart =
    int Function(
      Pointer<Void>,
      int,
      int,
      int,
      int,
      Pointer<Uint16>,
      Pointer<Uint8>,
      Pointer<_RefineOptions>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
    );
typedef _FilterReciprocalDepthsC =
    Int32 Function(
      Int32,
      Int32,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      Int32,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<_ReciprocalOptions>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Int32,
    );
typedef _FilterReciprocalDepthsDart =
    int Function(
      int,
      int,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<_ReciprocalOptions>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      int,
    );
typedef _SessionFreeC = Void Function(Pointer<Void>);
typedef _SessionFreeDart = void Function(Pointer<Void>);
typedef _PreprocessJpegBytesC =
    Int32 Function(
      Pointer<Uint8>,
      UintPtr,
      Pointer<Float>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Float>,
      UintPtr,
      Pointer<_PreprocessedImage>,
    );
typedef _PreprocessJpegBytesDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      int,
      Pointer<_PreprocessedImage>,
    );
typedef _PreprocessJpegPathC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Uint8>,
      UintPtr,
      Pointer<Float>,
      UintPtr,
      Pointer<_PreprocessedImage>,
    );
typedef _PreprocessJpegPathDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Float>,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      int,
      Pointer<_PreprocessedImage>,
    );

class _NativeDetectorFreeDepth {
  _NativeDetectorFreeDepth._();

  static DynamicLibrary get _library => AetherFfi.resolveLibraryForBindings();

  static final _OptionsDefaultDart optionsDefault = _library
      .lookupFunction<_OptionsDefaultC, _OptionsDefaultDart>(
        'aether_detector_free_options_default',
      );
  static final _ReciprocalDefaultDart reciprocalDefault = _library
      .lookupFunction<_ReciprocalDefaultC, _ReciprocalDefaultDart>(
        'aether_detector_free_reciprocal_options_default',
      );
  static final _RefineDefaultDart refineDefault = _library
      .lookupFunction<_RefineDefaultC, _RefineDefaultDart>(
        'aether_detector_free_refine_options_default',
      );
  static final _SessionCreateDart sessionCreate = _library
      .lookupFunction<_SessionCreateC, _SessionCreateDart>(
        'aether_detector_free_session_create',
      );
  static final _SetAggregationDart setAggregation = _library
      .lookupFunction<_SetAggregationC, _SetAggregationDart>(
        'aether_detector_free_session_set_view_aggregation',
      );
  static final _RunInterpolatedTileDart runInterpolatedTile = _library
      .lookupFunction<_RunInterpolatedTileC, _RunInterpolatedTileDart>(
        'aether_detector_free_session_run_interpolated_tile',
      );
  static final _RunRefinedTileDart runRefinedTile = _library
      .lookupFunction<_RunRefinedTileC, _RunRefinedTileDart>(
        'aether_detector_free_session_run_refined_tile',
      );
  static final _FilterReciprocalDepthsDart filterReciprocalDepths = _library
      .lookupFunction<_FilterReciprocalDepthsC, _FilterReciprocalDepthsDart>(
        'aether_detector_free_filter_reciprocal_depth_births',
      );
  static final _SessionFreeDart sessionFree = _library
      .lookupFunction<_SessionFreeC, _SessionFreeDart>(
        'aether_detector_free_session_free',
      );
  static _PreprocessJpegBytesDart? _preprocessJpegBytes;
  static _PreprocessJpegPathDart? _preprocessJpegPath;

  static _PreprocessJpegBytesDart get preprocessJpegBytes =>
      _preprocessJpegBytes ??= _lookupPreprocessBytes();

  static _PreprocessJpegPathDart get preprocessJpegPath =>
      _preprocessJpegPath ??= _lookupPreprocessPath();

  static _PreprocessJpegBytesDart _lookupPreprocessBytes() {
    try {
      return _library
          .lookupFunction<_PreprocessJpegBytesC, _PreprocessJpegBytesDart>(
            'aether_detector_free_preprocess_jpeg_bytes',
          );
    } catch (error) {
      throw FfiResolutionError(
        'Missing required product symbol '
        'aether_detector_free_preprocess_jpeg_bytes: $error',
      );
    }
  }

  static _PreprocessJpegPathDart _lookupPreprocessPath() {
    try {
      return _library
          .lookupFunction<_PreprocessJpegPathC, _PreprocessJpegPathDart>(
            'aether_detector_free_preprocess_jpeg_path',
          );
    } catch (error) {
      throw FfiResolutionError(
        'Missing required product symbol '
        'aether_detector_free_preprocess_jpeg_path: $error',
      );
    }
  }
}

class DetectorFreePreprocessedImage {
  const DetectorFreePreprocessedImage({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.rgbU8,
    required this.grayU8,
    required this.scaleX,
    required this.scaleY,
    required this.scaledK,
  });

  final int sourceWidth;
  final int sourceHeight;
  final Uint8List rgbU8;
  final Uint8List grayU8;
  final double scaleX;
  final double scaleY;
  final Float32List scaledK;

  int get width => detectorFreeImageWidth;
  int get height => detectorFreeImageHeight;
}

/// Bounded native preprocessing for the frozen detector-free image grid.
///
/// [fromJpegPath] is the product route on iOS/Android/HarmonyOS: Dart passes
/// only a path and never materializes a decoded 4K frame. [fromJpegBytes] is
/// the equivalent compressed-bytes entry point for Wasm/Web and tests. Both
/// calls are synchronous and must be invoked by the capture background
/// isolate, never by the UI isolate.
class DetectorFreeImagePreprocessor {
  DetectorFreeImagePreprocessor._();

  static DetectorFreePreprocessedImage fromJpegBytes({
    required Uint8List jpegBytes,
    required List<double> sourceK,
  }) {
    if (jpegBytes.isEmpty || jpegBytes.length > detectorFreeMaximumJpegBytes) {
      throw ArgumentError(
        'JPEG byte count must be in 1..$detectorFreeMaximumJpegBytes',
      );
    }
    return _preprocess(
      sourceK: sourceK,
      call: (nativeK, rgb, grayU8, grayF32, metadata) {
        final compressed = malloc<Uint8>(jpegBytes.length);
        try {
          compressed.asTypedList(jpegBytes.length).setAll(0, jpegBytes);
          return _NativeDetectorFreeDepth.preprocessJpegBytes(
            compressed,
            jpegBytes.length,
            nativeK,
            rgb,
            detectorFreeImageRgbBytes,
            grayU8,
            detectorFreeImagePixels,
            grayF32,
            detectorFreeImagePixels,
            metadata,
          );
        } finally {
          malloc.free(compressed);
        }
      },
    );
  }

  static DetectorFreePreprocessedImage fromJpegPath({
    required String jpegPath,
    required List<double> sourceK,
  }) {
    if (jpegPath.isEmpty || jpegPath.contains('\u0000')) {
      throw ArgumentError('invalid JPEG path');
    }
    final byteCount = _checkedJpegPathLength(jpegPath);
    if (byteCount <= 0 || byteCount > detectorFreeMaximumJpegBytes) {
      throw ArgumentError(
        'JPEG byte count must be in 1..$detectorFreeMaximumJpegBytes',
      );
    }
    return _preprocess(
      sourceK: sourceK,
      call: (nativeK, rgb, grayU8, grayF32, metadata) {
        final path = jpegPath.toNativeUtf8();
        try {
          return _NativeDetectorFreeDepth.preprocessJpegPath(
            path,
            nativeK,
            rgb,
            detectorFreeImageRgbBytes,
            grayU8,
            detectorFreeImagePixels,
            grayF32,
            detectorFreeImagePixels,
            metadata,
          );
        } finally {
          malloc.free(path);
        }
      },
    );
  }

  static DetectorFreePreprocessedImage _preprocess({
    required List<double> sourceK,
    required int Function(
      Pointer<Float>,
      Pointer<Uint8>,
      Pointer<Uint8>,
      Pointer<Float>,
      Pointer<_PreprocessedImage>,
    )
    call,
  }) {
    if (sourceK.length != 9 ||
        sourceK.any((value) => !_isFiniteFloat32(value)) ||
        !(sourceK[0] > 0) ||
        !(sourceK[4] > 0) ||
        _asFloat32(sourceK[8]) == 0) {
      throw ArgumentError('source intrinsics must contain 9 finite float32s');
    }
    final nativeK = malloc<Float>(9);
    final rgb = malloc<Uint8>(detectorFreeImageRgbBytes);
    final grayU8 = malloc<Uint8>(detectorFreeImagePixels);
    final grayF32 = malloc<Float>(detectorFreeImagePixels);
    final metadata = malloc<_PreprocessedImage>();
    try {
      nativeK.asTypedList(9).setAll(0, sourceK);
      final rc = call(nativeK, rgb, grayU8, grayF32, metadata);
      final result = _result(rc);
      if (result != DetectorFreeDepthResult.ok) {
        throw StateError('detector-free JPEG preprocess failed: $result');
      }
      if (metadata.ref.outputWidth != detectorFreeImageWidth ||
          metadata.ref.outputHeight != detectorFreeImageHeight ||
          metadata.ref.sourceWidth < detectorFreeImageWidth ||
          metadata.ref.sourceHeight < detectorFreeImageHeight ||
          metadata.ref.sourceWidth > detectorFreeMaximumSourceSide ||
          metadata.ref.sourceHeight > detectorFreeMaximumSourceSide ||
          !_validScale(
            metadata.ref.scaleX,
            detectorFreeImageWidth,
            metadata.ref.sourceWidth,
          ) ||
          !_validScale(
            metadata.ref.scaleY,
            detectorFreeImageHeight,
            metadata.ref.sourceHeight,
          )) {
        throw StateError('native detector-free image metadata is invalid');
      }
      final scaledK = Float32List(9);
      for (var index = 0; index < 9; index++) {
        scaledK[index] = metadata.ref.scaledK[index];
        final rowScale = index ~/ 3 == 0
            ? metadata.ref.scaleX
            : (index ~/ 3 == 1 ? metadata.ref.scaleY : 1.0);
        final expected = _asFloat32(_asFloat32(sourceK[index]) * rowScale);
        if (!scaledK[index].isFinite || scaledK[index] != expected) {
          throw StateError(
            'native detector-free scaled intrinsics are invalid',
          );
        }
      }
      final nativeGrayF32 = grayF32.asTypedList(detectorFreeImagePixels);
      final nativeGrayU8 = grayU8.asTypedList(detectorFreeImagePixels);
      for (var index = 0; index < detectorFreeImagePixels; index++) {
        if (!nativeGrayF32[index].isFinite ||
            nativeGrayF32[index] != nativeGrayU8[index].toDouble()) {
          throw StateError('native detector-free gray planes disagree');
        }
      }
      return DetectorFreePreprocessedImage(
        sourceWidth: metadata.ref.sourceWidth,
        sourceHeight: metadata.ref.sourceHeight,
        rgbU8: Uint8List.fromList(rgb.asTypedList(detectorFreeImageRgbBytes)),
        grayU8: Uint8List.fromList(nativeGrayU8),
        scaleX: metadata.ref.scaleX,
        scaleY: metadata.ref.scaleY,
        scaledK: scaledK,
      );
    } finally {
      malloc.free(nativeK);
      malloc.free(rgb);
      malloc.free(grayU8);
      malloc.free(grayF32);
      malloc.free(metadata);
    }
  }

  static int _checkedJpegPathLength(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException catch (error) {
      throw StateError('JPEG path is not readable: $error');
    }
  }

  static bool _validScale(double actual, int output, int source) =>
      actual.isFinite &&
      actual > 0 &&
      actual <= 1 &&
      actual == _asFloat32(output / source);
}

class DetectorFreeDepthOptions {
  const DetectorFreeDepthOptions({
    required this.imageWidth,
    required this.imageHeight,
    required this.sourceCount,
    required this.inverseDepthFirst,
    required this.inverseDepthStep,
    required this.referenceInverseK,
    this.maxTileWidth = 128,
    this.maxTileHeight = 72,
    this.depthCount = 48,
    this.patchN = 5,
    this.minimumViews = 4,
    this.exclusionRadiusSamples = 2,
    this.minimumStdU8 = 6,
    this.nccMin = 0.75,
    this.uniqueDepthMargin = 0.03,
  });

  final int imageWidth;
  final int imageHeight;
  final int maxTileWidth;
  final int maxTileHeight;
  final int depthCount;
  final int sourceCount;
  final int patchN;
  final int minimumViews;
  final int exclusionRadiusSamples;
  final double minimumStdU8;
  final double nccMin;
  final double uniqueDepthMargin;
  final double inverseDepthFirst;
  final double inverseDepthStep;
  final List<double> referenceInverseK;

  void validate() {
    final inverseDepthFirstF32 = _asFloat32(inverseDepthFirst);
    final inverseDepthStepF32 = _asFloat32(inverseDepthStep);
    final scaledStepF32 = _asFloat32(
      _asFloat32((depthCount - 1).toDouble()) * inverseDepthStepF32,
    );
    final lastInverseDepthF32 = _asFloat32(
      inverseDepthFirstF32 + scaledStepF32,
    );
    if (imageWidth <= 2 ||
        imageHeight <= 2 ||
        imageWidth > _maximumImageSide ||
        imageHeight > _maximumImageSide ||
        maxTileWidth <= 0 ||
        maxTileHeight <= 0 ||
        maxTileWidth > imageWidth ||
        maxTileHeight > imageHeight ||
        depthCount < 2 ||
        depthCount > 64 ||
        sourceCount <= 0 ||
        sourceCount > 8 ||
        minimumViews <= 0 ||
        minimumViews > sourceCount ||
        patchN < 1 ||
        patchN > 5 ||
        patchN.isEven ||
        exclusionRadiusSamples < 0 ||
        exclusionRadiusSamples >= depthCount ||
        referenceInverseK.length != 9 ||
        referenceInverseK.any((value) => !_isFiniteFloat32(value)) ||
        !_isFiniteFloat32(inverseDepthFirst) ||
        inverseDepthFirstF32 <= 0 ||
        !_isFiniteFloat32(inverseDepthStep) ||
        inverseDepthStepF32 == 0 ||
        !lastInverseDepthF32.isFinite ||
        lastInverseDepthF32 <= 0 ||
        !_isFiniteFloat32(minimumStdU8) ||
        _asFloat32(minimumStdU8) <= 0 ||
        !_isFiniteFloat32(nccMin) ||
        _asFloat32(nccMin) < 0 ||
        _asFloat32(nccMin) > 1 ||
        !_isFiniteFloat32(uniqueDepthMargin) ||
        _asFloat32(uniqueDepthMargin) < 0 ||
        _asFloat32(uniqueDepthMargin) > 2) {
      throw ArgumentError('invalid detector-free depth options');
    }
  }
}

class DetectorFreeRefineOptions {
  const DetectorFreeRefineOptions({
    this.fineDepthCount = 17,
    this.coarseStepSpan = 1,
    this.uniquenessAbsoluteM = 0.08,
    this.uniquenessRelative = 0.05,
  });

  final int fineDepthCount;
  final double coarseStepSpan;
  final double uniquenessAbsoluteM;
  final double uniquenessRelative;

  void validate() {
    if (fineDepthCount < 3 ||
        fineDepthCount > 64 ||
        fineDepthCount.isEven ||
        !_isFiniteFloat32(coarseStepSpan) ||
        _asFloat32(coarseStepSpan) <= 0 ||
        _asFloat32(coarseStepSpan) > 2 ||
        !_isFiniteFloat32(uniquenessAbsoluteM) ||
        _asFloat32(uniquenessAbsoluteM) <= 0 ||
        _asFloat32(uniquenessAbsoluteM) > 2 ||
        !_isFiniteFloat32(uniquenessRelative) ||
        _asFloat32(uniquenessRelative) < 0 ||
        _asFloat32(uniquenessRelative) > 1) {
      throw ArgumentError('invalid detector-free refine options');
    }
  }
}

class DetectorFreeReciprocalOptions {
  const DetectorFreeReciprocalOptions({
    this.minimumReciprocalViews = 2,
    this.absoluteDepthToleranceM = 0.08,
    this.relativeDepthTolerance = 0.05,
    this.minimumParallaxDeg = 8,
  });

  final int minimumReciprocalViews;
  final double absoluteDepthToleranceM;
  final double relativeDepthTolerance;
  final double minimumParallaxDeg;

  void validate(int reciprocalViewCount) {
    if (reciprocalViewCount <= 0 ||
        reciprocalViewCount > 255 ||
        minimumReciprocalViews <= 0 ||
        minimumReciprocalViews > reciprocalViewCount ||
        !_isFiniteFloat32(absoluteDepthToleranceM) ||
        _asFloat32(absoluteDepthToleranceM) <= 0 ||
        !_isFiniteFloat32(relativeDepthTolerance) ||
        _asFloat32(relativeDepthTolerance) < 0 ||
        !_isFiniteFloat32(minimumParallaxDeg) ||
        _asFloat32(minimumParallaxDeg) < 0 ||
        _asFloat32(minimumParallaxDeg) > 180) {
      throw ArgumentError('invalid detector-free reciprocal options');
    }
  }
}

class DetectorFreeTileResult {
  const DetectorFreeTileResult({
    required this.bestIndex,
    required this.depthM,
    required this.peakMinimumNeighborDrop,
    required this.bestScore,
    required this.secondScore,
    required this.supportingViews,
    required this.accepted,
  });

  final Uint16List bestIndex;
  final Float32List depthM;
  final Float32List peakMinimumNeighborDrop;
  final Float32List bestScore;
  final Float32List secondScore;
  final Uint8List supportingViews;
  final Uint8List accepted;
}

class DetectorFreeRefinedTileResult {
  const DetectorFreeRefinedTileResult({
    required this.depthM,
    required this.bestScore,
    required this.secondScore,
    required this.supportingViews,
    required this.accepted,
  });

  final Float32List depthM;
  final Float32List bestScore;
  final Float32List secondScore;
  final Uint8List supportingViews;
  final Uint8List accepted;
}

class DetectorFreeReciprocalBirthResult {
  const DetectorFreeReciprocalBirthResult({
    required this.consistentViews,
    required this.born,
  });

  final Uint8List consistentViews;
  final Uint8List born;
}

class DetectorFreeDepthSession {
  DetectorFreeDepthSession._(this._session, this.options);

  Pointer<Void> _session;
  final DetectorFreeDepthOptions options;

  static DetectorFreeDepthSession create({
    required DetectorFreeDepthOptions options,
    required Float32List grayFrames,
    required Float32List sourceProjections,
  }) {
    options.validate();
    final pixels = options.imageWidth * options.imageHeight;
    final expectedGray = pixels * (options.sourceCount + 1);
    final expectedProjections = options.sourceCount * 12;
    if (grayFrames.length != expectedGray ||
        sourceProjections.length != expectedProjections ||
        grayFrames.any((value) => !value.isFinite) ||
        sourceProjections.any((value) => !value.isFinite)) {
      throw ArgumentError('detector-free input dimensions do not match');
    }
    final nativeOptions = malloc<_DetectorFreeOptions>();
    final gray = malloc<Float>(grayFrames.length);
    final projections = malloc<Float>(sourceProjections.length);
    final out = malloc<Pointer<Void>>();
    try {
      _NativeDetectorFreeDepth.optionsDefault(nativeOptions);
      nativeOptions.ref
        ..imageWidth = options.imageWidth
        ..imageHeight = options.imageHeight
        ..maxTileWidth = options.maxTileWidth
        ..maxTileHeight = options.maxTileHeight
        ..depthCount = options.depthCount
        ..sourceCount = options.sourceCount
        ..patchN = options.patchN
        ..minimumViews = options.minimumViews
        ..exclusionRadiusSamples = options.exclusionRadiusSamples
        ..minimumStdU8 = options.minimumStdU8
        ..nccMin = options.nccMin
        ..uniqueDepthMargin = options.uniqueDepthMargin
        ..inverseDepthFirst = options.inverseDepthFirst
        ..inverseDepthStep = options.inverseDepthStep;
      for (var index = 0; index < 9; index++) {
        nativeOptions.ref.referenceInverseK[index] =
            options.referenceInverseK[index];
      }
      gray.asTypedList(grayFrames.length).setAll(0, grayFrames);
      projections
          .asTypedList(sourceProjections.length)
          .setAll(0, sourceProjections);
      out.value = nullptr;
      final rc = _NativeDetectorFreeDepth.sessionCreate(
        nativeOptions,
        gray,
        grayFrames.length,
        projections,
        sourceProjections.length,
        out,
      );
      if (_result(rc) != DetectorFreeDepthResult.ok || out.value == nullptr) {
        throw StateError(
          'aether_detector_free_session_create failed: ${_result(rc)}',
        );
      }
      return DetectorFreeDepthSession._(out.value, options);
    } finally {
      malloc.free(nativeOptions);
      malloc.free(gray);
      malloc.free(projections);
      malloc.free(out);
    }
  }

  void setViewAggregation(DetectorFreeViewAggregation aggregation) {
    _checkLive();
    final rc = _NativeDetectorFreeDepth.setAggregation(
      _session,
      aggregation.index,
    );
    if (_result(rc) != DetectorFreeDepthResult.ok) {
      throw StateError(
        'aether_detector_free_session_set_view_aggregation failed: '
        '${_result(rc)}',
      );
    }
  }

  DetectorFreeTileResult runInterpolatedTile({
    required int originX,
    required int originY,
    required int width,
    required int height,
  }) {
    _checkTile(originX, originY, width, height);
    final count = width * height;
    final bestIndex = malloc<Uint16>(count);
    final depth = malloc<Float>(count);
    final peakDrop = malloc<Float>(count);
    final best = malloc<Float>(count);
    final second = malloc<Float>(count);
    final supportingViews = malloc<Uint8>(count);
    final accepted = malloc<Uint8>(count);
    try {
      final rc = _NativeDetectorFreeDepth.runInterpolatedTile(
        _session,
        originX,
        originY,
        width,
        height,
        bestIndex,
        depth,
        peakDrop,
        best,
        second,
        supportingViews,
        accepted,
        count,
      );
      if (_result(rc) != DetectorFreeDepthResult.ok) {
        throw StateError(
          'aether_detector_free_session_run_interpolated_tile failed: '
          '${_result(rc)}',
        );
      }
      return DetectorFreeTileResult(
        bestIndex: Uint16List.fromList(bestIndex.asTypedList(count)),
        depthM: Float32List.fromList(depth.asTypedList(count)),
        peakMinimumNeighborDrop: Float32List.fromList(
          peakDrop.asTypedList(count),
        ),
        bestScore: Float32List.fromList(best.asTypedList(count)),
        secondScore: Float32List.fromList(second.asTypedList(count)),
        supportingViews: Uint8List.fromList(supportingViews.asTypedList(count)),
        accepted: Uint8List.fromList(accepted.asTypedList(count)),
      );
    } finally {
      malloc.free(bestIndex);
      malloc.free(depth);
      malloc.free(peakDrop);
      malloc.free(best);
      malloc.free(second);
      malloc.free(supportingViews);
      malloc.free(accepted);
    }
  }

  DetectorFreeRefinedTileResult runRefinedTile({
    required int originX,
    required int originY,
    required int width,
    required int height,
    required Uint16List coarseBestIndex,
    required Uint8List coarseAccepted,
    DetectorFreeRefineOptions refineOptions = const DetectorFreeRefineOptions(),
  }) {
    _checkTile(originX, originY, width, height);
    refineOptions.validate();
    final count = width * height;
    if (coarseBestIndex.length != count ||
        coarseAccepted.length != count ||
        coarseBestIndex.any((index) => index >= options.depthCount) ||
        coarseAccepted.any((accepted) => accepted > 1)) {
      throw ArgumentError('coarse tile dimensions do not match');
    }
    final coarseIndex = malloc<Uint16>(count);
    final coarseMask = malloc<Uint8>(count);
    final nativeOptions = malloc<_RefineOptions>();
    final depth = malloc<Float>(count);
    final best = malloc<Float>(count);
    final second = malloc<Float>(count);
    final supportingViews = malloc<Uint8>(count);
    final accepted = malloc<Uint8>(count);
    try {
      coarseIndex.asTypedList(count).setAll(0, coarseBestIndex);
      coarseMask.asTypedList(count).setAll(0, coarseAccepted);
      _NativeDetectorFreeDepth.refineDefault(nativeOptions);
      nativeOptions.ref
        ..fineDepthCount = refineOptions.fineDepthCount
        ..coarseStepSpan = refineOptions.coarseStepSpan
        ..uniquenessAbsoluteM = refineOptions.uniquenessAbsoluteM
        ..uniquenessRelative = refineOptions.uniquenessRelative;
      final rc = _NativeDetectorFreeDepth.runRefinedTile(
        _session,
        originX,
        originY,
        width,
        height,
        coarseIndex,
        coarseMask,
        nativeOptions,
        depth,
        best,
        second,
        supportingViews,
        accepted,
        count,
      );
      if (_result(rc) != DetectorFreeDepthResult.ok) {
        throw StateError(
          'aether_detector_free_session_run_refined_tile failed: '
          '${_result(rc)}',
        );
      }
      return DetectorFreeRefinedTileResult(
        depthM: Float32List.fromList(depth.asTypedList(count)),
        bestScore: Float32List.fromList(best.asTypedList(count)),
        secondScore: Float32List.fromList(second.asTypedList(count)),
        supportingViews: Uint8List.fromList(supportingViews.asTypedList(count)),
        accepted: Uint8List.fromList(accepted.asTypedList(count)),
      );
    } finally {
      malloc.free(coarseIndex);
      malloc.free(coarseMask);
      malloc.free(nativeOptions);
      malloc.free(depth);
      malloc.free(best);
      malloc.free(second);
      malloc.free(supportingViews);
      malloc.free(accepted);
    }
  }

  void dispose() {
    if (_session == nullptr) return;
    _NativeDetectorFreeDepth.sessionFree(_session);
    _session = nullptr;
  }

  void _checkLive() {
    if (_session == nullptr) throw StateError('detector-free session disposed');
  }

  void _checkTile(int originX, int originY, int width, int height) {
    _checkLive();
    if (originX < 0 ||
        originY < 0 ||
        width <= 0 ||
        height <= 0 ||
        width > options.maxTileWidth ||
        height > options.maxTileHeight ||
        originX + width > options.imageWidth ||
        originY + height > options.imageHeight) {
      throw ArgumentError('invalid detector-free tile bounds');
    }
  }
}

class DetectorFreeReciprocalBirth {
  DetectorFreeReciprocalBirth._();

  static DetectorFreeReciprocalBirthResult filterMetricDepths({
    required int imageWidth,
    required int imageHeight,
    required Float32List referenceInverseK,
    required Float32List referenceDepthM,
    required Uint8List referenceAccepted,
    required int reciprocalViewCount,
    required Float32List reciprocalDepthsM,
    required Uint8List reciprocalAccepted,
    required Float32List referenceToReciprocalProjections,
    required Float32List reciprocalCameraCentersInReference,
    DetectorFreeReciprocalOptions options =
        const DetectorFreeReciprocalOptions(),
  }) {
    options.validate(reciprocalViewCount);
    if (imageWidth <= 0 ||
        imageHeight <= 0 ||
        imageWidth > _maximumImageSide ||
        imageHeight > _maximumImageSide) {
      throw ArgumentError('invalid reciprocal birth image dimensions');
    }
    final pixels = imageWidth * imageHeight;
    if (referenceInverseK.length != 9 ||
        referenceDepthM.length != pixels ||
        referenceAccepted.length != pixels ||
        reciprocalDepthsM.length != reciprocalViewCount * pixels ||
        reciprocalAccepted.length != reciprocalViewCount * pixels ||
        referenceToReciprocalProjections.length != reciprocalViewCount * 12 ||
        reciprocalCameraCentersInReference.length != reciprocalViewCount * 3) {
      throw ArgumentError('reciprocal birth dimensions do not match');
    }
    if (referenceInverseK.any((value) => !value.isFinite) ||
        referenceToReciprocalProjections.any((value) => !value.isFinite) ||
        reciprocalCameraCentersInReference.any((value) => !value.isFinite) ||
        referenceAccepted.any((accepted) => accepted > 1) ||
        reciprocalAccepted.any((accepted) => accepted > 1)) {
      throw ArgumentError('invalid reciprocal birth values');
    }
    for (var pixel = 0; pixel < pixels; pixel++) {
      if (referenceAccepted[pixel] != 0 &&
          (!referenceDepthM[pixel].isFinite ||
              referenceDepthM[pixel] <= _minimumMetricDepthF32)) {
        throw ArgumentError('invalid accepted reference depth');
      }
    }
    for (var offset = 0; offset < reciprocalDepthsM.length; offset++) {
      if (reciprocalAccepted[offset] != 0 &&
          (!reciprocalDepthsM[offset].isFinite ||
              reciprocalDepthsM[offset] <= _minimumMetricDepthF32)) {
        throw ArgumentError('invalid accepted reciprocal depth');
      }
    }
    final inverseK = malloc<Float>(9);
    final referenceDepth = malloc<Float>(pixels);
    final referenceMask = malloc<Uint8>(pixels);
    final reciprocalDepth = malloc<Float>(reciprocalDepthsM.length);
    final reciprocalMask = malloc<Uint8>(reciprocalAccepted.length);
    final projections = malloc<Float>(referenceToReciprocalProjections.length);
    final centers = malloc<Float>(reciprocalCameraCentersInReference.length);
    final nativeOptions = malloc<_ReciprocalOptions>();
    final consistent = malloc<Uint8>(pixels);
    final born = malloc<Uint8>(pixels);
    try {
      inverseK.asTypedList(9).setAll(0, referenceInverseK);
      referenceDepth.asTypedList(pixels).setAll(0, referenceDepthM);
      referenceMask.asTypedList(pixels).setAll(0, referenceAccepted);
      reciprocalDepth
          .asTypedList(reciprocalDepthsM.length)
          .setAll(0, reciprocalDepthsM);
      reciprocalMask
          .asTypedList(reciprocalAccepted.length)
          .setAll(0, reciprocalAccepted);
      projections
          .asTypedList(referenceToReciprocalProjections.length)
          .setAll(0, referenceToReciprocalProjections);
      centers
          .asTypedList(reciprocalCameraCentersInReference.length)
          .setAll(0, reciprocalCameraCentersInReference);
      _NativeDetectorFreeDepth.reciprocalDefault(nativeOptions);
      nativeOptions.ref
        ..minimumReciprocalViews = options.minimumReciprocalViews
        ..absoluteDepthToleranceM = options.absoluteDepthToleranceM
        ..relativeDepthTolerance = options.relativeDepthTolerance
        ..minimumParallaxDeg = options.minimumParallaxDeg;
      final rc = _NativeDetectorFreeDepth.filterReciprocalDepths(
        imageWidth,
        imageHeight,
        inverseK,
        referenceDepth,
        referenceMask,
        reciprocalViewCount,
        reciprocalDepth,
        reciprocalMask,
        projections,
        centers,
        nativeOptions,
        consistent,
        born,
        pixels,
      );
      if (_result(rc) != DetectorFreeDepthResult.ok) {
        throw StateError(
          'aether_detector_free_filter_reciprocal_depth_births failed: '
          '${_result(rc)}',
        );
      }
      return DetectorFreeReciprocalBirthResult(
        consistentViews: Uint8List.fromList(consistent.asTypedList(pixels)),
        born: Uint8List.fromList(born.asTypedList(pixels)),
      );
    } finally {
      malloc.free(inverseK);
      malloc.free(referenceDepth);
      malloc.free(referenceMask);
      malloc.free(reciprocalDepth);
      malloc.free(reciprocalMask);
      malloc.free(projections);
      malloc.free(centers);
      malloc.free(nativeOptions);
      malloc.free(consistent);
      malloc.free(born);
    }
  }
}
