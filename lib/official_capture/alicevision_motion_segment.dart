import 'continuous_feature_tracks.dart';

/// AliceVision keyframeSelection's official smart-selection default: split a
/// sequence whenever accumulated optical-flow motion reaches 10% of the
/// image's shorter edge. This causal accumulator preserves that spatial rule
/// for a live camera without inventing a wall-clock interval.
const double kAliceVisionMotionStepPercent = 10.0;

class AliceVisionMotionSegment {
  AliceVisionMotionSegment({required this.width, required this.height})
    : assert(width > 0),
      assert(height > 0);

  final int width;
  final int height;
  double _accumulatedPixelMotion = 0;

  double get accumulatedPixelMotion => _accumulatedPixelMotion;
  double get thresholdPixelMotion =>
      kAliceVisionMotionStepPercent * (width < height ? width : height) / 100.0;
  bool get ready => _accumulatedPixelMotion >= thresholdPixelMotion;

  bool add(FrameTrackEvidence evidence) {
    final step = evidence.medianStepPixelDisplacement;
    if (!evidence.comparable || !step.isFinite || step < 0) return ready;
    _accumulatedPixelMotion += step;
    return ready;
  }

  void reset() => _accumulatedPixelMotion = 0;
}
