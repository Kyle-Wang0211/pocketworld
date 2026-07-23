import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/draft_capture_shell.dart';

void main() {
  testWidgets('every Drafts shell keeps the capture FAB visible and tappable', (
    tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DraftCaptureShell(
          onCaptureTap: () => taps++,
          child: const ColoredBox(
            color: Colors.white,
            child: Center(child: Text('草稿')),
          ),
        ),
      ),
    );

    expect(find.text('草稿'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('draft-capture-fab')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('draft-capture-fab')));

    expect(taps, 1);
  });

  testWidgets('reconstruction keeps FAB visible but blocks a second capture', (
    tester,
  ) async {
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: DraftCaptureShell(
          blockedMessage: '当前任务正在重建',
          onCaptureTap: () => taps++,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey<String>('draft-capture-fab')));
    await tester.pump();

    expect(find.text('当前任务正在重建'), findsOneWidget);
    expect(taps, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
