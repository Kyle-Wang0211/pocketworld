import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release build stamps identity once after every bundle-mutating phase', () {
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final stampScript = File('ios/scripts/stamp_runtime_identity.sh');

    String objectBlock(String id, String name) {
      final marker = '$id /* $name */ = {';
      final start = project.indexOf(marker);
      expect(start, isNonNegative, reason: 'missing PBX object: $name');
      final end = project.indexOf('\n\t\t};', start);
      expect(end, greaterThan(start), reason: 'unterminated PBX object: $name');
      return project.substring(start, end + '\n\t\t};'.length);
    }

    final runnerTargetStart = project.indexOf(
      '97C146ED1CF9000F007C117D /* Runner */ = {',
    );
    expect(runnerTargetStart, isNonNegative);
    final buildPhasesStart = project.indexOf(
      'buildPhases = (',
      runnerTargetStart,
    );
    final buildPhasesEnd = project.indexOf(');', buildPhasesStart);
    expect(buildPhasesStart, isNonNegative);
    expect(buildPhasesEnd, greaterThan(buildPhasesStart));
    final phaseEntries = RegExp(
      r'([0-9A-F]{24}) /\* (.*?) \*/,',
    ).allMatches(project.substring(buildPhasesStart, buildPhasesEnd)).toList();
    final phaseNames = phaseEntries.map((match) => match.group(2)!).toList();
    final phaseIds = {
      for (final match in phaseEntries) match.group(2)!: match.group(1)!,
    };

    const orderedArtifactPhases = [
      'Embed Frameworks',
      'Thin Binary',
      'Clean CodeSign Attributes',
      '[CP] Embed Pods Frameworks',
      '[CP] Copy Pods Resources',
      'Stamp Runtime Identity',
    ];
    for (var index = 1; index < orderedArtifactPhases.length; index++) {
      expect(
        phaseNames.indexOf(orderedArtifactPhases[index - 1]),
        lessThan(phaseNames.indexOf(orderedArtifactPhases[index])),
        reason:
            '${orderedArtifactPhases[index]} must follow '
            '${orderedArtifactPhases[index - 1]}',
      );
    }
    expect(
      phaseNames.where((name) => name == 'Stamp Runtime Identity'),
      hasLength(1),
    );
    expect(
      phaseNames.last,
      'Stamp Runtime Identity',
      reason: 'no target build phase may mutate Runner.app after stamping',
    );

    final thinBinary = objectBlock(phaseIds['Thin Binary']!, 'Thin Binary');
    final stampPhase = objectBlock(
      phaseIds['Stamp Runtime Identity']!,
      'Stamp Runtime Identity',
    );
    expect(thinBinary, isNot(contains('stamp_runtime_identity.sh')));
    expect(
      'stamp_runtime_identity.sh'.allMatches(stampPhase),
      hasLength(1),
      reason: 'the dedicated phase must invoke the stamp script exactly once',
    );
    expect(
      stampPhase,
      contains('/bin/sh \\"\$SRCROOT/scripts/stamp_runtime_identity.sh\\"'),
    );
    expect(stampPhase, contains(r'${TARGET_BUILD_DIR}/${EXECUTABLE_PATH}'));
    expect(
      stampPhase,
      contains(
        r'${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/App.framework/App',
      ),
    );
    expect(
      stampPhase,
      contains(
        r'${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/PWOfficialSfm.framework/PWOfficialSfm',
      ),
    );
    expect(
      stampPhase,
      contains(
        r'${SRCROOT}/../vendor/xrslam/libs/ios-arm64/libxrslam_generic_4beb1a9.a',
      ),
    );
    expect(
      project.lastIndexOf('/usr/bin/codesign --force'),
      lessThan(
        project.indexOf(
          'A64F000000000000000064E2 /* Stamp Runtime Identity */ = {',
        ),
      ),
      reason: 'runtime hashes must be calculated after framework re-signing',
    );
    expect(stampScript.existsSync(), isTrue);

    final script = stampScript.readAsStringSync();
    expect(script, contains('PWProductSourceManifestSHA256'));
    expect(script, contains('PWDartAOTSHA256'));
    expect(script, contains('PWOfficialSfmSHA256'));
    expect(script, contains('PWXrslamSHA256'));
    expect(script, contains('PWXrslamBuildPatchSHA256'));
    expect(script, contains('PWXrslamDestroyLifecyclePatchSHA256'));
    expect(script, contains('PWXrslamAlgorithmBranch'));
    expect(script, contains('PWOpenCVSHA256'));
    expect(script, contains('PWCeresSHA256'));
    expect(script, contains('PWNativeHostUUID'));
    expect(script, contains('PWLiveCloudDiagnosticBuildId'));
    expect(script, contains('App.framework/App'));
    expect(script, contains('PWOfficialSfm.framework/PWOfficialSfm'));
    expect(
      script,
      contains('vendor/xrslam/libs/ios-arm64/libxrslam_generic_4beb1a9.a'),
    );
    expect(script, contains('PW_PRODUCT_SOURCE_MANIFEST_SHA256'));
    expect(script, contains('PW_DIAGNOSTIC_BUILD_ID'));
    expect(script, contains('/usr/bin/xcrun dwarfdump --uuid'));
    expect(script, contains('exactly one arm64 LC_UUID'));
    expect(script, contains('identity value is missing'));
  });

  test('release stamp writes exact source and artifact receipts', () {
    final root = Directory.systemTemp.createTempSync('pw-runtime-identity-');
    addTearDown(() => root.deleteSync(recursive: true));

    final sourceRoot = Directory('${root.path}/ios')..createSync();
    final app = Directory('${root.path}/build/Runner.app')
      ..createSync(recursive: true);
    final nativeSource = File('${root.path}/native_host.c')
      ..writeAsStringSync('int main(void) { return 0; }\n');
    final nativeHost = File('${app.path}/Runner');
    final ProcessResult compileNativeHost = Process.runSync('/usr/bin/xcrun', [
      'clang',
      '-arch',
      'arm64',
      nativeSource.path,
      '-o',
      nativeHost.path,
    ]);
    expect(
      compileNativeHost.exitCode,
      0,
      reason: '${compileNativeHost.stdout}\n${compileNativeHost.stderr}',
    );
    final frameworks = Directory('${app.path}/Frameworks')..createSync();
    final dartAot = File('${frameworks.path}/App.framework/App')
      ..createSync(recursive: true)
      ..writeAsStringSync('dart-aot');
    final officialSfm =
        File('${frameworks.path}/PWOfficialSfm.framework/PWOfficialSfm')
          ..createSync(recursive: true)
          ..writeAsStringSync('official-sfm');
    final xrslam =
        File(
            '${root.path}/vendor/xrslam/libs/ios-arm64/'
            'libxrslam_generic_4beb1a9.a',
          )
          ..createSync(recursive: true)
          ..writeAsStringSync('xrslam');
    final ceres = File(
      '${root.path}/vendor/xrslam/libs/ios-arm64/'
      'libceres_official_1_14.a',
    )..writeAsStringSync('ceres');
    final opencv = File(
      '${root.path}/vendor/xrslam/libs/ios-arm64/'
      'libopencv_generic_4_0_1.a',
    )..writeAsStringSync('opencv');
    final plist = File('${app.path}/Info.plist')
      ..writeAsStringSync('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>''');

    final sourceManifest = 'a' * 64;
    final result = Process.runSync(
      '/bin/sh',
      ['ios/scripts/stamp_runtime_identity.sh'],
      workingDirectory: Directory.current.path,
      environment: {
        ...Platform.environment,
        'CONFIGURATION': 'Release',
        'TARGET_BUILD_DIR': '${root.path}/build',
        'INFOPLIST_PATH': 'Runner.app/Info.plist',
        'EXECUTABLE_PATH': 'Runner.app/Runner',
        'FRAMEWORKS_FOLDER_PATH': 'Runner.app/Frameworks',
        'SRCROOT': sourceRoot.path,
        'PW_PRODUCT_SOURCE_MANIFEST_SHA256': sourceManifest,
        'PW_DIAGNOSTIC_BUILD_ID': 'build-37-contract',
      },
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    String plistValue(String key) {
      final read = Process.runSync('/usr/libexec/PlistBuddy', [
        '-c',
        'Print :$key',
        plist.path,
      ]);
      expect(read.exitCode, 0, reason: '${read.stdout}\n${read.stderr}');
      return (read.stdout as String).trim();
    }

    String sha256(File file) =>
        (Process.runSync('/usr/bin/shasum', ['-a', '256', file.path]).stdout
                as String)
            .split(RegExp(r'\s+'))
            .first;

    expect(plistValue('PWProductSourceManifestSHA256'), sourceManifest);
    expect(plistValue('PWLiveCloudDiagnosticBuildId'), 'build-37-contract');
    expect(plistValue('PWDartAOTSHA256'), sha256(dartAot));
    expect(plistValue('PWOfficialSfmSHA256'), sha256(officialSfm));
    expect(plistValue('PWXrslamSHA256'), sha256(xrslam));
    expect(plistValue('PWOpenCVSHA256'), sha256(opencv));
    expect(plistValue('PWCeresSHA256'), sha256(ceres));
    expect(plistValue('PWXrslamAlgorithmBranch'), 'generic');
    expect(plistValue('PWXrslamIosEnabled'), 'false');
    expect(plistValue('PWXrslamThreadingEnabled'), 'false');
    final ProcessResult hostUuidResult = Process.runSync('/usr/bin/xcrun', [
      'dwarfdump',
      '--uuid',
      nativeHost.path,
    ]);
    final RegExpMatch? hostUuid = RegExp(
      r'UUID: ([0-9A-Fa-f-]{36}) \(arm64',
    ).firstMatch(hostUuidResult.stdout as String);
    expect(hostUuid, isNotNull);
    expect(plistValue('PWNativeHostUUID'), hostUuid!.group(1));
  });

  test('release stamp rejects malformed source identity and build label', () {
    ProcessResult runWith({required String manifest, required String buildId}) {
      return Process.runSync(
        '/bin/sh',
        ['ios/scripts/stamp_runtime_identity.sh'],
        workingDirectory: Directory.current.path,
        environment: {
          ...Platform.environment,
          'CONFIGURATION': 'Release',
          'PW_PRODUCT_SOURCE_MANIFEST_SHA256': manifest,
          'PW_DIAGNOSTIC_BUILD_ID': buildId,
        },
      );
    }

    final malformedManifest = runWith(
      manifest: 'not-a-sha256',
      buildId: 'build-37-contract',
    );
    expect(malformedManifest.exitCode, 65);
    expect(malformedManifest.stderr, contains('identity value is invalid'));

    final unsafeBuildId = runWith(
      manifest: 'b' * 64,
      buildId: 'bad label/with spaces',
    );
    expect(unsafeBuildId.exitCode, 65);
    expect(unsafeBuildId.stderr, contains('identity value is invalid'));
  });
}
