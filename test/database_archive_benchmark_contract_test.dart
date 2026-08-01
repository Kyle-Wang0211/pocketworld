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

    expect(runner, contains('com.kyle.PocketWorld.ArchiveBench'));
    expect(runner, isNot(contains('device uninstall app')));
    expect(runner, contains('PRODUCT_BUNDLE_IDENTIFIER='));
    expect(runner, contains('lib/database_archive_benchmark_main.dart'));
    expect(runner, contains('--no-pub'));
    expect(entrypoint, contains('benchmark_input.db'));
    expect(entrypoint, contains('DatabaseArchiveTransaction'));
    expect(entrypoint, contains('DatabaseArchiveResolver'));
    expect(entrypoint, contains('TrackDeltaFfiDatabaseArchivePreprocessor'));
    expect(entrypoint, contains('ZpaqFfiDatabaseArchiveCodec'));
    expect(entrypoint, contains('integrityCheck'));
    expect(entrypoint, contains('database_archive_benchmark_result.json'));
    expect(entrypoint, contains('repeatCount = 3'));
  });
}
