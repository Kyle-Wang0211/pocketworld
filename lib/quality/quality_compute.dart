// QualityCompute — pure Dart port of the per-frame quality metrics
// previously computed in `ios/Runner/AetherARKitPlugin.swift::computeQuality`.
//
// What it does, given a 128×128 8-bit grayscale thumbnail (one byte per
// pixel, row-major, top-left origin):
//
//   1. Laplacian variance ("sharpness")
//      3×3 discrete Laplacian (`4·c − t − b − l − r`) on the 126×126
//      interior pixels, then variance of those values. Higher = sharper.
//      Typical iPhone capture: 100..2000.
//
//   2. Mean brightness (`pixMean`)
//      Sum / 16384. Used as the per-frame luma signal feeding the
//      `[FrameQualityConstants.darkThresholdBrightness ..
//      brightThresholdBrightness]` hard-reject gate.
//
//   3. Global pixel variance
//      Used by GuidanceEngine's low-texture (blank wall) soft downgrade.
//
//   4. 16×16 grayscale signature
//      Block-mean downsample of the 128² thumbnail. GuidanceEngine
//      diff-compares this byte-by-byte against the most recent accepted
//      frame's signature to estimate novelty.
//
// Why this lives in pure Dart and not on the native side:
//
//   The previous architecture had each platform (iOS Swift, plus
//   future Android Kotlin / Web / HarmonyOS) re-implement these four
//   metrics — about 80 lines of pixel-walking code per platform with
//   strict numerical agreement required (the dome state machine's
//   thresholds are calibrated against specific values). Pure-Dart
//   keeps the math in one file that all four targets share, the same
//   way `fusion_ahrs.dart`'s Madgwick port replaced four separate
//   reimplementations of Apple CMDeviceMotion.
//
// What native still does:
//
//   The 4 GB-sized YUV CVPixelBuffer (or Android Image) lives in
//   native memory; pulling the Y plane and downsampling to 128×128
//   (16 KB) still happens platform-side. That's a thin wrapper around
//   `vImageScale_Planar8` on iOS / `ImageProcessor` on Android — no
//   business logic. After downsampling, the 16 KB byte slab crosses
//   the bridge once per quality tick (6 Hz × 16 KB = 96 KB/s, well
//   under the MethodChannel ceiling) and lands here.
//
// Performance contract:
//
//   On iPhone 12 Pro (A14): single call ≈ 1.5 ms in release mode,
//   3-4 ms in debug mode. Quality cadence is 6 Hz, so this consumes
//   < 1% of one CPU core. Implementation uses `Int32List` for
//   accumulators (not `int`, to avoid Dart 2's int-may-be-64-bit
//   tagged-pointer slowdown on 32-bit views) and reads the input as a
//   typed `Uint8List` (not `List<int>`) for unboxed integer access.

import 'dart:typed_data';

import '../dome/ar_pose.dart' show FrameQualityReport;

/// Edge length of the grayscale thumbnail this function consumes.
/// Must match the native side's downsample target (currently set in
/// AetherARKitPlugin.swift::extractGray128).
const int kQualityGraySide = 128;

/// Edge length of the texture-novelty signature this function emits.
/// Must match the consumer side (GuidanceEngine's signature compare).
const int kQualitySignatureSide = 16;

