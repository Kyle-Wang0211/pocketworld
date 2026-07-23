import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture_pipeline_chooser.dart';

void main() {
  testWidgets('chooser exposes two clearly-labelled independent routes', (
    tester,
  ) async {
    CaptureRouteChoice? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CapturePipelineChooser(
            onSelected: (choice) => selected = choice,
          ),
        ),
      ),
    );

    expect(find.text('选择拍摄路线'), findsOneWidget);
    expect(find.text('自研'), findsOneWidget);
    expect(find.text('当前产品基线'), findsOneWidget);
    expect(find.text('官方'), findsOneWidget);
    expect(find.text('官方对齐路线'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('capture-route-official')));
    expect(selected, CaptureRouteChoice.official);
  });
}
