import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/sfm_preview_overlay.dart';

void main() {
  Widget subject({
    required SfmPreviewPhase phase,
    VoidCallback? onBack,
    required VoidCallback onDone,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            SfmPreviewOverlay(
              phase: phase,
              snapshot: null,
              progressText: '已处理 12 帧 · 剩余 8 帧',
              onBack: onBack ?? () {},
              onDone: onDone,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('generating state shows queue and cannot exit', (tester) async {
    var done = false;
    await tester.pumpWidget(
      subject(phase: SfmPreviewPhase.generating, onDone: () => done = true),
    );

    expect(find.text('正在生成最终点云…'), findsOneWidget);
    expect(find.text('已处理 12 帧 · 剩余 8 帧'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    expect(done, isFalse);
  });

  testWidgets('back action is available while reconstruction keeps running', (
    tester,
  ) async {
    var backed = false;
    await tester.pumpWidget(
      subject(
        phase: SfmPreviewPhase.generating,
        onBack: () => backed = true,
        onDone: () {},
      ),
    );

    await tester.tap(find.byKey(const ValueKey('sfm_preview_back')));
    expect(backed, isTrue);
    expect(find.text('完成'), findsNothing);
  });

  testWidgets('completion action appears only for a terminal result', (
    tester,
  ) async {
    var done = false;
    await tester.pumpWidget(
      subject(phase: SfmPreviewPhase.refined, onDone: () => done = true),
    );

    expect(find.text('完成'), findsOneWidget);
    await tester.tap(find.text('完成'));
    expect(done, isTrue);
  });
}
