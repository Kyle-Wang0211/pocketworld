import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final repo = Directory.current;

  String read(String relativePath) =>
      File('${repo.path}/$relativePath').readAsStringSync();

  Iterable<File> dartFiles(String relativePath) =>
      Directory('${repo.path}/$relativePath')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));

  test(
    'official capture tree is a physical Dart copy with no self imports',
    () {
      for (final path in <String>[
        'lib/official_capture',
        'lib/official_dome',
        'lib/official_quality',
        'lib/official_util',
        'lib/ui/official_capture',
      ]) {
        expect(
          Directory('${repo.path}/$path').existsSync(),
          isTrue,
          reason: path,
        );
      }

      final sources = <String>[
        ...dartFiles(
          'lib/official_capture',
        ).map((file) => file.readAsStringSync()),
        ...dartFiles(
          'lib/official_dome',
        ).map((file) => file.readAsStringSync()),
        ...dartFiles(
          'lib/official_quality',
        ).map((file) => file.readAsStringSync()),
        ...dartFiles(
          'lib/official_util',
        ).map((file) => file.readAsStringSync()),
        ...dartFiles(
          'lib/ui/official_capture',
        ).map((file) => file.readAsStringSync()),
      ].join('\n');

      expect(sources, isNot(contains("import '../capture/")));
      expect(sources, isNot(contains("import '../../capture/")));
      expect(sources, isNot(contains("import '../dome/")));
      expect(sources, isNot(contains("import '../../dome/")));
      expect(sources, isNot(contains("import '../aether_sfm_ffi.dart'")));
      expect(sources, isNot(contains("import '../quality/")));
      expect(sources, isNot(contains("import '../../quality/")));
      expect(sources, isNot(contains("import '../util/device_log.dart'")));
      expect(sources, isNot(contains("import '../../util/device_log.dart'")));
      expect(sources, isNot(contains("import '../aether_ffi.dart'")));
      expect(sources, isNot(contains('package:aether_capture_services/')));
    },
  );

  test(
    'official capture has isolated channels, storage, and service package',
    () {
      final provider = read('lib/official_dome/platform_pose_provider.dart');
      expect(provider, contains("MethodChannel('pocketworld_official_arkit')"));
      expect(provider, contains("'pocketworld_official_arkit/pose_stream'"));
      expect(provider, isNot(contains('MockARPoseProvider')));
      expect(provider, contains('Future<void> ensureStarted()'));

      final page = read('lib/ui/official_capture/ar_capture_page.dart');
      expect(page, contains('class OfficialARCapturePage'));
      expect(page, contains("MethodChannel('pocketworld_official_arkit')"));
      expect(page, contains("viewType: 'pocketworld_official_arkit_preview'"));
      expect(page, contains('official_sfm_live.db'));

      final session = read('lib/official_capture/capture_session.dart');
      expect(
        session,
        contains(
          "package:official_capture_services/official_capture_services.dart",
        ),
      );
      expect(session, contains('/captures_official/'));

      final sparsePly = read('lib/official_capture/sparse_ply.dart');
      expect(sparsePly, contains('official_sfm_sparse.ply'));
      expect(sparsePly, contains('official_sfm_sparse_meta.json'));
      expect(session, contains('official_photo_bundle.json'));

      final deviceLog = read('lib/official_util/device_log.dart');
      expect(deviceLog, contains('official_pw_device_log.txt'));
      expect(deviceLog, isNot(contains("'/pw_device_log.txt'")));

      final telemetry = read('lib/official_capture/telemetry_writer.dart');
      expect(telemetry, contains('telemetry_official_dart.jsonl'));

      final manifest = read(
        'packages/official_capture_services/lib/src/'
        'photo_bundle_manifest_service.dart',
      );
      expect(manifest, contains("'pipeline_kind': 'official'"));

      expect(page, contains('pipelineKind: CapturePipelineKind.official'));
      expect(
        page,
        contains(
          'activeReconstructionPipelineKind: CapturePipelineKind.official',
        ),
      );
      expect(page, contains('officialResumeRoute:'));
      expect(page, contains('officialViewerRoute:'));

      final root = read('lib/ui/me_root_page.dart');
      expect(root, contains('officialResumeRoute: _pushOfficialResumeRoute'));
      expect(root, contains('officialViewerRoute: _pushOfficialViewerRoute'));
    },
  );

  test('both capture pages expose explicit route markers', () {
    expect(
      read('lib/ui/capture/ar_capture_page.dart'),
      contains("ValueKey<String>('capture-route-badge-self')"),
    );
    expect(
      read('lib/ui/official_capture/ar_capture_page.dart'),
      contains("ValueKey<String>('capture-route-badge-official')"),
    );
  });

  test('official FFI binds only the official ABI and fails closed', () {
    final ffi = read('lib/official_aether_sfm_ffi.dart');
    expect(ffi, contains('pwofficial_create'));
    expect(ffi, contains('pwofficial_finalize_async'));
    expect(ffi, isNot(contains('pwsfm_')));

    final live = read('lib/official_capture/sfm_live_recon.dart');
    expect(live, contains("import '../official_aether_sfm_ffi.dart'"));

    final resolver = read('lib/official_aether_ffi.dart');
    expect(resolver, contains('PWOfficialSfm.framework/PWOfficialSfm'));
    expect(resolver, contains("'pwofficial_options_default'"));
    expect(resolver, isNot(contains('DynamicLibrary.process()')));
    expect(resolver, isNot(contains('libaether3d_ffi')));

    final telemetry = read('lib/official_capture/pw_telemetry.dart');
    expect(telemetry, contains("import '../official_aether_ffi.dart'"));
    expect(telemetry, contains("'pwofficial_telemetry'"));
  });
}
