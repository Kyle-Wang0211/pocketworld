import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/lepton_jxl_benchmark_gate.dart';

void main() {
  test('Lepton/JXL benchmark is official, exact, and container-isolated', () {
    final runner = File(
      'tool/run_lepton_jxl_iphone_bench.sh',
    ).readAsStringSync();
    final builder = File('tool/build_lepton_ios.sh').readAsStringSync();
    final entrypoint = File(
      'lib/lepton_jxl_benchmark_main.dart',
    ).readAsStringSync();
    final dartFfi = File(
      'lib/official_capture/lepton_photo_archive_ffi_codec.dart',
    ).readAsStringSync();
    final gate = File(
      'lib/official_capture/lepton_jxl_benchmark_gate.dart',
    ).readAsStringSync();
    final native = File('native/lepton_jpeg_ffi/src/lib.rs').readAsStringSync();
    final cargo = File('native/lepton_jpeg_ffi/Cargo.toml').readAsStringSync();

    expect(runner, contains('bundle_id=com.kyle.PocketWorld.LeptonBench'));
    expect(runner, isNot(contains('device uninstall app')));
    expect(runner, contains(r'--domain-identifier "$bundle_id"'));
    expect(runner, contains(r'PRODUCT_BUNDLE_IDENTIFIER="$bundle_id"'));
    expect(runner, contains('--no-pub'));
    expect(runner, contains('CODE_SIGNING_ALLOWED=NO'));
    expect(runner, contains(r'BUILD_DIR="$build_dir"'));
    expect(runner, contains('benchmark_input.jpg'));
    expect(runner, contains('lepton_jxl_benchmark_result.json'));
    expect(runner, contains('lepton_archive_bytes < jxl_archive_bytes'));
    expect(runner, contains('IPHONE_LEPTON_JXL_AB_OK'));

    expect(builder, contains('aarch64-apple-ios'));
    expect(builder, contains('cargo build --release --locked'));
    expect(builder, contains('libpw_lepton_jpeg_ffi.a'));

    expect(cargo, contains('lepton_jpeg = "=0.5.8"'));
    expect(cargo, contains('crate-type = ["staticlib"]'));
    expect(native, contains('EnabledFeatures::compat_lepton_vector_write()'));
    expect(native, contains('EnabledFeatures::compat_lepton_vector_read()'));
    expect(native, contains('DEFAULT_THREAD_POOL'));
    expect(native, contains('pw_lepton_encode_jpeg_file'));
    expect(native, contains('pw_lepton_reconstruct_jpeg_file'));

    expect(gate, contains('2725495'));
    expect(
      gate,
      contains(
        'a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138',
      ),
    );
    for (final field in const <String>[
      'source_bytes',
      'source_sha256',
      'jxl',
      'lepton',
      'archive_bytes',
      'archive_sha256',
      'restored_sha256',
      'byte_equal',
      'encode_elapsed_us',
      'decode_elapsed_us',
      'winner',
      'production_eligible',
    ]) {
      expect(entrypoint, contains(field));
    }
    expect(entrypoint, contains('lepton.archiveBytes < jxl.archiveBytes'));
    expect(entrypoint, contains('JxlFfiPhotoArchiveCodec(effort: 10)'));
    expect(dartFfi, contains("DynamicLibrary.process()"));
    expect(dartFfi, contains("version != '0.5.8'"));
    expect(dartFfi, contains('90fdc27828676892fbb41777cfcc6bad1e470516'));
  });

  test('immutable input gate requires both exact length and SHA-256', () {
    expect(
      isExpectedLeptonJxlBenchmarkInput(
        bytes: expectedLeptonJxlSourceBytes,
        sha256Hex: expectedLeptonJxlSourceSha256,
      ),
      isTrue,
    );
    expect(
      isExpectedLeptonJxlBenchmarkInput(
        bytes: expectedLeptonJxlSourceBytes - 1,
        sha256Hex: expectedLeptonJxlSourceSha256,
      ),
      isFalse,
    );
    expect(
      isExpectedLeptonJxlBenchmarkInput(
        bytes: expectedLeptonJxlSourceBytes,
        sha256Hex: '0' * 64,
      ),
      isFalse,
    );
  });

  test('production gate requires both exact arms and a strict Lepton win', () {
    expect(
      isLeptonProductionEligible(
        jxlExact: true,
        leptonExact: true,
        jxlArchiveBytes: 100,
        leptonArchiveBytes: 99,
      ),
      isTrue,
    );
    expect(
      isLeptonProductionEligible(
        jxlExact: true,
        leptonExact: true,
        jxlArchiveBytes: 100,
        leptonArchiveBytes: 100,
      ),
      isFalse,
    );
    expect(
      isLeptonProductionEligible(
        jxlExact: true,
        leptonExact: false,
        jxlArchiveBytes: 100,
        leptonArchiveBytes: 90,
      ),
      isFalse,
    );
    expect(
      isLeptonProductionEligible(
        jxlExact: false,
        leptonExact: true,
        jxlArchiveBytes: 100,
        leptonArchiveBytes: 90,
      ),
      isFalse,
    );
  });
}
