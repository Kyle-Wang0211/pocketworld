import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';

Widget _host(
  SfmPreviewPhase phase, {
  VoidCallback? onNext,
  VoidCallback? onDone,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          SfmPreviewOverlay(
            phase: phase,
            snapshot: null,
            onBack: () {},
            onDone: onDone ?? () {},
            onNext: onNext,
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('refined + onNext:保存草稿|下一步,无"完成"', (tester) async {
    var next = 0, done = 0;
    await tester.pumpWidget(
      _host(
        SfmPreviewPhase.refined,
        onNext: () => next++,
        onDone: () => done++,
      ),
    );
    expect(find.text('保存草稿'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    await tester.tap(find.text('下一步'));
    expect(next, 1);
    await tester.tap(find.text('保存草稿'));
    expect(done, 1);
  });

  testWidgets('error:只有"完成"', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.error, onNext: () {}));
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('generating:无底部按钮', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.generating, onNext: () {}));
    expect(find.text('完成'), findsNothing);
    expect(find.text('下一步'), findsNothing);
  });
}
