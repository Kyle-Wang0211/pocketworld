import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final nativeSource = File(
    '../Aether3D-cross/aether_cpp/official_pipeline/src/'
    'official_aether_sfm_c.cc',
  );

  test('production native pipeline stops at official BA and filtering', () {
    final source = nativeSource.readAsStringSync();

    expect(
      source,
      contains('constexpr bool kProductionOfficialEndpointOnly = true;'),
    );
    expect(
      source,
      contains(
        'void AddSpatialRevisitMatches(aether_sfm_session* s) {\n'
        '  if (kProductionOfficialEndpointOnly) return;',
      ),
    );
    expect(
      source,
      contains(
        'void RestoreTemporalDetail(aether_sfm_session* s,\n'
        '                           colmap::Reconstruction* reconstruction) {\n'
        '  if (kProductionOfficialEndpointOnly) return;',
      ),
    );
    expect(
      source,
      contains(
        'void UpgradeLowParallaxTracks(aether_sfm_session* s,\n'
        '                              colmap::Reconstruction* reconstruction) {\n'
        '  if (kProductionOfficialEndpointOnly) return;',
      ),
    );
    expect(
      source,
      contains(
        'void MergeFragmentTracks(aether_sfm_session* s,\n'
        '                         colmap::Reconstruction* reconstruction) {\n'
        '  if (kProductionOfficialEndpointOnly) return;',
      ),
    );
    expect(
      source,
      contains(
        'void FinalizeRematchStarvedFrames(aether_sfm_session* s) {\n'
        '  if (kProductionOfficialEndpointOnly) return;',
      ),
    );
    expect(
      source,
      contains(
        'int aether_sfm_live_repay(aether_sfm_session_t* s, int max_pairs) {\n'
        '  if (kProductionOfficialEndpointOnly) return 0;',
      ),
    );

    // These are COLMAP's own reconstruction operations and must stay enabled.
    expect(source, contains('CompleteAndMergeTracks'));
    expect(source, contains('Retriangulate'));
    expect(source, contains('FilterPoints'));
  });

  test('production iOS route cannot re-enable self enrichment', () {
    final swift = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    expect(swift, isNot(contains('setenv("OFFICIAL_AETHER_TRACK_UPGRADE"')));
    expect(swift, isNot(contains('setenv("OFFICIAL_AETHER_ENRICH_TARGETED"')));
    expect(swift, isNot(contains('setenv("OFFICIAL_AETHER_ENRICH_PAIR_CAP"')));
  });

  test('official Dart delivery preserves every official endpoint point', () {
    final worker = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    final liveUi = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final resume = File(
      'lib/official_capture/sfm_resume.dart',
    ).readAsStringSync();

    // The utility remains available for old tests/records, but the official
    // worker has only its declaration and no production invocation.
    expect(
      RegExp(r'filterFinalSpatialTwoViewPoints\(').allMatches(worker).length,
      1,
    );
    expect(worker, isNot(contains('.liveRepay(')));

    for (final source in [liveUi, resume]) {
      expect(
        source,
        isNot(
          contains(
            "import '../../official_capture/"
            "floater_filter.dart';",
          ),
        ),
      );
      expect(source, isNot(contains("import 'floater_filter.dart';")));
      expect(source, isNot(contains('floaterKeepIndices(')));
      expect(source, isNot(contains('compactXyzRgbByIndices(')));
    }
  });
}
