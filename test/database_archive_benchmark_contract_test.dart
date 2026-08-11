import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('independent iPhone benchmark cannot target production bundle', () {
    final entrypoint = File(
      'lib/database_archive_benchmark_main.dart',
    ).readAsStringSync();
    final runner = File(
      'tool/run_sqlite_dual_candidate_iphone_bench.sh',
    ).readAsStringSync();
    final hostRunner = File(
      'tool/run_sqlite_track_delta_complete_archive_bench.sh',
    ).readAsStringSync();
    final hostHarness = File(
      'tool/sqlite_track_delta_complete_archive_bench.cpp',
    ).readAsStringSync();
    final nativeBridge = File(
      'ios/Runner/pw_sqlite_descriptor_transform.cpp',
    ).readAsStringSync();
    final xcodeProject = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(runner, contains('com.kyle.PocketWorld.ArchiveBench'));
    expect(runner, isNot(contains('device uninstall app')));
    expect(runner, contains('PRODUCT_BUNDLE_IDENTIFIER='));
    expect(runner, contains('lib/database_archive_benchmark_main.dart'));
    expect(runner, contains('--no-pub'));
    expect(runner, contains('CODE_SIGNING_ALLOWED=NO'));
    expect(runner, contains(r'BUILD_DIR="$build_dir"'));
    expect(runner, isNot(contains('CONFIGURATION_BUILD_DIR=')));
    expect(runner, contains('embedded.mobileprovision'));
    expect(runner, contains('ArchiveBench.entitlements'));
    expect(runner, contains(r'$team_id.$bundle_id'));
    expect(entrypoint, contains('benchmark_input.db'));
    expect(entrypoint, contains('DatabaseArchiveTransaction'));
    expect(entrypoint, contains('DatabaseArchiveResolver'));
    expect(entrypoint, contains('TrackDeltaFfiDatabaseArchivePreprocessor'));
    expect(entrypoint, contains('ExactTransformV2FfiBenchmarkPreprocessor'));
    expect(entrypoint, contains('exact_transform_v2'));
    expect(entrypoint, contains('ZpaqFfiDatabaseArchiveCodec'));
    expect(entrypoint, contains('integrityCheck'));
    expect(entrypoint, contains('database_archive_benchmark_result.json'));
    expect(entrypoint, contains('repeatCount = 1'));
    expect(runner, contains('repeat_count=1'));
    expect(runner, contains('124401918'));
    expect(runner, contains('exact_v2_archive_bytes'));
    expect(hostRunner, contains('exact_transform_v2'));
    expect(hostHarness, contains('exact_transform_v2'));
    expect(hostHarness, contains('PW_SQLITE_EXACT_TRANSFORM_V2'));
    expect(hostRunner, contains('-DPW_SQLITE_EXACT_TRANSFORM_V2_BENCH=1'));
    expect(runner, contains('-DPW_SQLITE_EXACT_TRANSFORM_V2_BENCH=1'));
    expect(
      nativeBridge,
      contains('#if defined(PW_SQLITE_EXACT_TRANSFORM_V2_BENCH)'),
    );
    expect(xcodeProject, isNot(contains('PW_SQLITE_EXACT_TRANSFORM_V2_BENCH')));
  });
}
