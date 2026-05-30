import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:pocketworld_flutter/capture/depth_alignment_ffi.dart';

void _expectClose(String name, double got, double expected, double eps) {
  if ((got - expected).abs() > eps) {
    throw StateError('$name got=$got expected=$expected eps=$eps');
  }
}

void main() {
  final align = DepthAlignmentFfi.scaleAlignAdaptive(
    zAi: const [0.5, 0.9, 1.2, 1.7, 2.1, 2.6],
    zMetric: const [1.1, 1.9, 2.5, 3.5, 4.3, 5.3],
    options: const ScaleAlignOptions(
      minAnchors: 2,
      goodAnchors: 6,
      minDepthSpanM: 0.02,
      goodDepthSpanM: 2.5,
      translationFitGain: 1.0,
    ),
  );
  if (!align.raw.ok || align.reliability < 0.50) {
    throw StateError(
      'adaptive align failed ok=${align.raw.ok} r=${align.reliability}',
    );
  }
  _expectClose('scale', align.scale, 2.0, 0.05);
  _expectClose('translation', align.translation, 0.1, 0.05);

  const w = 5;
  const h = 4;
  final rel = Float32List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      rel[y * w + x] = 0.8 + 0.05 * x + 0.03 * y;
    }
  }
  final out = DepthAlignmentFfi.refineSparsePrior(
    relativeDepth: rel,
    conf: Float32List(w * h)..fillRange(0, w * h, 2.0),
    width: w,
    height: h,
    sparseU: const [0, 4, 0, 4],
    sparseV: const [0, 0, 3, 3],
    sparseMetricDepth: [
      2.0 * rel[0],
      2.0 * rel[4],
      2.0 * rel[3 * w],
      2.0 * rel[3 * w + 4],
    ],
    options: const SparseDepthPriorOptions(
      align: ScaleAlignOptions(
        minAnchors: 2,
        goodAnchors: 4,
        minDepthSpanM: 0.01,
        goodDepthSpanM: 0.5,
        translationFitGain: 1.0,
      ),
      residualGain: 0.0,
    ),
  );
  if (!out.result.ok) {
    throw StateError('sparse prior failed');
  }
  final center = 2 * rel[2 * w + 2];
  if ((out.metricDepth[2 * w + 2] - center).abs() > 0.04 ||
      out.metricDepth.any((v) => !v.isFinite || v <= 0.0)) {
    throw StateError('metric depth output invalid');
  }

  stdout.writeln(
    'depth_alignment_ffi_smoke ok '
    'scale=${align.scale.toStringAsFixed(4)} '
    'translation=${align.translation.toStringAsFixed(4)} '
    'r=${align.reliability.toStringAsFixed(4)} '
    'meanResidual=${out.result.meanAbsResidualM.toStringAsFixed(4)} '
    'center=${out.metricDepth[math.min(2 * w + 2, out.metricDepth.length - 1)].toStringAsFixed(4)}',
  );
}
