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
    // [重写 2026-08-22 用户签决] 原断言要求 live_repay 在 endpoint gate 内
    // **无条件** return PrepayQuadraticTick —— 该形态已于 [IDLE-PREPAY 2026-08-07]
    // 与 [STARVED-ALWAYS 2026-08-14 用户签] 变更,长期红。
    //
    // ⚠️ 出货真相(不要再写成"quadratic 优先"这种在出货 env 下不成立的话):
    // 插件里 QUADRATIC_PREPAY=0 + QUADRATIC_OVERLAP=0 ⇒ PrepayQuadraticTick 的
    // consumed **恒为 0** ⇒ 空闲通道在真机上 100% 落到自研
    // LiveRepayStarvedWindowTick,并默认当场长云(GrowLiveTracksFromTvgInliers
    // 就地写 live_recon,finalize 版本没有这条腿)。
    //
    // 因此这里改钉**行为**而非注释文本:先试官方 quadratic 的次序仍在,三道
    // 回滚闸都在场,且改写 live_recon 的入口恰好三处。注释 grep 零约束力
    // (删光 gate 只留注释照样绿),一律不用。
    expect(
      source,
      contains('int aether_sfm_live_repay(aether_sfm_session_t* s, int max_pairs) {'),
    );
    // 次序:官方 quadratic 仍然先试,有产出就直接返回,不落到自研腿。
    expect(
      source,
      contains(
        'const int consumed = PrepayQuadraticTick(s, max_pairs);\n'
        '    if (consumed > 0) return consumed;',
      ),
    );
    // 一号闸:IDLE-PREPAY 可整条关掉,且默认 ON 的语义不许改成"必须显式开"。
    expect(source, contains('if (!IdlePrepayEnabled()) return 0;'));
    expect(source, contains('std::getenv("OFFICIAL_AETHER_IDLE_PREPAY")'));
    // 二号闸:STARVED-ALWAYS 可回滚,且热档仍能叫停。
    expect(source, contains('std::getenv("OFFICIAL_AETHER_STARVED_ALWAYS")'));
    expect(source, contains('std::getenv("OFFICIAL_AETHER_STARVED_THERMAL_STOP")'));
    // 三号闸:当场长云可回滚;merge / obs 两条腿必须保持默认关
    // (cap201 实测 merge 开启交付点 −1.54%)。
    expect(source, contains('std::getenv("OFFICIAL_AETHER_PROBE_DEBT_GROW_LIVE")'));
    expect(source, contains('std::getenv("OFFICIAL_AETHER_PROBE_DEBT_GROW_MERGE")'));
    expect(source, contains('std::getenv("OFFICIAL_AETHER_PROBE_DEBT_GROW_OBS")'));
    // 交付面:改写 live_recon 的入口 = 1 处定义 + 3 处调用。多出第四处 ⇒ 红。
    expect(
      RegExp(r'GrowLiveTracksFromTvgInliers\(\n').allMatches(source).length,
      4,
      reason: '当场长云的入口数变化必须显式过审(1 定义 + 3 调用)',
    );
    // 出货插件确实关掉了官方 quadratic 预付 —— 这是上面那段"真相"的机器可见版本。
    final plugin = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    expect(
      plugin,
      contains('setenv("OFFICIAL_AETHER_QUADRATIC_PREPAY", "0", 0)'),
    );
    expect(
      plugin,
      contains('setenv("OFFICIAL_AETHER_QUADRATIC_OVERLAP", "0", 0)'),
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
