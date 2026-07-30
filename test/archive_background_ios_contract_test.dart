import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Runner registers a dedicated official archive BGProcessingTask', () {
    final bridgeFile = File('ios/Runner/OfficialArchiveBackgroundTask.swift');
    expect(bridgeFile.existsSync(), isTrue);
    if (!bridgeFile.existsSync()) return;

    final bridge = bridgeFile.readAsStringSync();
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final info = File('ios/Runner/Info.plist').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    for (final required in const <String>[
      'com.kyle.PocketWorld.official.archive',
      'BGProcessingTaskRequest',
      'requiresExternalPower = false',
      'requiresNetworkConnectivity = false',
      'task.expirationHandler',
      'runColdArchive',
      'cancelColdArchive',
      'setTaskCompleted',
      'work_remaining',
    ]) {
      expect(bridge, contains(required), reason: required);
    }
    expect(delegate, contains('OfficialArchiveBackgroundTask.shared.register'));
    expect(
      delegate.indexOf('OfficialArchiveBackgroundTask.shared.register'),
      lessThan(delegate.indexOf('return super.application')),
    );
    expect(
      info,
      contains('<string>com.kyle.PocketWorld.official.archive</string>'),
    );
    expect(info, contains('official-archive-bgprocessing-v1'));
    expect(project, contains('OfficialArchiveBackgroundTask.swift in Sources'));
    expect(project, contains('path = OfficialArchiveBackgroundTask.swift;'));
  });

  test(
    'native bridge waits for Dart readiness and reschedules remaining work',
    () {
      final bridgeFile = File('ios/Runner/OfficialArchiveBackgroundTask.swift');
      expect(bridgeFile.existsSync(), isTrue);
      if (!bridgeFile.existsSync()) return;
      final bridge = bridgeFile.readAsStringSync();

      expect(bridge, contains('case "ready"'));
      expect(bridge, contains('case "schedule"'));
      expect(bridge, contains('case "cancelScheduled"'));
      expect(bridge, contains('pendingTask'));
      expect(bridge, contains('dartReady'));
      expect(bridge, contains('scheduleIfNeeded()'));
    },
  );
}
