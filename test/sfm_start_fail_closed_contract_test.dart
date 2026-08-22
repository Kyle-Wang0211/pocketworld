import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const routes = <String, String>{
    'official': 'lib/ui/official_capture/ar_capture_page.dart',
  };

  for (final entry in routes.entries) {
    test('${entry.key} capture fails closed when live SfM cannot start', () {
      final source = File(entry.value).readAsStringSync();

      // [2026-08-22] 下面三条断言曾自 a3d4496(08-06)起红了 16 天。
      // **不是性质丢失** —— 三处守卫都被加强成了当前语义的超集,只是逐字
      // 文本断言接不住 dart format 的换行与新增的 disjunct。改为正则,
      // 语义是"只许更严,不许放宽"。

      expect(source, contains('bool _sfmStarting = false;'));
      expect(source, contains('String? _sfmStartFailureText;'));
      expect(source, contains('bool get _sfmCaptureReady =>'));
      expect(source, contains('await _startSfmLiveRecon(session);'));
      expect(
        source,
        isNot(contains('unawaited(_startSfmLiveRecon(session));')),
      );

      // A null worker is how lease contention and native startup failures are
      // reported. Both controls and the persistence path must reject that
      // state, even if invoked programmatically rather than through the UI.
      expect(source, contains('if (recon == null) {'));
      expect(
        source,
        contains('if (session == null || !_sfmCaptureReady) return;'),
      );
      // 守卫条件只许增(更严)不许减:锚定 _onFinishTap 首句,要求
      // !_sfmCaptureReady 与 _finalizingRecording 都仍在其中。
      expect(
        source,
        matches(
          RegExp(
            r'Future<void> _onFinishTap\(\) async \{\s*'
            r'if \(!_sfmCaptureReady \|\|\s*_finalizingRecording',
          ),
        ),
      );
      expect(source, contains('ready: _sfmCaptureReady,'));
      expect(
        source,
        matches(
          RegExp(r'onFinish:\s*_sfmCaptureReady\s*&&\s*!_finalizingRecording'),
        ),
      );

      // Failure must be persistent and visible, not log-only or a transient
      // snackbar that can disappear while the broken capture remains active.
      // 只许再挂更多失败源(||),**不许**被 && 收窄成可隐藏 / 可消失的横幅。
      // 常驻可见才是这条断言真正保护的性质 —— 开放前缀 contains(
      // 'if (_sfmStartFailureText != null') 会放行 `&& !_bannerDismissed`,
      // 那正好把它保护的东西放掉(对抗复核变异测试证实)。
      expect(
        source,
        matches(RegExp(r'if \(_sfmStartFailureText != null\s*(\)|\|\|)')),
      );
      expect(source, contains("'sfm-start-failure-banner-${entry.key}'"));
      expect(source, contains('此次拍摄不会保存'));
    });
  }
}
