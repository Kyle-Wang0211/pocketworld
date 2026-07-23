import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every product capture entry opens the official route directly', () {
    final rootPage = File('lib/ui/me_root_page.dart').readAsStringSync();
    final appShell = File('lib/ui/app_shell.dart').readAsStringSync();

    expect(
      rootPage,
      contains("import 'official_capture/ar_capture_page.dart';"),
    );
    expect(rootPage, isNot(contains("import 'capture/ar_capture_page.dart';")));
    expect(rootPage, isNot(contains('capture_pipeline_chooser.dart')));
    expect(rootPage, isNot(contains('CaptureRouteChoice')));
    expect(rootPage, isNot(contains('CapturePipelineChooser')));
    expect(
      rootPage,
      isNot(contains('showModalBottomSheet<CaptureRouteChoice>')),
    );
    expect(rootPage, contains('builder: (_) => const OfficialARCapturePage()'));

    expect(
      appShell,
      contains("import 'official_capture/ar_capture_page.dart';"),
    );
    expect(appShell, isNot(contains("import 'capture/ar_capture_page.dart';")));
    expect(appShell, contains('builder: (_) => const OfficialARCapturePage()'));

    expect(File('lib/ui/capture_pipeline_chooser.dart').existsSync(), isFalse);
  });

  test('iOS registers and builds only the official capture runtime', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();
    final infoPlist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(delegate, contains('OfficialAetherARKitPlugin.register'));
    expect(delegate, contains('OfficialReconUmbrella.shared.register()'));
    expect(
      delegate,
      isNot(contains('        AetherARKitPlugin.register(with: registrar)')),
    );
    expect(delegate, isNot(contains('      ReconUmbrella.shared.register()')));

    expect(project, isNot(contains('/* AetherARKitPlugin.swift */')));
    expect(project, isNot(contains('/* ReconUmbrella.swift */')));
    expect(File('ios/Runner/AetherARKitPlugin.swift').existsSync(), isFalse);
    expect(File('ios/Runner/ReconUmbrella.swift').existsSync(), isFalse);

    expect(infoPlist, isNot(contains('com.kyle.PocketWorld.recon')));
    expect(infoPlist, contains('com.kyle.PocketWorld.official.recon'));
  });

  test(
    'self capture telemetry is not started, while legacy records remain',
    () {
      final mainSource = File('lib/main.dart').readAsStringSync();
      final scanRecord = File('lib/ui/scan_record.dart').readAsStringSync();
      final recordStore = File(
        'lib/me/scan_record_store.dart',
      ).readAsStringSync();

      expect(
        mainSource,
        isNot(contains("import 'capture/telemetry_writer.dart';")),
      );
      expect(
        mainSource,
        isNot(contains("'\${dir.path}/telemetry_dart.jsonl'")),
      );
      expect(
        mainSource,
        contains("'\${dir.path}/telemetry_official_dart.jsonl'"),
      );

      // Existing on-device self-route records are data compatibility, not a
      // selectable production capture route. Keep them discoverable/readable.
      expect(
        scanRecord,
        contains('enum CapturePipelineKind { self, official }'),
      );
      expect(
        recordStore,
        contains(
          "(Directory('\${root.path}/captures'), CapturePipelineKind.self)",
        ),
      );
    },
  );
}
