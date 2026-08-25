import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/global_ptol_benchmark_gate.dart';

const _benchmarkBundleId = 'com.kyle.PocketWorld.PtolBench';
const _productionBundleId = 'com.kyle.PocketWorld';

const _archiveSha256 =
    '9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4';
const _archiveManifestSha256 =
    '3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e';
const _poseSha256 =
    'd4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1';
const _materializedSqliteSha256 =
    'f829c281aea6ed7956e3afb134959b663cf35cfee633956029c09d3b2af3290d';
const _nativeFrameworkSha256 =
    'bd1220f12b84b6de06319bda28e2902d375b59b9150d3dd947bc1d04afc34062';

void main() {
  group('host runner and phone entrypoint contract', () {
    late String runner;
    late String entrypoint;

    setUpAll(() {
      runner = _readRequiredSource('tool/run_global_ptol_phone_ab.sh');
      entrypoint = _readRequiredSource('lib/global_ptol_benchmark_main.dart');
    });

    test('uses only the isolated benchmark bundle and safe build settings', () {
      expect(
        runner,
        contains('bundle_id="$_benchmarkBundleId"'),
        reason: 'The runner must freeze the independent benchmark bundle ID.',
      );
      expect(runner, isNot(contains('device uninstall app')));
      expect(runner, contains('--domain-identifier "\$bundle_id"'));
      expect(runner, contains('PRODUCT_BUNDLE_IDENTIFIER="\$bundle_id"'));
      expect(runner, contains('--no-pub'));
      expect(runner, contains('CODE_SIGNING_ALLOWED=NO'));
      expect(runner, contains('device info details'));
      expect(runner, contains('iPhone 14 Pro'));
      expect(runner, contains('00008120-00146C4A1AEBC01E'));
      expect(runner, contains('Flutter 3.47.1'));
      expect(runner, contains('Dart SDK version: 3.13.1'));
      expect(runner, contains('expected_source_manifest_sha='));
      expect(runner, contains('PW_PTOL_EXPECTED_RUNNER_SHA256'));
      expect(runner, contains('PW_PTOL_EXPECTED_IDENTITY_RECEIPT_SHA256'));
      expect(runner, contains('candidate-identity.yaml'));
      expect(runner, contains('/usr/bin/python3 -I -'));
      expect(runner, contains('def require(condition, message):'));
      expect(runner, isNot(contains('\nassert ')));
      expect(runner, contains('signed_native_cdhash'));
      expect(runner, contains('attempt/720'));

      _expectNoDeviceOperationTargetsProductionBundle(runner);
    });

    test('freezes the exact A/B/A/B arm order and PTOL values', () {
      final armContract = RegExp(
        r"GlobalPtolArmSpec\(\s*label:\s*'A1',\s*ptol:\s*'0'\s*\)"
        r"[\s\S]*GlobalPtolArmSpec\(\s*label:\s*'B1',\s*ptol:\s*'1e-8'\s*\)"
        r"[\s\S]*GlobalPtolArmSpec\(\s*label:\s*'A2',\s*ptol:\s*'0'\s*\)"
        r"[\s\S]*GlobalPtolArmSpec\(\s*label:\s*'B2',\s*ptol:\s*'1e-8'\s*\)",
      );

      expect(
        entrypoint,
        matches(armContract),
        reason:
            'The phone entrypoint must declare A1=0, B1=1e-8, '
            'A2=0, B2=1e-8 in that exact order.',
      );
    });

    test('checks every frozen input and native framework identity', () {
      final sources = '$runner\n$entrypoint';
      for (final digest in <String>[
        _archiveSha256,
        _archiveManifestSha256,
        _poseSha256,
        _materializedSqliteSha256,
        _nativeFrameworkSha256,
      ]) {
        expect(sources, contains(digest));
      }
    });

    test('pulls the result and emits the final success marker', () {
      expect(entrypoint, contains('global_ptol_benchmark_result.json'));
      expect(runner, contains('global_ptol_benchmark_result.json'));
      expect(
        runner,
        contains('device copy from'),
        reason: 'The runner must pull benchmark output from the phone.',
      );
      expect(runner, contains('IPHONE_GLOBAL_PTOL_AB_OK'));
      expect(runner, contains('global_ptol_arm_result.json'));
      expect(runner, contains('hashlib.sha256(payload).hexdigest()'));
      expect(runner, contains('arm["sparse_meta"]["sha256"]'));
      expect(runner, contains('pulled_arm == arm'));
      expect(runner, contains(r'--source "$staged_input"'));
      expect(runner, isNot(contains(r'--source "$input_dir"')));
    });

    test('is a diagnostic screen and restores production resume metadata', () {
      expect(
        entrypoint,
        contains("'experiment_class': 'diagnostic_mechanical_screen'"),
      );
      expect(entrypoint, contains("result['production_eligible'] = false"));
      expect(entrypoint, contains("'advance_to_end_to_end_candidate'"));
      expect(entrypoint, contains('recon.seedFedMeta(fedFrameMeta)'));
      expect(
        entrypoint,
        contains("'pose_source': 'frozen_production_arkit_sidecar'"),
      );
      expect(
        entrypoint,
        contains("'excluded_shadow_pose_source': 'xrslam_vio'"),
      );
      expect(entrypoint, contains('global_ptol_arm_result.json'));
    });
  });

  group('pure preregistered gate', () {
    test('accepts only the exact frozen input identity', () {
      const frozen = GlobalPtolInputIdentity(
        archiveSha256: _archiveSha256,
        archiveManifestSha256: _archiveManifestSha256,
        poseSha256: _poseSha256,
        materializedSqliteSha256: _materializedSqliteSha256,
        nativeFrameworkSha256: _nativeFrameworkSha256,
      );

      expect(isFrozenGlobalPtolInputIdentity(frozen), isTrue);
      expect(
        isFrozenGlobalPtolInputIdentity(
          const GlobalPtolInputIdentity(
            archiveSha256: _archiveSha256,
            archiveManifestSha256: _archiveManifestSha256,
            poseSha256: _poseSha256,
            materializedSqliteSha256: 'wrong-sqlite-hash',
            nativeFrameworkSha256: _nativeFrameworkSha256,
          ),
        ),
        isFalse,
      );
    });

    test('accepts only A1=0, B1=1e-8, A2=0, B2=1e-8', () {
      expect(hasExactGlobalPtolArmOrder(_passingArms()), isTrue);

      final reordered = _passingArms();
      final temporary = reordered[1];
      reordered[1] = reordered[2];
      reordered[2] = temporary;
      expect(hasExactGlobalPtolArmOrder(reordered), isFalse);

      final wrongValue = _passingArms();
      wrongValue[3] = _arm('B2', '1e-7', elapsedMs: 830);
      expect(hasExactGlobalPtolArmOrder(wrongValue), isFalse);
    });

    test('quality requires equal cameras, points within 1%, and reprojection '
        'no worse than 0.01 px', () {
      final control = _arm(
        'A1',
        '0',
        elapsedMs: 1000,
        registeredCameras: 100,
        pointCount: 10000,
        reprojectionErrorPx: 0.40,
      );

      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm(
            'B1',
            '1e-8',
            elapsedMs: 850,
            registeredCameras: 100,
            pointCount: 9900,
            reprojectionErrorPx: 0.41,
          ),
        ),
        isTrue,
        reason: 'The inclusive point and reprojection boundaries must pass.',
      );
      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm('B1', '1e-8', elapsedMs: 850, pointCount: 10100),
        ),
        isTrue,
      );
      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm('B1', '1e-8', elapsedMs: 850, registeredCameras: 99),
        ),
        isFalse,
      );
      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm('B1', '1e-8', elapsedMs: 850, pointCount: 10101),
        ),
        isFalse,
      );
      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm('B1', '1e-8', elapsedMs: 850, pointCount: 9899),
        ),
        isFalse,
      );
      expect(
        passesGlobalPtolQualityGate(
          control: control,
          candidate: _arm(
            'B1',
            '1e-8',
            elapsedMs: 850,
            reprojectionErrorPx: 0.411,
          ),
        ),
        isFalse,
      );
    });

    test(
      'repeatability allows at most 10% wall-time drift and no camera drift',
      () {
        expect(
          isGlobalPtolFamilyRepeatable(
            first: _arm('A1', '0', elapsedMs: 1000),
            second: _arm('A2', '0', elapsedMs: 1100),
          ),
          isTrue,
        );
        expect(
          isGlobalPtolFamilyRepeatable(
            first: _arm('A1', '0', elapsedMs: 1000),
            second: _arm('A2', '0', elapsedMs: 1101),
          ),
          isFalse,
        );
        expect(
          isGlobalPtolFamilyRepeatable(
            first: _arm('B1', '1e-8', elapsedMs: 900),
            second: _arm('B2', '1e-8', elapsedMs: 900, registeredCameras: 99),
          ),
          isFalse,
        );
      },
    );

    test('winner requires a faster B median and improvement strictly above '
        'max(5%, observed within-family noise)', () {
      final clearWinner = evaluateGlobalPtolWinner(<GlobalPtolArmMetrics>[
        _arm('A1', '0', elapsedMs: 1000),
        _arm('B1', '1e-8', elapsedMs: 800),
        _arm('A2', '0', elapsedMs: 1080),
        _arm('B2', '1e-8', elapsedMs: 840),
      ]);
      expect(clearWinner.eligible, isTrue);
      expect(clearWinner.aMedianElapsedMs, 1040);
      expect(clearWinner.bMedianElapsedMs, 820);
      expect(
        clearWinner.observedWithinFamilyNoiseFraction,
        closeTo(0.08, 1e-12),
      );
      expect(clearWinner.requiredImprovementFraction, closeTo(0.08, 1e-12));
      expect(
        clearWinner.improvementFraction,
        closeTo((1040 - 820) / 1040, 1e-12),
      );

      final exactlyFivePercent =
          evaluateGlobalPtolWinner(<GlobalPtolArmMetrics>[
            _arm('A1', '0', elapsedMs: 1000),
            _arm('B1', '1e-8', elapsedMs: 950),
            _arm('A2', '0', elapsedMs: 1000),
            _arm('B2', '1e-8', elapsedMs: 950),
          ]);
      expect(exactlyFivePercent.eligible, isFalse);

      final losesToObservedNoise =
          evaluateGlobalPtolWinner(<GlobalPtolArmMetrics>[
            _arm('A1', '0', elapsedMs: 1000),
            _arm('B1', '1e-8', elapsedMs: 960),
            _arm('A2', '0', elapsedMs: 1090),
            _arm('B2', '1e-8', elapsedMs: 960),
          ]);
      expect(losesToObservedNoise.observedWithinFamilyNoiseFraction, 0.09);
      expect(
        losesToObservedNoise.improvementFraction,
        lessThan(losesToObservedNoise.requiredImprovementFraction),
      );
      expect(losesToObservedNoise.eligible, isFalse);

      final slowerB = evaluateGlobalPtolWinner(<GlobalPtolArmMetrics>[
        _arm('A1', '0', elapsedMs: 900),
        _arm('B1', '1e-8', elapsedMs: 901),
        _arm('A2', '0', elapsedMs: 900),
        _arm('B2', '1e-8', elapsedMs: 901),
      ]);
      expect(slowerB.eligible, isFalse);
    });
  });
}

