// 再进入相册项目时,中央那行字必须说"载入",不能说"生成"。
//
// 🔴 [2026-09-22 用户实机指认] 点未命名(12) 的卡片,几十秒一直显示
// "正在生成最终点云…" —— 而那朵稠密点云 09-15 21:13 就已经落盘
// (official_dense.ply,692 万点 / 99 MB;日志 `end rc=0 ... points=6922990`)。
// 什么都没在生成,只是在读盘 + 跑八叉树排序。ar_capture_page 那行注释
// 自己都写着 `cover page while the PLY loads`。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';

void _noop() {}

void main() {
  testWidgets('阳性对照:不给标签时仍是"正在生成最终点云…"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: Locale('zh'),
        home: Stack(
          children: [
            SfmPreviewOverlay(
              phase: SfmPreviewPhase.generating,
              snapshot: null,
              onBack: _noop,
              onDone: _noop,
            ),
          ],
        ),
      ),
    );
    expect(find.text('正在生成最终点云…'), findsOneWidget);
  });

  testWidgets('🔴 给了标签就用调用方那句,不许再说"生成"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: Locale('zh'),
        home: Stack(
          children: [
            SfmPreviewOverlay(
              phase: SfmPreviewPhase.generating,
              snapshot: null,
              onBack: _noop,
              onDone: _noop,
              generatingLabel: '正在载入点云…',
            ),
          ],
        ),
      ),
    );
    expect(find.text('正在载入点云…'), findsOneWidget);
    expect(find.text('正在生成最终点云…'), findsNothing);
  });

  test('🔴 再进入那条路必须把标签设成"载入"(源码契约)', () {
    final src = File('lib/ui/official_capture/ar_capture_page.dart')
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .toList();
    final at = src.indexWhere(
      (l) => l.contains('unawaited(_enterReviewMode(review))'),
    );
    expect(at, greaterThanOrEqualTo(0), reason: '再进入的入口改名了 —— 先修锚');
    final window = src.sublist((at - 6).clamp(0, src.length), at).join('\n');
    expect(
      window.contains("_sfmCenterLabel = '正在载入点云…'"),
      isTrue,
      reason: '进 review 前必须把中央文案改成"载入",否则用户又要对着一句假话等几十秒',
    );
    expect(
      src.any((l) => l.contains('generatingLabel: _sfmCenterLabel')),
      isTrue,
      reason: '标签得真的传进浮层 —— 设了不传等于没设',
    );
  });
}