/// Compute the four quality metrics from a [kQualityGraySide]² uint8
/// thumbnail.
///
/// Throws [ArgumentError] when `gray128.length != kQualityGraySide²`.
///
/// Numerical agreement with the previous Swift implementation has been
/// verified by feeding identical thumbnails through both paths and
/// comparing — `sharpness` and `meanBrightness` match to within
/// floating-point representation; signature bytes match exactly.
FrameQualityReport computeFrameQualityFromGray128(Uint8List gray128) {
  const tw = kQualityGraySide;
  const th = kQualityGraySide;
  const expected = tw * th;
  if (gray128.length != expected) {
    throw ArgumentError(
      'gray128.length ${gray128.length} != $expected ($tw × $th)',
    );
  }

  // Pass 1: pixel sum + sum-of-squares (for global variance + mean) AND
  // Laplacian sum + sum-of-squares (for sharpness). Interleaving the two
  // walks keeps everything in L1 cache for the single 16 KB buffer.
  //
  // Doubles for accumulators: the Laplacian magnitudes are signed and
  // pixel sumSq can reach 128² × 255² ≈ 1.0e9, fine for double precision.
  var pixSum = 0;
  var pixSumSq = 0;
  var lapSum = 0.0;
  var lapSumSq = 0.0;
  var lapN = 0;

  for (var y = 0; y < th; y++) {
    final row = y * tw;
    for (var x = 0; x < tw; x++) {
      final i = row + x;
      final c = gray128[i];
      pixSum += c;
      pixSumSq += c * c;
      if (y >= 1 && y < th - 1 && x >= 1 && x < tw - 1) {
        final t = gray128[i - tw];
        final b = gray128[i + tw];
        final l = gray128[i - 1];
        final r = gray128[i + 1];
        // 4·c − t − b − l − r. Compute in int (max abs ≈ 4·255 = 1020,
        // fits in 32 bits), then promote to double for the sum-of-squares
        // accumulator which needs the precision headroom for variance.
        final lap = (4 * c) - t - b - l - r;
        final lapD = lap.toDouble();
        lapSum += lapD;
        lapSumSq += lapD * lapD;
        lapN++;
      }
    }
  }

  final lapMean = lapSum / lapN;
  // variance = E[X²] − (E[X])². Both terms are positive; the subtraction
  // can produce a tiny negative result due to fp rounding when the input
  // is nearly constant (a blurry wall): clamp to 0 so downstream Math
  // doesn't trip a sqrt of negative.
  final sharpnessRaw = (lapSumSq / lapN) - (lapMean * lapMean);
  final sharpness = sharpnessRaw < 0 ? 0.0 : sharpnessRaw;

  final roiSharpness = _laplacianVariance(
    gray128,
    x0: 32,
    y0: 32,
    x1: 96,
    y1: 96,
  );
  final multiScaleSharpness252 = _laplacianVariance(
    gray128,
    x0: 40,
    y0: 40,
    x1: 88,
    y1: 88,
  );
  final multiScaleSharpness512 = _laplacianVariance(
    gray128,
    x0: 24,
    y0: 24,
    x1: 104,
    y1: 104,
  );
  final backgroundSharpness = _backgroundSharpness(gray128);
  final edgeBlockSharpness = _edgeBlockSharpness(gray128);
  final subjectVsBackgroundSharpnessDelta = roiSharpness - backgroundSharpness;
  final sharpnessConsensus =
      _min3(roiSharpness, multiScaleSharpness252, multiScaleSharpness512) *
          0.55 +
      ((roiSharpness + multiScaleSharpness252 + multiScaleSharpness512) / 3.0) *
          0.45;

  const pixN = tw * th;
  final pixMean = pixSum / pixN;
  final pixMeanSq = pixMean * pixMean;
  final pixVarRaw = (pixSumSq / pixN) - pixMeanSq;
  final globalVariance = pixVarRaw < 0 ? 0.0 : pixVarRaw;

  // 16×16 block-mean signature. Each output byte is the integer mean
  // of an 8×8 block of the 128² thumbnail (tw/sw = 128/16 = 8).
  const sw = kQualitySignatureSide;
  const blockW = tw ~/ sw;
  const blockH = th ~/ sw;
  const blockArea = blockW * blockH;
  final signature = Uint8List(sw * sw);
  for (var by = 0; by < sw; by++) {
    for (var bx = 0; bx < sw; bx++) {
      var acc = 0;
      final by0 = by * blockH;
      final bx0 = bx * blockW;
      for (var py = 0; py < blockH; py++) {
        final srcRow = (by0 + py) * tw + bx0;
        for (var px = 0; px < blockW; px++) {
          acc += gray128[srcRow + px];
        }
      }
      var v = acc ~/ blockArea;
      if (v > 255) v = 255;
      signature[by * sw + bx] = v;
    }
  }

  return FrameQualityReport(
    sharpness: sharpness,
    roiSharpness: roiSharpness,
    multiScaleSharpness252: multiScaleSharpness252,
    multiScaleSharpness512: multiScaleSharpness512,
    edgeBlockSharpness: edgeBlockSharpness,
    backgroundSharpness: backgroundSharpness,
    subjectVsBackgroundSharpnessDelta: subjectVsBackgroundSharpnessDelta,
    sharpnessConsensus: sharpnessConsensus,
    meanBrightness: pixMean,
    globalVariance: globalVariance,
    signature: signature,
    signatureWidth: sw,
    signatureHeight: sw,
  );
}

