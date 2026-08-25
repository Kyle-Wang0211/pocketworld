import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/splash_overlay.dart';
import 'package:pocketworld_flutter/ui/splash_solving_orb.dart';

Widget _host({
  required bool visible,
  bool disableAnimations = false,
  SplashExitStyle exitStyle = SplashExitStyle.fade,
}) {
  return MaterialApp(
    localizationsDelegates: AppL10n.localizationsDelegates,
    supportedLocales: AppL10n.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: AetherSplashOverlay(
        visible: visible,
        progressMessage: 'legacy progress must not render',
        exitStyle: exitStyle,
      ),
    ),
  );
}

void main() {
  testWidgets('shows a black full-screen splash', (tester) async {
    await tester.pumpWidget(_host(visible: true));

    final background = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('splash-background')),
    );
    expect(background.color, Colors.black);
  });

  testWidgets('centers one 128pt white solving orb at speed 0.8', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(visible: true));

    final orb = tester.widget<SplashSolvingOrb>(find.byType(SplashSolvingOrb));
    expect(orb.size, 128);
    expect(orb.speed, 0.8);
    expect(orb.color, Colors.white);
    expect(
      tester.getCenter(find.byType(SplashSolvingOrb)),
      tester.getCenter(find.byKey(const ValueKey('splash-background'))),
    );
  });

  testWidgets('removes old logo text and progress UI', (tester) async {
    await tester.pumpWidget(_host(visible: true));

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('legacy progress must not render'), findsNothing);
    expect(find.text('方寸间'), findsNothing);
  });

  testWidgets('reduced motion paints the representative frozen frame', (
    tester,
  ) async {
    await tester.pumpWidget(_host(visible: true, disableAnimations: true));

    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(SplashSolvingOrb),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as SplashSolvingOrbPainter;
    expect(painter.frozenTime, SplashSolvingOrb.reducedMotionTime);
  });

  testWidgets('removes the orb after the 420ms fade', (tester) async {
    await tester.pumpWidget(_host(visible: true));
    await tester.pumpWidget(_host(visible: false));
    // Pump one millisecond beyond the 420ms controller endpoint so the test
    // binding also delivers the terminal AnimationStatus frame.
    await tester.pump(const Duration(milliseconds: 421));
    await tester.pump();

    expect(find.byType(SplashSolvingOrb), findsNothing);
  });

  testWidgets('restores dark status bar icons after the splash fades', (
    tester,
  ) async {
    final iconBrightnesses = <String?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemChrome.setSystemUIOverlayStyle') {
            final arguments = Map<Object?, Object?>.from(call.arguments as Map);
            iconBrightnesses.add(
              arguments['statusBarIconBrightness'] as String?,
            );
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.pumpWidget(_host(visible: true));
    await tester.pump();
    await tester.pumpWidget(_host(visible: false));
    await tester.pump(const Duration(milliseconds: 421));
    await tester.pump();

    expect(iconBrightnesses, contains('Brightness.light'));
    expect(iconBrightnesses.last, 'Brightness.dark');
  });

  testWidgets('direct-line reveal uses 500ms line, 110ms hold, 680ms doors', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(visible: true, exitStyle: SplashExitStyle.directLineDoor),
    );
    await tester.pumpWidget(
      _host(visible: false, exitStyle: SplashExitStyle.directLineDoor),
    );

    expect(find.byType(SplashDirectLineField), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    var field = tester.widget<SplashDirectLineField>(
      find.byType(SplashDirectLineField),
    );
    expect(field.morphProgress, closeTo(1, 1e-6));
    var doorPaint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('splash-door-painter')),
    );
    var doorPainter = doorPaint.painter! as SplashDoorPainter;
    expect(doorPainter.openProgress, 0);

    await tester.pump(const Duration(milliseconds: 110));
    doorPaint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('splash-door-painter')),
    );
    doorPainter = doorPaint.painter! as SplashDoorPainter;
    expect(doorPainter.openProgress, 0);

    await tester.pump(const Duration(milliseconds: 340));
    doorPaint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('splash-door-painter')),
    );
    doorPainter = doorPaint.painter! as SplashDoorPainter;
    expect(doorPainter.openProgress, closeTo(0.5, 0.03));

    await tester.pump(const Duration(milliseconds: 341));
    await tester.pump();
    expect(find.byType(SplashDirectLineField), findsNothing);
    expect(find.byKey(const ValueKey('splash-background')), findsNothing);
  });

  testWidgets('door seam is two physical pixels split one per black door', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(visible: true, exitStyle: SplashExitStyle.directLineDoor),
    );
    await tester.pumpWidget(
      _host(visible: false, exitStyle: SplashExitStyle.directLineDoor),
    );
    await tester.pump(const Duration(milliseconds: 610));

    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('splash-door-painter')),
    );
    final painter = paint.painter! as SplashDoorPainter;
    final geometry = painter.geometryFor(const Size(393, 852));
    expect(geometry.leftSeam.width, closeTo(1 / 3, 1e-9));
    expect(geometry.rightSeam.width, closeTo(1 / 3, 1e-9));
    expect(
      geometry.leftSeam.width + geometry.rightSeam.width,
      closeTo(2 / 3, 1e-9),
    );
    expect(geometry.leftPanel.right, lessThanOrEqualTo(393 / 2));
    expect(geometry.rightPanel.left, greaterThanOrEqualTo(393 / 2));
  });

  testWidgets('reduced motion skips direct-line and door movement', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        visible: true,
        disableAnimations: true,
        exitStyle: SplashExitStyle.directLineDoor,
      ),
    );
    await tester.pumpWidget(
      _host(
        visible: false,
        disableAnimations: true,
        exitStyle: SplashExitStyle.directLineDoor,
      ),
    );
    await tester.pump();

    expect(find.byType(SplashDirectLineField), findsNothing);
    expect(find.byKey(const ValueKey('splash-background')), findsNothing);
  });

  test('only the final HomeScreen overlay opts into the door reveal', () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
      RegExp(
        r'exitStyle:\s*SplashExitStyle\.directLineDoor',
      ).allMatches(source).length,
      1,
    );
  });
}
