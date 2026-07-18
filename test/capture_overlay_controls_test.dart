import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/capture_overlay_controls.dart';

Widget harness(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

void main() {
  testWidgets('capsule is 176 by 52 with two default-on semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        CaptureOverlayControls(
          photoCardsVisible: true,
          coveragePointsVisible: true,
          onPhotoCardsChanged: (_) {},
          onCoveragePointsChanged: (_) {},
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(CaptureOverlayControls.panelKey)),
      const Size(176, 52),
    );

    final panel = tester.widget<Container>(
      find.byKey(CaptureOverlayControls.panelKey),
    );
    final decoration = panel.decoration! as BoxDecoration;
    expect(decoration.color, captureGlassTint);
    expect(decoration.borderRadius, BorderRadius.circular(20));

    final photo = tester.getSemantics(
      find.byKey(CaptureOverlayControls.photoKey),
    );
    final points = tester.getSemantics(
      find.byKey(CaptureOverlayControls.pointsKey),
    );
    expect(photo.label, '显示照片卡片');
    expect(photo.flagsCollection.isButton, isTrue);
    expect(photo.flagsCollection.isToggled, Tristate.isTrue);
    expect(points.label, '显示覆盖点');
    expect(points.flagsCollection.isButton, isTrue);
    expect(points.flagsCollection.isToggled, Tristate.isTrue);

    final photoIcon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(CaptureOverlayControls.photoKey),
        matching: find.byIcon(Icons.photo_outlined),
      ),
    );
    expect(photoIcon.size, 27);
    expect(photoIcon.color, captureGlassActive);

    final activeDots = find.descendant(
      of: find.byKey(CaptureOverlayControls.pointsKey),
      matching: find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.shape == BoxShape.circle &&
            decoration.color == captureGlassActive;
      }),
    );
    expect(activeDots, findsNWidgets(9));
  });

  testWidgets('photo and coverage controls toggle independently', (
    tester,
  ) async {
    var photo = true;
    var points = true;
    await tester.pumpWidget(
      harness(
        StatefulBuilder(
          builder: (context, setState) => CaptureOverlayControls(
            photoCardsVisible: photo,
            coveragePointsVisible: points,
            onPhotoCardsChanged: (value) {
              setState(() => photo = value);
            },
            onCoveragePointsChanged: (value) {
              setState(() => points = value);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(CaptureOverlayControls.photoKey));
    await tester.pump();
    expect(photo, isFalse);
    expect(points, isTrue);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.photo_outlined)).color,
      captureGlassInactive,
    );

    await tester.tap(find.byKey(CaptureOverlayControls.pointsKey));
    await tester.pump();
    expect(photo, isFalse);
    expect(points, isFalse);

    final inactiveDots = find.descendant(
      of: find.byKey(CaptureOverlayControls.pointsKey),
      matching: find.byWidgetPredicate((widget) {
        if (widget is! DecoratedBox) return false;
        final decoration = widget.decoration;
        return decoration is BoxDecoration &&
            decoration.shape == BoxShape.circle &&
            decoration.color == captureGlassInactive;
      }),
    );
    expect(inactiveDots, findsNWidgets(9));
  });

  testWidgets('each half is an opaque 88 by 52 point target', (tester) async {
    await tester.pumpWidget(
      harness(
        CaptureOverlayControls(
          photoCardsVisible: true,
          coveragePointsVisible: true,
          onPhotoCardsChanged: (_) {},
          onCoveragePointsChanged: (_) {},
        ),
      ),
    );

    for (final key in [
      CaptureOverlayControls.photoKey,
      CaptureOverlayControls.pointsKey,
    ]) {
      final target = find.byKey(key);
      expect(tester.getSize(target), const Size(88, 52));
      final gesture = tester.widget<GestureDetector>(
        find.descendant(of: target, matching: find.byType(GestureDetector)),
      );
      expect(gesture.behavior, HitTestBehavior.opaque);
    }
  });

  testWidgets('rect reporter suppresses unchanged layout', (tester) async {
    final rects = <Rect>[];
    await tester.pumpWidget(
      harness(
        CaptureGlassRectReporter(
          onRectChanged: rects.add,
          child: const SizedBox(width: 176, height: 52),
        ),
      ),
    );
    await tester.pump();
    expect(rects, hasLength(1));

    await tester.pump();
    expect(rects, hasLength(1));
  });

  testWidgets('rect reporter reports an actual position change', (
    tester,
  ) async {
    final rects = <Rect>[];
    var left = 12.0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Stack(
                children: [
                  Positioned(
                    left: left,
                    top: 24,
                    child: CaptureGlassRectReporter(
                      onRectChanged: rects.add,
                      child: const SizedBox(width: 176, height: 52),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(rects, [const Rect.fromLTWH(12, 24, 176, 52)]);

    update(() => left = 48);
    await tester.pump();
    expect(rects, [
      const Rect.fromLTWH(12, 24, 176, 52),
      const Rect.fromLTWH(48, 24, 176, 52),
    ]);
  });
}
