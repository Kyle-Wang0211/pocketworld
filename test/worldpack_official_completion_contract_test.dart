import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const experimentRoot = 'experiments/worldpack_official_completion';

  test('official completion contract freezes every missing route', () {
    final contractFile = File('$experimentRoot/experiment-contract.yaml');
    final manifestFile = File('$experimentRoot/input-manifest.yaml');
    final runnerFile = File('$experimentRoot/run_benchmark.py');

    expect(contractFile.existsSync(), isTrue);
    expect(manifestFile.existsSync(), isTrue);
    expect(runnerFile.existsSync(), isTrue);

    final contract = contractFile.readAsStringSync();
    expect(contract, contains('scope: host_only_strict_lossless_completion'));
    expect(contract, contains('production_changes: forbidden'));
    expect(contract, contains('phone_access: forbidden'));
    expect(contract, contains('run_each_registered_arm_once: true'));
    expect(contract, contains('seed: 20260802'));

    expect(contract, contains('bytes: 198983680'));
    expect(
      contract,
      contains(
        '0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0',
      ),
    );
    expect(contract, contains('bytes: 1162370'));
    expect(
      contract,
      contains(
        'ba941c8b1fff4e6bbeb270aed8f4e328a14e570c46647dbd91b48e74c713dd3a',
      ),
    );

    expect(contract, contains('3dceb64867840201fb8f57a29d179995f700c9b8'));
    expect(contract, contains('typed_parser'));
    expect(contract, contains('untrained_parser'));
    expect(contract, contains('ace_complete'));
    expect(contract, contains('clustering_plus_ace_complete'));
    expect(contract, contains('disjoint_train_test: true'));
    expect(contract, contains('training_time_limit_seconds: null'));

    expect(contract, contains('31ca0ed11c93c99d3f5b5c30e01a3e1c3832d3ce'));
    expect(contract, contains('all_ieee_bits_equal: true'));
    expect(contract, contains('preserve_nan_payloads: true'));
    expect(contract, contains('preserve_signed_zero: true'));

    expect(contract, contains('f8698a7bdda2c4e171017548307179cd5c7a3166'));
    expect(contract, contains('license_choice: Apache-2.0'));
    expect(contract, contains('compression_windows: [3, 7]'));
    expect(contract, contains('maximum_reference_counts: [3, 7]'));
    expect(contract, contains('minimum_interval_lengths: [2, 4]'));
    expect(contract, contains('count_graph_file: true'));
    expect(contract, contains('count_properties_file: true'));
    expect(contract, contains('count_elias_fano_file: true'));
    expect(contract, contains('count_reversible_mappings: true'));

    expect(
      contract,
      contains('stages: [minimum, approximately_100mb, complete]'),
    );
    expect(contract, contains('complete_persisted_bytes: true'));
    expect(contract, contains('byte_equal: true'));
    expect(contract, contains('sha256_equal: true'));
    expect(contract, contains('sqlite_integrity_check: ok'));
    expect(contract, contains('random_reads_exact: true'));
  });

  test('input manifest is ordered, complete, and content-addressed', () {
    final manifest =
        jsonDecode(
              File('$experimentRoot/input-manifest.yaml').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final entries = (manifest['entries'] as List<dynamic>)
        .cast<Map<String, dynamic>>();

    expect(manifest['capture_id'], 'cap_1785512421333592');
    expect(manifest['ordering'], 'normalized_relative_path_utf8');
    expect(entries, isNotEmpty);

    final paths = entries.map((entry) => entry['path'] as String).toList();
    expect(paths, orderedEquals([...paths]..sort()));
    expect(entries.every((entry) => (entry['bytes'] as int) >= 0), isTrue);
    expect(
      entries.every(
        (entry) =>
            RegExp(r'^[0-9a-f]{64}$').hasMatch(entry['sha256'] as String),
      ),
      isTrue,
    );
    expect(
      entries.any((entry) => entry['path'] == 'official_sfm_live.db'),
      isTrue,
    );
    expect(
      entries.any((entry) => entry['path'] == 'official_sfm_sparse.ply'),
      isTrue,
    );
  });

  test('runner cannot mutate production or access an iPhone', () {
    final runner = File('$experimentRoot/run_benchmark.py').readAsStringSync();
    for (final forbidden in <String>{
      'device install app',
      'devicectl',
      'flutter build ios',
      'com.kyle.PocketWorld',
      'Documents/captures_official',
    }) {
      expect(runner, isNot(contains(forbidden)));
    }
  });
}
