import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PWA2 host benchmark isolates structure and enforces the frozen gate',
    () {
      final runner = File(
        'tool/run_pwa2_structure_zpaq_bench.sh',
      ).readAsStringSync();
      final harness = File(
        'tool/pwa2_structure_zpaq_bench.cpp',
      ).readAsStringSync();

      expect(runner, contains('198983680'));
      expect(
        runner,
        contains(
          '0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0',
        ),
      );
      expect(runner, contains('111961726'));
      expect(runner, contains('124401918'));
      expect(runner, contains('sqlite3'));
      expect(runner, contains('PRAGMA integrity_check'));
      expect(runner, contains('pwa2_sqlite_logical_archive.cpp'));
      expect(runner, contains('pw_zpaq_bridge.cpp'));
      expect(runner, contains('libzpaq.cpp'));
      expect(runner, isNot(contains('OpenZL')));
      expect(runner, isNot(contains('Pcodec')));
      expect(runner, isNot(contains('Blosc2')));
      expect(runner, isNot(contains('device install app')));
      expect(runner, isNot(contains('com.kyle.PocketWorld')));
      expect(harness, contains('pw_zpaq_version'));
      expect(harness, contains('pw_zpaq_revision'));
      expect(harness, contains('pw_zpaq_compress_file'));
      expect(harness, contains('pw_zpaq_decompress_file'));
      expect(harness, contains('PW_PWA2_STRUCTURE_ZPAQ_BENCH_OK'));
      expect(harness, contains('complete_persisted_bytes'));
      expect(harness, contains('logical_sha256_equal'));
      expect(harness, contains('all_cells_equal'));
      expect(harness, contains('all_rows_and_order_equal'));
      expect(harness, contains('random_reads_exact'));
      expect(harness, contains('materialized_sqlite_integrity_ok'));
      expect(harness, contains('source_unchanged'));
      expect(harness, contains('111961726'));
    },
  );
}
