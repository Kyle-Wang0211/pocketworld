import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repository = Directory.current;
  final contract = File(
    '${repository.path}/experiments/descriptor_chunk_official_backends/'
    'experiment-contract.yaml',
  );
  final runner = File(
    '${repository.path}/tool/run_descriptor_chunk_official_backends_bench.sh',
  );
  final source = File(
    '${repository.path}/tool/descriptor_chunk_official_backends_bench.cpp',
  );

  test('contract freezes one 2 MiB complete descriptor chunk', () {
    final text = contract.readAsStringSync();
    expect(text, contains('descriptor_count: 16384'));
    expect(text, contains('dimension: 128'));
    expect(text, contains('raw_bytes: 2097152'));
    expect(text, contains('root_count: 8192'));
    expect(text, contains('predicted_count: 8192'));
    expect(
      text,
      contains(
        'stopping_rule: one_encode_decode_corruption_cycle_per_arm_then_stop',
      ),
    );
  });

  test('runner pins official upstreams and refuses large or phone work', () {
    final text = runner.readAsStringSync();
    expect(text, contains('3dceb64867840201fb8f57a29d179995f700c9b8'));
    expect(text, contains('7265419b23872707b1b52298d5f1469c9ea7b9e7'));
    expect(text, contains('2d8555888b21bbaa19326580b740fa24b7da6bd3'));
    expect(text, contains('descriptor_count=16384'));
    expect(text, isNot(contains('flutter build')));
    expect(text, isNot(contains('devicectl')));
    expect(text, isNot(contains('device install')));
  });

  test(
    'benchmark counts complete bytes and enforces exact corruption gates',
    () {
      final text = source.readAsStringSync();
      expect(text, contains('complete_persisted_bytes'));
      expect(text, contains('parent_sidecar_bytes'));
      expect(text, contains('original_sha256_equal'));
      expect(text, contains('transformed_sha256_equal'));
      expect(text, contains('corruption_rejected'));
      expect(text, contains('production_promoted'));
    },
  );
}
