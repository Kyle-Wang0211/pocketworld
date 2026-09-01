import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pocketworld_flutter/community/report_evidence_processor.dart';
import 'package:pocketworld_flutter/community/social_profile_models.dart';

void main() {
  const processor = ReportEvidenceProcessor();

  test('re-encodes JPEG, removes EXIF marker, and bounds dimensions', () {
    final source = img.Image(width: 3000, height: 1200)
      ..clear(img.ColorRgb8(50, 100, 150));
    final jpeg = img.encodeJpg(source, quality: 92);
    final withExif = Uint8List.fromList([
      0xff,
      0xd8,
      0xff,
      0xe1,
      0x00,
      0x10,
      ...'Exif\u0000\u0000GPSDATA'.codeUnits,
      ...jpeg.skip(2),
    ]);

    final result = processor.process(withExif);
    final decoded = img.decodeImage(result.bytes)!;

    expect(result.contentType, 'image/jpeg');
    expect(result.extension, 'jpg');
    expect(decoded.width, 2048);
    expect(decoded.height, lessThanOrEqualTo(2048));
    expect(String.fromCharCodes(result.bytes).contains('Exif'), isFalse);
    expect(
      result.bytes.lengthInBytes,
      lessThanOrEqualTo(ReportEvidenceUpload.maxBytes),
    );
  });

  test('accepts PNG but returns a sanitized supported bitmap', () {
    final source = img.Image(width: 32, height: 24)
      ..clear(img.ColorRgb8(200, 30, 40));
    final result = processor.process(img.encodePng(source));
    expect(result.contentType, anyOf('image/jpeg', 'image/png'));
    expect(img.decodeImage(result.bytes), isNotNull);
  });

  test('rejects invalid and unsupported input fail closed', () {
    expect(
      () => processor.process(Uint8List.fromList([1, 2, 3, 4])),
      throwsFormatException,
    );
  });
}
