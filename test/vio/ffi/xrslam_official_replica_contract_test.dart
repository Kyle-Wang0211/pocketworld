import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production links the frozen generic XRSLAM core and ABI only', () {
    final String podfile = File('ios/Podfile').readAsStringSync();
    final String header = File(
      'vendor/xrslam/include/XRSLAM.h',
    ).readAsStringSync();

    expect(podfile, contains('libxrslam_generic_4beb1a9.a'));
    expect(podfile, contains('libopencv_generic_4_0_1.a'));
    expect(podfile, isNot(contains('opencv2.framework/opencv2')));
    expect(podfile, contains('libceres_official_1_14.a'));
    for (final String symbol in <String>[
      'XRSLAMCreate',
      'XRSLAMPushSensorData',
      'XRSLAMRunOneFrame',
      'XRSLAMGetResult',
      'XRSLAMDestroy',
    ]) {
      expect(podfile, contains(symbol));
    }
    expect(podfile, contains('"-Wl,-u,_#{n}"'));
    expect(podfile, contains('"-Wl,-exported_symbol,_#{n}"'));
    for (final String forkOnlySymbol in <String>[
      'XRSLAMPushSensorDataChecked',
      'XRSLAMGetHealth',
      'XRSLAMTryGetLatestPose',
      'XRSLAMGetDepthFusionStats',
    ]) {
      expect(podfile, isNot(contains(forkOnlySymbol)));
      expect(header, isNot(contains(forkOnlySymbol)));
    }

    expect(header, contains('typedef struct XRSLAMImage'));
    expect(header, contains('XRSLAMImageExtension *ext'));
    expect(header, isNot(contains('int width;')));
    expect(header, isNot(contains('int height;')));
    expect(header, isNot(contains('readout_time')));
    expect(header, isNot(contains('timestamp_convention')));
  });

  test('one shared C++ transport owns every official core call', () {
    final String source = File(
      'ios/Runner/PwVioSlamFeeder.swift',
    ).readAsStringSync();
    final String shared = File(
      'vendor/xrslam/transport/PwXrslamTransportCore.cpp',
    ).readAsStringSync();
    final String android = File(
      'android_ready/native/xrslam/PwXrslamTransport.cpp',
    ).readAsStringSync();

    for (final String directCall in <String>[
      'XRSLAMCreate(',
      'XRSLAMPushSensorData(',
      'XRSLAMRunOneFrame(',
      'XRSLAMGetResult(',
      'XRSLAMDestroy(',
    ]) {
      expect(source, isNot(contains(directCall)));
      expect(android, isNot(contains(directCall)));
    }
    expect(source, isNot(contains('img.width')));
    expect(source, isNot(contains('img.height')));
    expect(
      RegExp(r'XRSLAMPushSensorData\(XRSLAM_SENSOR_CAMERA').allMatches(shared),
      hasLength(1),
    );
    expect(
      RegExp(
        r'XRSLAMPushSensorData\(XRSLAM_SENSOR_ACCELERATION',
      ).allMatches(shared),
      hasLength(1),
    );
    expect(
      RegExp(
        r'XRSLAMPushSensorData\(XRSLAM_SENSOR_GYROSCOPE',
      ).allMatches(shared),
      hasLength(1),
    );
    expect(shared, contains('XRSLAMRunOneFrame()'));
    expect(shared, contains('XRSLAMGetResult(XRSLAM_RESULT_STATE'));
    expect(shared, contains('XRSLAMGetResult(XRSLAM_RESULT_CAMERA_POSE'));
    expect(source, contains('PWXrslamTransportPushCameraAndRunRaw'));
    expect(source, contains('PWXrslamTransportPushAccelerationRaw'));
    expect(source, contains('PWXrslamTransportPushGyroscopeRaw'));
    expect(source, contains('rawStateCallCompleted'));
    expect(source, contains('rawCameraPoseCallCompleted'));
    expect(source, isNot(contains('poseAvailable')));
    expect(source, isNot(contains('quaternionNormSquared')));
    expect(source, isNot(contains('poseFinite')));
    expect(source, isNot(contains('rawDegenerateFlag')));
    expect(source, isNot(contains('rawPoseRc')));
    expect(source, isNot(contains('rawCameraPoseRc')));
  });

  test(
    'shadow admission is fixed-bounded and never pressure-throttles capture',
    () {
      final String source = File(
        'ios/Runner/PwVioSlamFeeder.swift',
      ).readAsStringSync();

      expect(source, contains('private static let maxQueuedWork = 256'));
      expect(source, contains('private static let maxRetainedImages = 2'));
      expect(source, contains('guard lock.try() else'));
      expect(source, contains('reason: .cameraFull'));
      expect(source, contains('reason: .queueFull'));
      expect(source, contains('pendingWork[pendingTail] = work'));
      expect(source, contains('invalidateRunLocked'));
      expect(source, contains('coreQueue.async'));
    },
  );

  test('runtime receipt hashes the frozen official core artifact', () {
    final String script = File(
      'ios/scripts/stamp_runtime_identity.sh',
    ).readAsStringSync();
    expect(script, contains('libxrslam_generic_4beb1a9.a'));
    expect(script, contains('PWXrslamUpstreamRevision'));
    expect(script, contains('4beb1a942f33da9afbfae2d70e2c641cfc2bb675'));
  });

  test(
    'iOS generic artifact is a truthful frozen full-target rebuild',
    () {
      final File candidate = File(
        'vendor/xrslam/libs/ios-arm64/libxrslam_generic_4beb1a9.a',
      );
      final Map<String, Object?> receipt =
          jsonDecode(
                File(
                  'vendor/xrslam/libs/ios-arm64/'
                  'libxrslam_generic_4beb1a9.receipt.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;

      expect(receipt['schema'], 'pw.xrslam.ios-generic-full-build/2');
      expect(receipt['build_mode'], 'full_target_from_frozen_upstream');
      expect(receipt['full_target_rebuild'], true);
      expect(receipt['source_tree_clean_before_declared_patches'], true);
      expect(receipt['xrslam_ios'], false);
      expect(receipt['threading'], false);
      expect(receipt['opencv_version'], '4.0.1');
      expect(
        receipt['opencv_headers_revision'],
        'c9ad5779f2803dcc91a9938142209128d30b22d1',
      );
      expect(receipt, isNot(contains('changed_object')));
      expect(receipt, isNot(contains('changed_objects')));
      expect(
        receipt['artifact_sha256'],
        sha256.convert(candidate.readAsBytesSync()).toString(),
      );

      Map<String, String> memberHashes(File archive) {
        final directory = Directory.systemTemp.createTempSync('pw-xrslam-ar-');
        addTearDown(() => directory.deleteSync(recursive: true));
        final extract = Process.runSync('xcrun', <String>[
          'ar',
          '-x',
          archive.absolute.path,
        ], workingDirectory: directory.path);
        expect(extract.exitCode, 0, reason: '${extract.stderr}');
        return <String, String>{
          for (final file in directory.listSync().whereType<File>())
            file.uri.pathSegments.last: sha256
                .convert(file.readAsBytesSync())
                .toString(),
        };
      }

      final candidateMembers = memberHashes(candidate);
      expect(candidateMembers.length, receipt['archive_member_count']);
      expect(candidateMembers.keys, contains('XRSLAMManager.cpp.o'));
      expect(candidateMembers.keys, contains('worker.cpp.o'));

      final symbols = Process.runSync('nm', <String>[
        '-arch',
        'arm64',
        '-u',
        candidate.absolute.path,
      ]);
      expect(symbols.exitCode, 0, reason: '${symbols.stderr}');
      final undefined = '${symbols.stdout}';
      expect(undefined, isNot(contains('AlgorithmHint')));
      expect(undefined, isNot(contains('thread::join')));
      expect(undefined, isNot(contains('condition_variable::wait')));
    },
  );

  test('official Destroy ABI reaches the upstream Detail destructor', () {
    final File patch = File(
      'vendor/xrslam/patches/xrslam_destroy_lifecycle.patch',
    );
    expect(patch.existsSync(), isTrue);
    final String source = patch.readAsStringSync();
    expect(source, contains('cur_image_.reset();'));
    expect(source, contains('detail_.reset();'));
    expect(source, contains('config_.reset();'));
    expect(
      source.indexOf('detail_.reset();'),
      lessThan(source.indexOf('config_.reset();')),
      reason: 'the official Detail destructor owns worker stop/join',
    );

    final String contract = File(
      'lib/vio/ffi/xrslam_build_contract.dart',
    ).readAsStringSync();
    expect(contract, contains('destroyLifecyclePatchSha256'));
  });

  test('both platforms declare one generic build contract', () {
    final String contract = File(
      'lib/vio/ffi/xrslam_build_contract.dart',
    ).readAsStringSync();
    final String android = File(
      'android_ready/native/xrslam/CMakeLists.txt',
    ).readAsStringSync();
    final String podspec = File(
      'vendor/xrslam/xrslam.podspec',
    ).readAsStringSync();

    for (final String value in <String>[
      '4beb1a942f33da9afbfae2d70e2c641cfc2bb675',
      '4.0.1',
      'e809cf0c2879f521078b4c9e6329390b42ecf722',
      '1.14.0',
      '3.3.7',
      '-ffp-contract=off',
      '-fno-fast-math',
      '-fchar8_t',
      '-Dceres=pw_xrslam_ceres_1_14',
    ]) {
      expect(contract, contains(value));
    }
    expect(contract, contains('xrslamIos = false'));
    expect(contract, contains('threading = false'));
    expect(android, contains('XRSLAM_IOS OFF'));
    expect(android, contains('XRSLAM_ENABLE_THREADING OFF'));
    expect(android, isNot(contains('XRSLAM_IOS=0')));
    expect(android, contains('libxrslam_generic_4beb1a9.so'));
    expect(podspec, contains('generic C++ core'));
    expect(podspec, isNot(contains('upstream iOS route')));
  });

  test('Android core has a reproducible, artifact-bound build receipt', () {
    final File script = File(
      'android_ready/native/xrslam/build_generic_core.sh',
    );
    final File receiptFile = File(
      'android_ready/native/xrslam/core_build_receipt.json',
    );
    expect(script.existsSync(), isTrue);
    expect(receiptFile.existsSync(), isTrue);
    final Map<String, Object?> receipt =
        jsonDecode(receiptFile.readAsStringSync()) as Map<String, Object?>;
    expect(
      receipt['xrslamRevision'],
      '4beb1a942f33da9afbfae2d70e2c641cfc2bb675',
    );
    expect(
      receipt['opencvRevision'],
      'c9ad5779f2803dcc91a9938142209128d30b22d1',
    );
    expect(
      receipt['ceresRevision'],
      'e809cf0c2879f521078b4c9e6329390b42ecf722',
    );
    expect(
      receipt['eigenRevision'],
      'cf794d3b741a6278df169e58461f8529f43bce5d',
    );
    expect(
      receipt['spdlogRevision'],
      'a7148b718ea2fabb8387cb90aee9bf448da63e65',
    );
    expect(
      receipt['yamlCppRevision'],
      '0579ae3d976091d7d664aa9d2527e0d0cff25763',
    );
    expect(receipt['xrslamIos'], false);
    expect(receipt['threading'], false);
    expect(receipt['compileFlags'], <String>[
      '-ffp-contract=off',
      '-fno-fast-math',
      '-fchar8_t',
      '-Dceres=pw_xrslam_ceres_1_14',
    ]);
    final File core = File(
      'android_ready/native/xrslam/libs/arm64-v8a/'
      'libxrslam_generic_4beb1a9.so',
    );
    expect(
      sha256.convert(core.readAsBytesSync()).toString(),
      receipt['sha256'],
    );
    final String buildScript = script.readAsStringSync();
    for (final String frozen in <String>[
      '4beb1a942f33da9afbfae2d70e2c641cfc2bb675',
      'c9ad5779f2803dcc91a9938142209128d30b22d1',
      'e809cf0c2879f521078b4c9e6329390b42ecf722',
      'cf794d3b741a6278df169e58461f8529f43bce5d',
      'a7148b718ea2fabb8387cb90aee9bf448da63e65',
      '0579ae3d976091d7d664aa9d2527e0d0cff25763',
      'XRSLAM_IOS=OFF',
      'XRSLAM_ENABLE_THREADING=OFF',
      'require_hash "\$rebuilt" "\$expected_artifact_sha256"',
      'llvm-strip" --strip-debug',
      '-ffile-prefix-map=',
      'verify_toolchain',
    ]) {
      expect(buildScript, contains(frozen));
    }
  });

  test('generic core receives Dart-created config file paths', () {
    final String dartChannel = File(
      'lib/vio/timebase/ios_timebase_channel.dart',
    ).readAsStringSync();
    final String timebase = File(
      'ios/Runner/PwVioTimebase.swift',
    ).readAsStringSync();
    final String feeder = File(
      'ios/Runner/PwVioSlamFeeder.swift',
    ).readAsStringSync();

    expect(dartChannel, contains('slamConfigPath'));
    expect(dartChannel, contains('deviceConfigPath'));
    expect(timebase, contains('slamConfigPath'));
    expect(timebase, contains('deviceConfigPath'));
    expect(feeder, contains('slamConfigPath'));
    expect(feeder, contains('deviceConfigPath'));
    expect(feeder, isNot(contains('slamYaml')));
    expect(feeder, isNot(contains('deviceYaml')));
  });

  test('Android XRSLAM adapter exposes raw transport and no policy', () {
    final String kotlin = File(
      'android_ready/kotlin/com/pocketworld/capture/PwXrslamTransport.kt',
    ).readAsStringSync();
    final String cpp = File(
      'android_ready/native/xrslam/PwXrslamTransport.cpp',
    ).readAsStringSync();

    for (final String call in <String>[
      'create',
      'destroy',
      'pushCameraAndRunRaw',
      'pushAcceleration',
      'pushGyroscope',
    ]) {
      expect(kotlin, contains(call));
    }
    expect(cpp, contains('PWXrslamTransportPushCameraAndRunRaw'));
    expect(cpp, contains('PwXrslamTransportCore.h'));
    expect(kotlin, isNot(contains('runOneFrame')));
    expect(kotlin, isNot(contains('rawState')));
    expect(kotlin, isNot(contains('rawCameraPose')));
    expect(kotlin, isNot(contains('isPoseUsable')));
    expect(kotlin, isNot(contains('trackingSuccess')));
    expect(kotlin, isNot(contains('threshold')));
  });
}
