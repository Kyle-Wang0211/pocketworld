/// Cross-platform pixel-reduction contract selected by Dart.
///
/// Native platform glue executes this exact formula beside the source pixel
/// buffer to avoid transporting a full-resolution luma plane through Flutter.
/// The formula ID and this reference implementation are the portable source of
/// truth; native code may not substitute a default kernel or rounding rule.
const String kVioShadowDownsampleFormulaBoxNxnHalfUpV1 = 'box-nxn-half-up-v1';

/// Pure-Dart reference for one output pixel of `box-nxn-half-up-v1`.
int vioShadowDownsampleBoxNxnHalfUp(
  List<int> sourceBlock, {
  required int factor,
}) {
  if (factor <= 0 || sourceBlock.length != factor * factor) {
    throw ArgumentError('sourceBlock must contain exactly factor² samples');
  }
  var sum = 0;
  for (final int sample in sourceBlock) {
    if (sample < 0 || sample > 255) {
      throw ArgumentError.value(sample, 'sourceBlock', 'must be uint8');
    }
    sum += sample;
  }
  final int area = factor * factor;
  return (sum + area ~/ 2) ~/ area;
}
