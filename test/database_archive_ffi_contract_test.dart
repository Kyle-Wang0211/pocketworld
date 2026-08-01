import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_ffi_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_ffi_preprocessor.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';

void main() {
  test('desktop process fails closed instead of loading iOS symbols', () {
    if (!Platform.isIOS) {
      expect(ZpaqFfiDatabaseArchiveCodec().isSupported, isFalse);
      expect(TrackDeltaFfiDatabaseArchivePreprocessor().isSupported, isFalse);
    }
  });

  test('track preprocessor uses the cancellable native ABI in an isolate', () {
    final header = File(
      'ios/Runner/pw_sqlite_descriptor_transform.h',
    ).readAsStringSync();
    final bridge = File(
      'ios/Runner/pw_sqlite_descriptor_transform.cpp',
    ).readAsStringSync();
    final dart = File(
      'lib/official_capture/database_archive_ffi_preprocessor.dart',
    ).readAsStringSync();

    expect(dart, contains('Isolate.run'));
    for (final symbol in const <String>[
      'pw_sqlite_descriptor_transform_file_cancellable',
      'pw_sqlite_descriptor_transform_cancellation_generation',
      'pw_sqlite_descriptor_transform_request_cancel',
    ]) {
      expect(header, contains(symbol));
      expect(bridge, contains(symbol));
      expect(dart, contains(symbol));
    }
  });

  test(
    'native bridge pins exact ZPAQ identity method and cancellation ABI',
    () {
      final header = File('ios/Runner/pw_zpaq_bridge.h').readAsStringSync();
      final bridge = File('ios/Runner/pw_zpaq_bridge.cpp').readAsStringSync();
      final dart = File(
        'lib/official_capture/database_archive_ffi_codec.dart',
      ).readAsStringSync();

      expect(bridge, contains(DatabaseArchivePolicy.pinnedRevision));
      expect(bridge, contains('libzpaq::compress'));
      expect(bridge, contains('"5"'));
      expect(bridge, contains('libzpaq::decompress'));
      expect(bridge, contains('std::atomic<uint64_t>'));
      expect(dart, contains('Isolate.run'));
      for (final symbol in const <String>[
        'pw_zpaq_version',
        'pw_zpaq_revision',
        'pw_zpaq_error_message',
        'pw_zpaq_last_error',
        'pw_zpaq_compress_file',
        'pw_zpaq_decompress_file',
        'pw_zpaq_cancellation_generation',
        'pw_zpaq_request_cancel',
      ]) {
        expect(header, contains(symbol));
        expect(bridge, contains(symbol));
        expect(dart, contains(symbol));
      }
    },
  );

  test('vendored official source matches the accepted benchmark hashes', () {
    const expected = <String, String>{
      'ios/Vendor/Zpaq/include/libzpaq.h':
          '08bd9ce17ce018468e35721e2c6a8bd13c0c5e397ce4e9c90c52aec389662f79',
      'ios/Vendor/Zpaq/src/libzpaq.cpp':
          '151eb6bd83cb6c6f5261d64b1db49358710f844ee1a2aa4b9cb63e17319df122',
      'ios/Vendor/Zpaq/Zpaq-LICENSE.txt':
          '927b5feda84f7a7f2063998b124829182967f54b954db2c3569e8bd07958bf07',
    };
    for (final entry in expected.entries) {
      final file = File(entry.key);
      expect(file.existsSync(), isTrue, reason: entry.key);
      expect(
        sha256.convert(file.readAsBytesSync()).toString(),
        entry.value,
        reason: entry.key,
      );
    }
    final revision = File('ios/Vendor/Zpaq/REVISION').readAsStringSync();
    expect(revision, contains('official-zpaq-7.15.zip'));
    expect(revision, contains(DatabaseArchivePolicy.pinnedRevision));
  });

  test('Runner compiles and retains portable ZPAQ sources and native test', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    for (final evidence in const <String>[
      'pw_zpaq_bridge.cpp in Sources',
      'libzpaq.cpp in Sources',
      'PWZpaqBridgeTests.mm in Sources',
      r'$(PROJECT_DIR)/Vendor/Zpaq/include',
      '-DNOJIT -Dunix',
      '-Wl,-u,_pw_zpaq_version',
      '-Wl,-u,_pw_zpaq_revision',
      '-Wl,-u,_pw_zpaq_error_message',
      '-Wl,-u,_pw_zpaq_last_error',
      '-Wl,-u,_pw_zpaq_compress_file',
      '-Wl,-u,_pw_zpaq_decompress_file',
      '-Wl,-u,_pw_zpaq_cancellation_generation',
      '-Wl,-u,_pw_zpaq_request_cancel',
      'Zpaq-LICENSE.txt in Resources',
    ]) {
      expect(project, contains(evidence), reason: evidence);
    }
    final nativeTest = File(
      'ios/RunnerTests/PWZpaqBridgeTests.mm',
    ).readAsStringSync();
    final hostSmoke = File(
      'ios/RunnerTests/PWZpaqBridgeSmoke.cpp',
    ).readAsStringSync();
    expect(nativeTest, contains('testMethod5RoundTripRestoresExactBytes'));
    expect(nativeTest, contains('pw_zpaq_compress_file'));
    expect(nativeTest, contains('pw_zpaq_decompress_file'));
    expect(nativeTest, contains('XCTAssertEqualObjects(restored, source)'));
    expect(hostSmoke, contains('PW_ZPAQ_SMOKE_OK'));
    expect(hostSmoke, contains('PW_ZPAQ_CANCELLED'));
    expect(hostSmoke, contains('restored != source'));
  });

  test('license notice asset and explicit production marker are shipped', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final notices = File('THIRD_PARTY_NOTICES').readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(pubspec, contains('ios/Vendor/Zpaq/Zpaq-LICENSE.txt'));
    expect(notices, contains('ZPAQ 7.15 database archive stack'));
    expect(notices, contains(DatabaseArchivePolicy.pinnedRevision));
    expect(notices, contains('Unlicense'));
    expect(notices, contains('MIT'));
    expect(infoPlist, contains('future-official-zpaq-db-archive-v1'));
    expect(infoPlist, contains('sqlite-dual-candidate-archive-v2'));
  });
}