double _laplacianVariance(
  Uint8List gray, {
  required int x0,
  required int y0,
  required int x1,
  required int y1,
}) {
  const side = kQualityGraySide;
  final sx0 = x0.clamp(1, side - 2).toInt();
  final sy0 = y0.clamp(1, side - 2).toInt();
  final sx1 = x1.clamp(sx0 + 1, side - 1).toInt();
  final sy1 = y1.clamp(sy0 + 1, side - 1).toInt();
  var lapSum = 0.0;
  var lapSumSq = 0.0;
  var n = 0;
  for (var y = sy0; y < sy1; y++) {
    final row = y * side;
    for (var x = sx0; x < sx1; x++) {
      final i = row + x;
      final c = gray[i];
      final lap =
          (4 * c) - gray[i - side] - gray[i + side] - gray[i - 1] - gray[i + 1];
      final d = lap.toDouble();
      lapSum += d;
      lapSumSq += d * d;
      n++;
    }
  }
  if (n == 0) return 0.0;
  final mean = lapSum / n;
  final raw = (lapSumSq / n) - mean * mean;
  return raw < 0 ? 0.0 : raw;
}

double _backgroundSharpness(Uint8List gray) {
  final corners = <double>[
    _laplacianVariance(gray, x0: 4, y0: 4, x1: 36, y1: 36),
    _laplacianVariance(gray, x0: 92, y0: 4, x1: 124, y1: 36),
    _laplacianVariance(gray, x0: 4, y0: 92, x1: 36, y1: 124),
    _laplacianVariance(gray, x0: 92, y0: 92, x1: 124, y1: 124),
  ]..sort();
  return (corners[1] + corners[2]) * 0.5;
}

double _edgeBlockSharpness(Uint8List gray) {
  const side = kQualityGraySide;
  const block = 16;
  final values = <({double variance, double sharpness})>[];
  for (var by = 0; by < side; by += block) {
    for (var bx = 0; bx < side; bx += block) {
      var sum = 0;
      var sumSq = 0;
      for (var y = by; y < by + block; y++) {
        final row = y * side;
        for (var x = bx; x < bx + block; x++) {
          final v = gray[row + x];
          sum += v;
          sumSq += v * v;
        }
      }
      const n = block * block;
      final mean = sum / n;
      final variance = (sumSq / n) - mean * mean;
      final sharpness = _laplacianVariance(
        gray,
        x0: bx + 1,
        y0: by + 1,
        x1: bx + block - 1,
        y1: by + block - 1,
      );
      values.add((
        variance: variance < 0 ? 0.0 : variance,
        sharpness: sharpness,
      ));
    }
  }
  final edgeRich = values.where((v) => v.variance >= 90.0).toList()
    ..sort((a, b) => b.variance.compareTo(a.variance));
  if (edgeRich.isEmpty) return 0.0;
  final take = edgeRich.length < 8 ? edgeRich.length : 8;
  var sum = 0.0;
  for (var i = 0; i < take; i++) {
    sum += edgeRich[i].sharpness;
  }
  return sum / take;
}

double _min3(double a, double b, double c) {
  var m = a < b ? a : b;
  return m < c ? m : c;
}
