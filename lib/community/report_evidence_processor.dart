import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'social_profile_models.dart';

class ReportEvidenceProcessor {
  static const int maxDimension = 2048;
  static const int maxInputBytes = 20 * 1024 * 1024;
  static const int maxDecodedPixels = 40 * 1000 * 1000;

  const ReportEvidenceProcessor();

  ReportEvidenceUpload process(Uint8List input) {
    if (input.isEmpty || input.lengthInBytes > maxInputBytes) {
      throw const FormatException('Unsupported evidence image size.');
    }
    if (!_isJpeg(input) && !_isPng(input)) {
      throw const FormatException('Only JPEG and PNG evidence is supported.');
    }

    final decoder = _isJpeg(input) ? img.JpegDecoder() : img.PngDecoder();
    final info = decoder.startDecode(input);
    if (info == null || info.width <= 0 || info.height <= 0) {
      throw const FormatException('Evidence image could not be decoded.');
    }
    if (info.width * info.height > maxDecodedPixels) {
      throw const FormatException('Evidence image dimensions are too large.');
    }

    final decoded = decoder.decodeFrame(0);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      throw const FormatException('Evidence image could not be decoded.');
    }
    if (decoded.width * decoded.height > maxDecodedPixels) {
      throw const FormatException('Evidence image dimensions are too large.');
    }

    var bitmap = img.bakeOrientation(decoded);
    final longest = bitmap.width > bitmap.height ? bitmap.width : bitmap.height;
    if (longest > maxDimension) {
      final scale = maxDimension / longest;
      bitmap = img.copyResize(
        bitmap,
        width: (bitmap.width * scale).round(),
        height: (bitmap.height * scale).round(),
        interpolation: img.Interpolation.average,
      );
    }

    // Always encode a fresh JPEG. This discards EXIF/GPS, embedded thumbnails,
    // file names, PNG text chunks, and any bytes after the decoded bitmap.
    for (final quality in const [90, 82, 74, 66, 58, 50]) {
      final output = img.encodeJpg(bitmap, quality: quality);
      if (output.lengthInBytes <= ReportEvidenceUpload.maxBytes) {
        return ReportEvidenceUpload(
          bytes: output,
          contentType: 'image/jpeg',
          extension: 'jpg',
        );
      }
    }
    throw const FormatException('Sanitized evidence exceeds five MiB.');
  }

  bool _isJpeg(Uint8List bytes) =>
      bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff;

  bool _isPng(Uint8List bytes) =>
      bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a;
}
