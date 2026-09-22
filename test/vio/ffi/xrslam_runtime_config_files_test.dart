import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_build_contract.dart';

void main() {
  test('Dart materializes byte-exact generic-core YAML files', () async {
    const String slam = 'config_version: "1.0"\nsliding_window_size: 10\n';
    const String device = 'config_version: "1.0"\ncam0:\n  model: pinhole\n';

    final XrslamRuntimeConfigFiles files =
        await XrslamRuntimeConfigFiles.materialize(
          slamYaml: slam,
          deviceYaml: device,
        );
    addTearDown(files.dispose);

    expect(await files.slamFile.readAsString(), slam);
    expect(await files.deviceFile.readAsString(), device);
    expect(files.slamFile.path, isNot(contains(slam)));
    expect(files.deviceFile.path, isNot(contains(device)));
    expect(await files.slamFile.exists(), isTrue);
    expect(await files.deviceFile.exists(), isTrue);
  });

  test('dispose only removes its private temporary directory', () async {
    final XrslamRuntimeConfigFiles files =
        await XrslamRuntimeConfigFiles.materialize(
          slamYaml: 'a: 1\n',
          deviceYaml: 'b: 2\n',
        );
    final String ownedDirectory = files.directory.path;

    await files.dispose();

    expect(await Directory(ownedDirectory).exists(), isFalse);
  });

  test('frozen generic build contract is platform-neutral', () {
    expect(XrslamBuildContract.xrslamIos, isFalse);
    expect(XrslamBuildContract.threading, isFalse);
    expect(XrslamBuildContract.opencvVersion, '4.0.1');
    expect(XrslamBuildContract.ceresVersion, '1.14.0');
    expect(XrslamBuildContract.compileFlags, const <String>[
      '-ffp-contract=off',
      '-fno-fast-math',
      '-fchar8_t',
      '-Dceres=pw_xrslam_ceres_1_14',
    ]);
  });
}
