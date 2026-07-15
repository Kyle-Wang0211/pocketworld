import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/manual_capture_shutter_button.dart';

void main() {
  testWidgets(
    'recording shutter accepts every tap while earlier work is still pending',
    (tester) async {
      final pending = Completer<void>();
      var taps = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ManualCaptureShutterButton(
              enabled: true,
              onTap: () {
                taps++;
                unawaited(pending.future);
              },
            ),
          ),
        ),
      );

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byType(ManualCaptureShutterButton));
        await tester.pump();
      }

      expect(taps, 3);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(pending.isCompleted, isFalse);
    },
  );

  testWidgets('pre-recording shutter remains disabled without a loader', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualCaptureShutterButton(enabled: false, onTap: () => taps++),
        ),
      ),
    );

    await tester.tap(find.byType(ManualCaptureShutterButton));
    await tester.pump();

    expect(taps, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
