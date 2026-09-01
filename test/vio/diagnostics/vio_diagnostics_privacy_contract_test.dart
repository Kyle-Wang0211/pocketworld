import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String source = File(
    'lib/vio/diagnostics/vio_diagnostics_recorder.dart',
  ).readAsStringSync();
  final String mainSource = File('lib/main.dart').readAsStringSync();
  final String captureSource = File(
    'lib/ui/official_capture/ar_capture_page.dart',
  ).readAsStringSync();
  final String finishCoordinatorSource = File(
    'lib/official_capture/capture_finish_coordinator.dart',
  ).readAsStringSync();

  test('recorder persists only the privacy-safe shadow summary', () {
    expect(source, contains("import 'vio_shadow_health.dart';"));
    expect(source, contains("import 'vio_shadow_se3_comparison.dart';"));
    expect(source, contains('_shadowComparison.consumeSnapshot(sm)'));
    expect(source, contains('VioShadowHealthSummary.fromWire('));
    expect(source, contains("'shadowHealth': _shadowHealth?.toJson()"));
    expect(source, isNot(contains("'slamFeed': _slam")));
    expect(source, isNot(contains("'comparisonPairs':")));
    expect(source, isNot(contains("'poseObservations':")));
  });

  test('legacy pushed keys are replaced by accepted wire counters', () {
    expect(source, contains("gi('imagesAccepted')"));
    expect(source, contains("gi('accAccepted')"));
    expect(source, isNot(contains("gi('imagesPushed')")));
    expect(source, isNot(contains("gi('accPushed')")));
  });

  test('recorder stop calls slamStop and resets restart guards', () {
    expect(source, contains('_pollGate.closeAndDrain(),'));
    expect(source, contains('_timebase.slamStop(),'));
    final RegExpMatch? stopBody = RegExp(
      r'Future<void> _stopSerialized\(\) async \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(stopBody, isNotNull);
    expect(stopBody!.group(1), isNot(contains('slamSnapshot()')));
    expect(
      stopBody.group(1)!.indexOf('_timebase.slamStop()'),
      lessThan(stopBody.group(1)!.indexOf('_timebase.snapshot()')),
      reason: 'the final clock receipt must be sampled after native shutdown',
    );
    expect(
      source,
      contains('_consumeShadowSnapshot(terminal, requireTerminal: true)'),
    );
    expect(source, contains("sm['state'] == 'stopped'"));
    expect(source, contains("gi('queueBacklog') == 0"));
    expect(source, contains("gi('queueInFlight') == 0"));
    expect(source, contains('raw is List'));
    expect(
      source,
      isNot(contains('raw.isEmpty')),
      reason:
          'slamStop intentionally delivers the final unpolled pose observations in its one terminal receipt',
    );
    expect(source, contains('generation == _trustedRunningGeneration'));
    expect(source, contains('_terminalReceiptConsumed = true'));
    expect(source, contains('_clearTransientShadowAccumulators()'));
    expect(source, contains('_feedStarted = false;'));
    expect(source, contains('_lifecycleUpgraded = false;'));
  });

  test(
    'polling is single-flight generation guarded and cannot overwrite stop',
    () {
      expect(source, contains('class VioDiagnosticPollGate'));
      expect(source, contains('final VioDiagnosticPollGate _pollGate'));
      expect(source, contains('_pollGate.run('));
      expect(source, contains('_pollGate.isCurrent(token)'));
      expect(source, contains('_pollGate.closeAndDrain(),'));
      expect(source, contains('_terminalReceiptGeneration'));
    },
  );

  test('only the direct slamStart receipt can pin the shadow generation', () {
    expect(source, contains('final IosShadowStartReceipt startReceipt'));
    expect(
      source,
      contains('_trustedRunningGeneration = startReceipt.generation'),
    );
    expect(source, contains('_consumeShadowSnapshot(startReceipt.snapshot!'));
    expect(source, isNot(contains('trustedRunningSnapshot')));
    expect(source, isNot(contains('_trustedRunningGeneration = generation')));
  });

  test('XRSLAM core start is fail-closed behind the Dart timebase receipt', () {
    final RegExpMatch? tickBody = RegExp(
      r'Future<void> _tickForGeneration\(int token\) async \{([\s\S]*?)\n  void _consumeShadowSnapshot',
    ).firstMatch(source);
    expect(tickBody, isNotNull);
    final String body = tickBody!.group(1)!;
    final int gate = body.indexOf('_timebaseEvidence.preStartDomainAccepted');
    final int materialize = body.indexOf(
      'XrslamRuntimeConfigFiles.materialize',
    );
    final int start = body.indexOf('.slamStart(');
    expect(gate, greaterThanOrEqualTo(0));
    expect(gate, lessThan(materialize));
    expect(gate, lessThan(start));
    expect(
      body,
      contains("_noteStartGate('timebase-not-accepted')"),
      reason: 'a rejected pre-start gate needs a bounded diagnostic receipt',
    );
    expect(
      body.indexOf('_lifecycleUpgraded = true;'),
      greaterThan(body.indexOf('final bool trustedStart =')),
      reason:
          'missing timebase evidence must remain retryable on the next tick',
    );
  });

  test(
    'recorder never bypasses the native serial core queue with direct FFI lifecycle',
    () {
      expect(source, isNot(contains("import '../ffi/xrslam_smoke.dart';")));
      expect(source, isNot(contains('runXrslamLifecycle(')));
    },
  );

  test('capture finish and dispose preserve the terminal lifecycle tail', () {
    expect(
      mainSource,
      isNot(contains('VioDiagnosticsRecorder.instance.start()')),
    );
    expect(captureSource, contains('_startVioShadowForCapture()'));
    final RegExpMatch? shadowStop = RegExp(
      r'Future<void> _stopVioShadowForCapture\(\) async \{([\s\S]*?)\n  \}',
    ).firstMatch(captureSource);
    expect(shadowStop, isNotNull);
    expect(
      shadowStop!.group(1),
      contains('await VioDiagnosticsRecorder.instance.stop()'),
      reason: 'Finish must await the recorder path that validates slamStop',
    );

    expect(
      source,
      contains(
        'Future<void> start() async {\n'
        '    await _enqueueLifecycle(_startSerialized);\n'
        '  }',
      ),
    );
    expect(
      source,
      contains(
        'void stopInBackground() {\n'
        '    unawaited(\n'
        '      _enqueueLifecycle(_stopSerialized)',
      ),
      reason: 'dispose may return while stop remains on the owned tail',
    );
    final RegExpMatch? lifecycleQueue = RegExp(
      r'Future<void> _enqueueLifecycle\(Future<void> Function\(\) operation\) \{([\s\S]*?)\n  \}',
    ).firstMatch(source);
    expect(lifecycleQueue, isNotNull);
    expect(
      lifecycleQueue!.group(1),
      contains('final Future<void> scheduled = _lifecycleTail.then<void>('),
    );
    expect(
      lifecycleQueue.group(1),
      contains('_lifecycleTail = scheduled.then<void>('),
      reason: 'the next capture start must queue behind terminal cleanup',
    );

    final int disposeStart = captureSource.indexOf(
      '@override\n  void dispose() {',
    );
    final int disposeEnd = captureSource.indexOf(
      '\n  @override\n  Widget build(',
      disposeStart + 1,
    );
    expect(disposeStart, greaterThanOrEqualTo(0));
    expect(disposeEnd, greaterThan(disposeStart));
    final String disposeBody = captureSource.substring(
      disposeStart,
      disposeEnd,
    );
    expect(
      disposeBody,
      contains('VioDiagnosticsRecorder.instance.stopInBackground();'),
    );
    expect(
      disposeBody,
      isNot(contains('await VioDiagnosticsRecorder.instance.stop()')),
      reason: 'State.dispose must remain synchronous',
    );

    final int finishStart = captureSource.indexOf(
      'Future<void> _commitCaptureExit(',
    );
    final int finishEnd = captureSource.indexOf(
      'Future<void> _continueCommittedReconstruction(',
      finishStart,
    );
    expect(finishStart, greaterThanOrEqualTo(0));
    expect(finishEnd, greaterThan(finishStart));
    final String finishBody = captureSource.substring(finishStart, finishEnd);
    final int visibleTransition = finishBody.indexOf('_recording = false;');
    final int cameraStop = finishBody.indexOf(
      'await session.stopCameraTransport();',
    );
    final int terminalShadowStop = finishBody.indexOf(
      '_stopVioShadowInBackground();',
    );
    expect(visibleTransition, greaterThanOrEqualTo(0));
    expect(cameraStop, greaterThan(visibleTransition));
    expect(terminalShadowStop, greaterThan(cameraStop));
    expect(
      finishBody,
      isNot(contains('await _stopVioShadowForCapture()')),
      reason: 'diagnostic shutdown must not own production exit latency',
    );
    expect(
      finishBody.substring(cameraStop),
      isNot(contains('resumeCameraTransport()')),
      reason: 'terminal shadow cleanup must never reopen the production camera',
    );

    final RegExpMatch? orchestration = RegExp(
      r'Future<bool> orchestrateToProcessing\([\s\S]*?\) async \{([\s\S]*?)\n  \}',
    ).firstMatch(finishCoordinatorSource);
    expect(orchestration, isNotNull);
    final String orchestrationBody = orchestration!.group(1)!;
    expect(
      orchestrationBody.indexOf("stage: 'stopCamera'"),
      lessThan(orchestrationBody.indexOf("stage: 'beginProcessing'")),
      reason:
          'camera teardown completes before the independently awaited shadow receipt',
    );
    expect(
      source,
      contains('_consumeShadowSnapshot(terminal, requireTerminal: true)'),
    );
    expect(source, contains('_lastTerminalReceiptAccepted = true'));
  });
}
