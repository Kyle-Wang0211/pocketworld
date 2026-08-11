import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = Directory.current.path;
  final contract = File(
    '$root/experiments/cross_photo_abc/experiment-contract.yaml',
  );
  final input = File('$root/experiments/cross_photo_abc/input-manifest.yaml');

  test('cross-photo A/B/C benchmark freezes the complete exact workload', () {
    final text = contract.readAsStringSync();
    final inputText = input.readAsStringSync();

    expect(text, contains('ordered_jpeg_count: 25'));
    expect(text, contains('ordered_jpeg_bytes: 107649656'));
    expect(text, contains('archive_member_bytes: 88409901'));
    expect(text, contains('early_ratio_stop: disabled'));
    expect(text, contains('count_every_persisted_byte: true'));
    expect(text, contains('restored_bytes_equal: true'));
    expect(text, contains('restored_sha256_equal: true'));
    expect(text, contains('random_read_decodes_at_most_jpegs: 8'));
    expect(inputText, contains('immutable: true'));
    expect(text, contains('minimum_complete_unit_photos: 2'));
    expect(text, contains('next_gate_photos: 8'));
    expect(text, contains('full_gate_minimum_bytes: 104857600'));
    expect(text, contains('requires_strictly_smaller_than_baseline: true'));
  });

  test('host-only benchmark cannot build, install, or mutate production', () {
    final plan = File(
      '$root/docs/superpowers/plans/'
      '2026-08-02-cross-photo-abc-exact-benchmark.md',
    ).readAsStringSync();
    final contractText = contract.readAsStringSync();
    final combined = '$plan\n$contractText'.toLowerCase();

    expect(combined, isNot(contains('flutter build ios')));
    expect(combined, isNot(contains('devicectl device install')));
    expect(combined, isNot(contains('flutter drive')));
    expect(contractText, contains('production_behavior_modified: false'));
    expect(contractText, contains('Do not modify production code'));
  });
}
