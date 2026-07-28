import 'dart:io';

/// File-oriented JPEG XL primitive.
///
/// Implementations must use JPEG reconstruction mode: reconstructing the
/// archive must yield the original JPEG file bytes, not just identical pixels.
abstract interface class PhotoArchiveCodec {
  bool get isSupported;

  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  });

  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  });
}
