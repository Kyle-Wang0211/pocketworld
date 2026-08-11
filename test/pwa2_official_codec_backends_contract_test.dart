import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('official PWA2 codec benchmark is pinned exact and host-only', () {
    final runner = File(
      'tool/run_pwa2_official_codec_backends_bench.sh',
    ).readAsStringSync();
    final harness = File(
      'tool/pwa2_official_codec_backends_bench.cpp',
    ).readAsStringSync();

    expect(runner, contains('198983680'));
    expect(
      runner,
      contains(
        '0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0',
      ),
    );
    expect(runner, contains('v0.2.0'));
    expect(runner, contains('3dceb64867840201fb8f57a29d179995f700c9b8'));
    expect(runner, contains('v1.0.2'));
    expect(runner, contains('2d8555888b21bbaa19326580b740fa24b7da6bd3'));
    expect(runner, contains('v3.3.0'));
    expect(runner, contains('7265419b23872707b1b52298d5f1469c9ea7b9e7'));
    expect(runner, contains('371ed262b7969ba0a52f009588c0215df0e455c86'));
    expect(runner, contains('c71d239df91726fc519c6eb72d318ec6582062723'));
    expect(runner, contains('22623131a9b9f6a86a4dc6b9bccbb1d2aeb390df'));
    expect(runner, contains('124401918'));
    expect(runner, contains('129567942'));
    expect(runner, contains('111961726'));
    expect(runner, contains('PRAGMA integrity_check'));
    expect(runner, contains('repeat_count=1'));
    expect(runner, isNot(contains('device install app')));
    expect(runner, isNot(contains('com.kyle.PocketWorld')));
    expect(runner, isNot(contains('TRUNC_PREC')));
    expect(runner, isNot(contains('INT_TRUNC')));
    expect(runner, isNot(contains('NDMEAN')));

    expect(harness, contains('complete_persisted_bytes'));
    expect(harness, contains('logical_sha256_equal'));
    expect(harness, contains('all_cells_equal'));
    expect(harness, contains('all_rows_and_order_equal'));
    expect(harness, contains('random_reads_exact'));
    expect(harness, contains('materialized_sqlite_integrity_ok'));
    expect(harness, contains('source_unchanged'));
    expect(harness, contains('selected_codec'));
    expect(harness, contains('PW_PWA2_OFFICIAL_CODECS_BENCH_OK'));
  });

  test('strictly smaller exact hybrid is the scoped PWA2 baseline', () {
    final decision =
        jsonDecode(
              File(
                'experiments/pwa2_official_codec_backends/baseline-decision.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final previous = decision['previous_baseline'] as Map<String, dynamic>;
    final current = decision['new_baseline'] as Map<String, dynamic>;
    final production = decision['production_baseline'] as Map<String, dynamic>;

    expect(decision['scope'], 'pwa2_structure');
    expect(decision['status'], 'accepted');
    expect(previous['bytes'], 129567942);
    expect(current['bytes'], 129201499);
    expect(current['bytes'] as int, lessThan(previous['bytes'] as int));
    expect(decision['comparison_policy'], contains('any_strictly_smaller'));
    expect(production['bytes'], 124401918);
    expect(production['unchanged'], isTrue);
    expect(decision['production_promotion'], isFalse);
  });
}
