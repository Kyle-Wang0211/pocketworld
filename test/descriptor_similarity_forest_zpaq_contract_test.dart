import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('similarity forest benchmark is exact, isolated, and single-run', () {
    final runner = File(
      'tool/run_sqlite_descriptor_similarity_forest_zpaq_bench.sh',
    ).readAsStringSync();
    final benchmark = File(
      'tool/sqlite_descriptor_similarity_forest_zpaq_bench.cpp',
    ).readAsStringSync();
    final contract = File(
      'experiments/descriptor_similarity_forest_zpaq/experiment-contract.yaml',
    ).readAsStringSync();

    expect(runner, contains('OMP_NUM_THREADS=8'));
    expect(runner, contains('cbd11b958ff233d4cc1dc0fe010890b4'));
    expect(runner, isNot(contains('flutter build')));
    expect(runner, isNot(contains('devicectl')));
    expect(benchmark, contains('PW_SQLITE_DESCRIPTOR_TRACK_DELTA'));
    expect(benchmark, contains('similarity_forest_v1'));
    expect(benchmark, contains('sidecar_equal'));
    expect(benchmark, contains('FilesEqual(source, restored)'));
    expect(benchmark, contains('IntegrityOk(restored)'));
    expect(benchmark, contains('b_strictly_smaller'));
    expect(contract, contains('complete_repeats_per_arm: 1'));
    expect(contract, contains('automatic_extra_repeats: 0'));
    expect(
      contract,
      contains('production_promotion_requires_physical_iphone: true'),
    );
  });
}
