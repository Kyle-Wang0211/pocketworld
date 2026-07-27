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
    // [SIGNED 2026-07-26] FinalizeRematchStarvedFrames 解除生产 gate:它是
    // 官方语义(colmap 默认 TVG,只写 matches/two_view_geometries),且是
    // 热降档"交付无损"承诺的另一半。断言函数在且不再 endpoint 早退。
    expect(
      source,
      contains('void FinalizeRematchStarvedFrames(aether_sfm_session* s) {'),
    );
    expect(
      source,
      isNot(
        contains(
          'void FinalizeRematchStarvedFrames(aether_sfm_session* s) {\n'
          '  if (kProductionOfficialEndpointOnly) return;',
        ),
      ),
    );
    expect(source, contains('Un-gated from kProductionOfficialEndpointOnly'));
    // [SIGNED 2026-07-26 QUAD-PREPAY] live_repay 的生产路径 = 官方 quadratic
    // 预付(PrepayQuadraticTick);旧自研 starved-window repay 体仍留在
    // endpoint gate 之后。
    expect(
      source,
      contains(
        'if (kProductionOfficialEndpointOnly) {\n'
        '    return PrepayQuadraticTick(s, max_pairs);\n'
        '  }',
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
    // [SIGNED 2026-07-26 QUAD-PREPAY] worker 恰有一处 liveRepay 调用 = 官方
    // quadratic 空闲预付通道(native 生产 gate 内路由 PrepayQuadraticTick,
    // 出货插件当前 OFFICIAL_AETHER_QUADRATIC_PREPAY=0 关闭);旧自研 idle
    // repay 无生产调用。
    expect(RegExp(r'\.liveRepay\(').allMatches(worker).length, 1);
    expect(worker, contains('[QUAD-PREPAY 2026-07-26, signed]'));

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
