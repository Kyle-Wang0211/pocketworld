import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_finish_coordinator.dart';

void main() {
  testWidgets(
    'committed Finish hides capture synchronously and blocks system pop',
    (tester) async {
      final key = GlobalKey<_FinishRouteHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const ValueKey<String>('open-capture'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => _FinishRouteHarness(key: key),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open-capture')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('capture-surface')), findsOne);

      key.currentState!.commitFinish();
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('capture-surface')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('opaque-processing')), findsOne);
      expect(key.currentState!.coordinator.captureRootTombstoned, isTrue);
      expect(key.currentState!.coordinator.captureAdmissionOpen, isFalse);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('opaque-processing')), findsOne);

      key.currentState!.completeAndExit();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('open-capture')), findsOne);
      expect(
        find.byKey(const ValueKey<String>('capture-surface')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'drain failure keeps the route opaque, tears down, and never restores capture',
    (tester) async {
      final key = GlobalKey<_FinishRouteHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  key: const ValueKey<String>('open-capture'),
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => _FinishRouteHarness(key: key),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open-capture')));
      await tester.pumpAndSettle();

      await key.currentState!.failDrainAndCleanup();
      await tester.pump();

      expect(key.currentState!.coordinator.phase, CaptureFinishPhase.error);
      expect(key.currentState!.cameraStopCalls, 1);
      expect(key.currentState!.sessionCleanupCalls, 1);
      expect(
        find.byKey(const ValueKey<String>('capture-surface')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey<String>('opaque-processing')), findsOne);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('open-capture')), findsOne);
      expect(
        find.byKey(const ValueKey<String>('capture-surface')),
        findsNothing,
      );
    },
  );
}

class _FinishRouteHarness extends StatefulWidget {
  const _FinishRouteHarness({super.key});

  @override
  State<_FinishRouteHarness> createState() => _FinishRouteHarnessState();
}

class _FinishRouteHarnessState extends State<_FinishRouteHarness> {
  late final CaptureFinishCoordinator coordinator = CaptureFinishCoordinator(
    stageTimeout: const Duration(seconds: 1),
    onStateChanged: (_) {
      if (mounted) setState(() {});
    },
  );
  CaptureFinishAttempt? _attempt;
  int cameraStopCalls = 0;
  int sessionCleanupCalls = 0;

  void commitFinish() {
    _attempt = coordinator.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    );
  }

  void completeAndExit() {
    final attempt = _attempt!;
    coordinator.completeError(
      attempt,
      stage: 'processing_test_terminal',
      error: StateError('typed processing terminal'),
    );
    expect(coordinator.beginExit(attempt), isTrue);
    Navigator.of(context).pop();
    coordinator.markExited(attempt);
  }

  Future<void> failDrainAndCleanup() async {
    final attempt = coordinator.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    )!;
    _attempt = attempt;
    expect(
      await coordinator.orchestrateToProcessing(
        attempt: attempt,
        drainActiveTicket: () async => throw StateError('drain failed'),
        stopCamera: () async {
          cameraStopCalls++;
        },
        beginProcessing: () async {
          sessionCleanupCalls++;
        },
      ),
      isFalse,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<void>(
      canPop: coordinator.canPop,
      child: ColoredBox(
        color: Colors.black,
        child: coordinator.shouldShowOpaqueOverlay
            ? const SizedBox.expand(key: ValueKey<String>('opaque-processing'))
            : const SizedBox.expand(key: ValueKey<String>('capture-surface')),
      ),
    );
  }
}