String _readRequiredSource(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: 'Missing required source: $path');
  return file.readAsStringSync();
}

void _expectNoDeviceOperationTargetsProductionBundle(String runner) {
  final logicalLines = runner.replaceAll(RegExp(r'\\\s*\n'), ' ').split('\n');
  final deviceOperations = logicalLines
      .where((line) => line.contains('devicectl') && line.contains(' device '))
      .toList(growable: false);
  final exactProductionBundle = RegExp(
    '${RegExp.escape(_productionBundleId)}(?![A-Za-z0-9.-])',
  );

  expect(
    deviceOperations,
    isNotEmpty,
    reason:
        'The host runner must contain explicit devicectl device operations.',
  );
  for (final operation in deviceOperations) {
    expect(
      operation,
      isNot(matches(exactProductionBundle)),
      reason:
          'No devicectl operation may target the production bundle: '
          '$operation',
    );
    if (operation.contains('--domain-identifier') ||
        operation.contains(' process launch ') ||
        operation.contains(' process terminate ')) {
      expect(
        operation,
        contains('"\$bundle_id"'),
        reason:
            'Every bundle-targeting devicectl operation must use the '
            'already-frozen benchmark bundle variable: $operation',
      );
    }
  }
}

List<GlobalPtolArmMetrics> _passingArms() => <GlobalPtolArmMetrics>[
  _arm('A1', '0', elapsedMs: 1000),
  _arm('B1', '1e-8', elapsedMs: 820),
  _arm('A2', '0', elapsedMs: 1050),
  _arm('B2', '1e-8', elapsedMs: 830),
];

GlobalPtolArmMetrics _arm(
  String label,
  String ptol, {
  required int elapsedMs,
  int registeredCameras = 100,
  int pointCount = 10000,
  double reprojectionErrorPx = 0.40,
}) {
  return GlobalPtolArmMetrics(
    label: label,
    ptol: ptol,
    elapsedMs: elapsedMs,
    registeredCameras: registeredCameras,
    pointCount: pointCount,
    reprojectionErrorPx: reprojectionErrorPx,
    succeeded: true,
    plyBytes: 1,
  );
}
