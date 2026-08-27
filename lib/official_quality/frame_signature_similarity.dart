import 'dart:typed_data';

/// Exact byte-signature comparison used by Aether3D's guidance engine.
///
/// Returns null when the two 16×16 signatures cannot be compared. Otherwise
/// similarity is `1 - mean(abs(current[i] - previous[i]) / 255)`.
double? aetherFrameSignatureSimilarity({
  required Uint8List current,
  required Uint8List previous,
}) {
  if (current.isEmpty ||
      previous.isEmpty ||
      current.length != previous.length) {
    return null;
  }
  var difference = 0.0;
  for (var i = 0; i < current.length; i++) {
    difference += (current[i] - previous[i]).abs() / 255.0;
  }
  return 1.0 - difference / current.length;
}
