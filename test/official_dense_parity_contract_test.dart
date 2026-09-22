import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const parityRoot = 'vendor/official_dense/parity';

  test('CUDA golden capture is pinned and fail-closed', () {
    final contract = File('$parityRoot/contract.py').readAsStringSync();
    final preflight = File('$parityRoot/preflight.py').readAsStringSync();
    final capture = File(
      '$parityRoot/capture_cuda_golden.py',
    ).readAsStringSync();

    expect(contract, contains('a0d785fba74b2664f31edc4a29026a8b27c00f67'));
    expect(contract, contains('COLMAP_VERSION = "4.1.1"'));
    expect(contract, contains('PTX_ARCH = "compute_90"'));
    expect(contract, contains('FORBIDDEN_SASS_ARCHES = ("sm_100", "sm_120")'));
    expect(preflight, contains('nvidia-smi'));
    expect(preflight, contains('nvcc'));
    expect(preflight, contains('cuobjdump'));
    expect(preflight, contains('git'));
    expect(preflight, contains('input_manifest_sha256'));
    expect(preflight, contains('default_parameters'));
    expect(capture, contains('repeat_count'));
    expect(capture, contains('repeat_count < 2'));

    final noCuda = Process.runSync(
      '/usr/bin/python3',
      ['$parityRoot/preflight.py', '--help'],
      environment: const {'PATH': '/definitely/no/cuda/tools'},
    );
    expect(noCuda.exitCode, 0);

    final rejected = Process.runSync(
      '/usr/bin/python3',
      ['$parityRoot/preflight.py'],
      environment: const {'PATH': '/definitely/no/cuda/tools'},
    );
    expect(rejected.exitCode, isNonZero);
    expect('${rejected.stdout}${rejected.stderr}', contains('FAIL-CLOSED'));
  });

  test('artifact contract captures every official PatchMatch stage', () {
    final contract = File('$parityRoot/artifact_contract.json');
    final payload =
        jsonDecode(contract.readAsStringSync()) as Map<String, dynamic>;
    final artifacts = (payload['per_reference_artifacts'] as List)
        .cast<String>();

    expect(payload['sweeps_per_iteration'], 4);
    expect(payload['default_num_iterations'], 5);
    expect(payload['required_repeat_baselines'], greaterThanOrEqualTo(2));
    expect(artifacts, contains('ref_filter'));
    expect(artifacts, contains('initial_cost'));
    expect(artifacts, contains('sweep_depth'));
    expect(artifacts, contains('sweep_normal'));
    expect(artifacts, contains('sweep_cost'));
    expect(artifacts, contains('sweep_sel'));
    expect(artifacts, contains('sweep_mask'));
    expect(artifacts, contains('final_consistency_graph'));
    expect(payload['global_artifacts'], contains('fused_ply'));
  });

  test('comparator refuses thresholds without measured noise floor', () {
    final comparator = File('$parityRoot/compare_runs.py').readAsStringSync();
    expect(comparator, contains('noise_floor'));
    expect(comparator, contains('validate_run_structure'));
    expect(comparator, contains('FAIL-CLOSED'));

    final temp = Directory.systemTemp.createTempSync('pw_dense_parity_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final left = Directory('${temp.path}/left')..createSync();
    final right = Directory('${temp.path}/right')..createSync();
    final rejected = Process.runSync('/usr/bin/python3', [
      '$parityRoot/compare_runs.py',
      '--reference',
      left.path,
      '--candidate',
      right.path,
    ]);
    expect(rejected.exitCode, isNonZero);
    expect('${rejected.stdout}${rejected.stderr}', contains('noise-floor'));
  });

  test(
    'full workspace comparator covers every official final map per image',
    () {
      final comparator = File(
        '$parityRoot/compare_colmap_workspaces.py',
      ).readAsStringSync();

      expect(comparator, contains('read_frozen_scene_image_names'));
      expect(comparator, contains('photometric_depth'));
      expect(comparator, contains('photometric_normal'));
      expect(comparator, contains('geometric_depth'));
      expect(comparator, contains('geometric_normal'));
      expect(comparator, contains('geometric_consistency_graph'));
      expect(comparator, contains('--require-bitwise-identical'));
      expect(comparator, isNot(contains('tolerance')));
    },
  );

  test('workspace inspector exposes exact resumable per-phase progress', () {
    final inspector = File(
      '$parityRoot/inspect_colmap_workspace.py',
    ).readAsStringSync();

    expect(inspector, contains('photometric_complete'));
    expect(inspector, contains('geometric_complete'));
    expect(inspector, contains('next_photometric_image'));
    expect(inspector, contains('next_geometric_image'));
    expect(inspector, contains('corrupt_outputs'));
    expect(inspector, contains('--require-complete'));
  });

  test('probe budget exposes exact static queue and storage work', () {
    final budget = File(
      '$parityRoot/probe_plan_budget.py',
    ).readAsStringSync();

    expect(budget, contains('read_frozen_scene_manifest'));
    expect(budget, contains('queue_submits_per_split_phase'));
    expect(budget, contains('full_scene_queue_submits'));
    expect(budget, contains('float_map_payload_bytes'));
    expect(budget, contains('consistency_graph_bytes'));
    expect(budget, contains('one_reference_phase'));
  });
}
