import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_ffi_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';

void main() {
  test('production JPEG XL archive uses the verified effort 10', () {
    expect(JxlFfiPhotoArchiveCodec().effort, 10);
  });

  test('desktop test process fails closed instead of loading iOS symbols', () {
    if (!Platform.isIOS) {
      expect(JxlFfiPhotoArchiveCodec().isSupported, isFalse);
    }
  });

  test('native bridge pins exact libjxl revision and file-oriented ABI', () {
    final header = File('ios/Runner/pw_jxl_bridge.h').readAsStringSync();
    final implementation = File(
      'ios/Runner/pw_jxl_bridge.mm',
    ).readAsStringSync();
    final dart = File(
      'lib/official_capture/photo_archive_ffi_codec.dart',
    ).readAsStringSync();

    expect(implementation, contains(PhotoArchivePolicy.pinnedLibjxlRevision));
    for (final symbol in const [
      'pw_jxl_revision',
      'pw_jxl_encode_jpeg_file',
      'pw_jxl_reconstruct_jpeg_file',
    ]) {
      expect(header, contains(symbol));
      expect(implementation, contains(symbol));
      expect(dart, contains(symbol));
    }
    expect(implementation, contains('JxlEncoderUseContainer'));
    expect(implementation, contains('JxlEncoderStoreJPEGMetadata'));
    expect(implementation, contains('JXL_DEC_JPEG_RECONSTRUCTION'));
    expect(implementation, contains('JXL_DEC_FULL_IMAGE'));
  });

  test('Runner retains native entry points and links pinned libraries', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    expect(project, contains('pw_jxl_bridge.mm in Sources'));
    expect(project, contains(r'$(PROJECT_DIR)/Vendor/JXL/include'));
    for (final linkerFlag in const [
      '-ljxl',
      '-ljxl_threads',
      '-lhwy',
      '-lbrotlienc',
      '-lbrotlidec',
      '-lbrotlicommon',
      '-Wl,-u,_pw_jxl_encode_jpeg_file',
      '-Wl,-u,_pw_jxl_reconstruct_jpeg_file',
    ]) {
      expect(project, contains(linkerFlag));
    }
  });

  test('native dependency licenses and revisions ship with the app', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final notices = File('THIRD_PARTY_NOTICES').readAsStringSync();
    expect(pubspec, contains('ios/Vendor/JXL/licenses/'));
    for (final evidence in const [
      'a7a9c787341cf703dede03c2009fa460cae5e5df',
      '028fb5a23661f123017c060daa546b55cf4bde29',
      '457c891775a7397bdb0376bb1031e6e027af1c48',
      '96d9171c94b937a1b5f0293de7309ac16311b722',
    ]) {
      expect(notices, contains(evidence));
    }
    for (final license in const [
      'libjxl-LICENSE',
      'brotli-LICENSE',
      'highway-LICENSE',
      'highway-LICENSE-BSD3',
      'skcms-LICENSE',
    ]) {
      expect(
        File('ios/Vendor/JXL/licenses/$license').lengthSync(),
        greaterThan(0),
      );
    }
  });
}
