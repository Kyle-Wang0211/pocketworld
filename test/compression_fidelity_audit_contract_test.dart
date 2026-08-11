import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compression fidelity audit separates evidence from proposals', () {
    final contract = File(
      'experiments/compression_fidelity_audit/audit-contract.yaml',
    ).readAsStringSync();
    final inventory =
        jsonDecode(
              File(
                'experiments/compression_fidelity_audit/inventory.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    expect(contract, contains('scope: host_only_micro_supplements'));
    expect(contract, contains('maximum_descriptor_bytes: 1048576'));
    expect(contract, contains('maximum_jpeg_count: 1'));
    expect(contract, contains('automatic_scale_up: forbidden'));
    expect(contract, contains('production_changes: forbidden'));

    final schemes = (inventory['schemes'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final names = schemes.map((scheme) => scheme['scheme']).toSet();
    expect(
      names,
      containsAll(<String>{
        'jpeg_xl_exact_jpeg',
        'brunsli',
        'rust_lepton',
        'packjpg',
        'zstd',
        'lzma2',
        'zpaq_method5',
        'libbsc',
        'kanzi_tpaqx',
        'openzl',
        'c_blosc2_b2nd',
        'pcodec',
        'parquet_arrow',
        'orc',
        'tiledb',
        'dwarfs',
        'track_delta_v1',
        'exact_transform_v2',
        'similarity_forest_v1',
        'pwa2',
        'cross_photo_collection',
        'meshoptimizer',
        'fpzip_zfp',
      }),
    );

    const allowed = <String>{
      'faithful_official',
      'faithful_subset',
      'invalid_reproduction',
      'evidence_missing',
      'mentioned_not_run',
      'blocked_no_official_route',
      'validated_internal',
    };
    for (final scheme in schemes) {
      expect(allowed, contains(scheme['classification']));
      expect(scheme['basis'], isNotEmpty);
      expect(scheme['old_claim_disposition'], isNotEmpty);
    }

    for (final name in <String>{
      'track_delta_v1',
      'exact_transform_v2',
      'similarity_forest_v1',
      'pwa2',
    }) {
      expect(
        schemes.singleWhere(
          (scheme) => scheme['scheme'] == name,
        )['classification'],
        'validated_internal',
      );
    }
  });

  test(
    'micro supplement result proves exact restoration and bounded scope',
    () {
      final result =
          jsonDecode(
                File(
                  'experiments/compression_fidelity_audit/results/'
                  '2026-08-02-minimum-units.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;

      expect(result['production_promoted'], false);
      expect(result['phone_accessed'], false);
      expect(result['automatic_repeats'], 0);
      expect(result['descriptor_input_bytes'], 1048576);
      expect(result['jpeg_input_count'], lessThanOrEqualTo(1));

      final arms = (result['arms'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(arms, isNotEmpty);
      for (final arm in arms) {
        expect(arm['official_revision'], isNotEmpty);
        expect(arm['complete_persisted_bytes'], greaterThan(0));
        expect(arm['byte_equal'], 1);
        expect(arm['sha256_equal'], 1);
      }
    },
  );

  test('commercial candidate screen covers every previously unrun route', () {
    final contract = File(
      'experiments/compression_fidelity_audit/'
      'commercial-candidates-contract.yaml',
    ).readAsStringSync();
    final result =
        jsonDecode(
              File(
                'experiments/compression_fidelity_audit/results/'
                '2026-08-02-commercial-candidates-micro.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    expect(contract, contains('scope: host_only_commercial_candidate_micro'));
    expect(contract, contains('maximum_jpeg_count: 1'));
    expect(contract, contains('maximum_descriptor_bytes: 1048576'));
    expect(contract, contains('production_changes: forbidden'));
    expect(contract, contains('phone_access: forbidden'));

    final candidates = (result['candidates'] as List<dynamic>)
        .cast<Map<String, dynamic>>();
    final names = candidates.map((candidate) => candidate['scheme']).toSet();
    expect(
      names,
      containsAll(<String>{
        'jpeg_xl_exact_jpeg',
        'rust_lepton',
        'parquet_arrow',
        'orc',
        'tiledb',
        'dwarfs',
        'meshoptimizer',
        'fpzip',
        'zfp_reversible',
      }),
    );

    const statuses = <String>{
      'measured_exact',
      'blocked_build',
      'blocked_semantics',
      'not_applicable',
    };
    const commercialVerdicts = <String>{
      'allow',
      'conditional',
      'conflict',
      'block',
      'insufficient-evidence',
    };
    for (final candidate in candidates) {
      expect(statuses, contains(candidate['status']));
      expect(commercialVerdicts, contains(candidate['commercial_verdict']));
      expect(candidate['official_revision'], isNotEmpty);
      expect(candidate['basis'], isNotEmpty);
      if (candidate['status'] == 'measured_exact') {
        expect(candidate['complete_persisted_bytes'], greaterThan(0));
        expect(candidate['byte_equal'], 1);
        expect(candidate['sha256_equal'], 1);
      }
    }

    expect(result['production_promoted'], false);
    expect(result['phone_accessed'], false);
  });
}
