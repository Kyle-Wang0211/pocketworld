import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('finalized COLMAP reconstruction has a formal dense hand-off', () {
    final header = File(
      'vendor/official_sfm/include/official_sfm_c.h',
    ).readAsStringSync();
    final shim = File(
      'vendor/official_sfm/src/pwofficial_export_shim.c',
    ).readAsStringSync();
    final ffi = File('lib/official_aether_sfm_ffi.dart').readAsStringSync();

    expect(header, contains('pwofficial_dump_model('));
    expect(
      shim,
      contains('aether_sfm_finalize_status(s) != AETHER_SFM_FINALIZE_REFINED'),
    );
    expect(shim, contains('return AETHER_SFM_ERR_NOT_REGISTERED;'));
    expect(shim, contains('return aether_sfm_debug_dump_model(s, dir);'));
    expect(ffi, contains("'pwofficial_dump_model'"));
    expect(ffi, contains('AetherSfmResult dumpModel(String directory)'));
    expect(ffi, contains('directory.toNativeUtf8()'));
    expect(ffi, contains('malloc.free(directoryPtr)'));
  });

  test('new dense boundary contains no Swift implementation', () {
    final denseSwift = Directory('vendor')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (file) =>
              file.path.contains('official_dense') &&
              file.path.toLowerCase().endsWith('.swift'),
        )
        .toList();

    expect(denseSwift, isEmpty);
  });

  test(
    'packaged device and simulator frameworks export the dense hand-off',
    () {
      const frameworkRoot =
          'vendor/official_sfm/Frameworks/PWOfficialSfm.xcframework';
      const slices = <String>[
        'ios-arm64/PWOfficialSfm.framework',
        'ios-arm64_x86_64-simulator/PWOfficialSfm.framework',
      ];

      for (final slice in slices) {
        final framework = '$frameworkRoot/$slice';
        final binary = '$framework/PWOfficialSfm';
        final symbols = Process.runSync('nm', <String>['-gjU', binary]);

        expect(symbols.exitCode, 0, reason: symbols.stderr.toString());
        expect(
          symbols.stdout.toString().split('\n'),
          contains('_pwofficial_dump_model'),
          reason: '$slice must export the FFI symbol',
        );
        expect(
          File('$framework/Headers/official_sfm_c.h').readAsStringSync(),
          contains('pwofficial_dump_model('),
          reason: '$slice must package the matching public header',
        );
      }
    },
  );

  test('refined worker exports the model before publishing the snapshot', () {
    final worker = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    final refinedBranch = worker.indexOf(
      'if (st == AetherSfmFinalizeStatus.refined)',
    );
    final dump = worker.indexOf(
      's.dumpModel(stagedSparseDir.path)',
      refinedBranch,
    );
    final publishModel = worker.indexOf(
      'stagedSparseDir.renameSync(denseSparseDir.path)',
      refinedBranch,
    );
    final transaction = worker.indexOf(
      'DenseTransactionManifest.writeSync(',
      refinedBranch,
    );
    final publish = worker.indexOf("sendSnapshot('refined'", refinedBranch);

    expect(refinedBranch, greaterThanOrEqualTo(0));
    expect(dump, greaterThan(refinedBranch));
    expect(transaction, greaterThan(dump));
    expect(publishModel, greaterThan(transaction));
    expect(publish, greaterThan(publishModel));
    expect(worker, contains('generation: publishToken'));
    expect(worker, contains('dense_transaction_manifest.dart'));
    expect(worker, contains('followLinks: false'));
    expect(worker, contains("'official_dense_model_dir'"));
    expect(worker, contains("'official_dense_handoff_status'"));
  });
}
