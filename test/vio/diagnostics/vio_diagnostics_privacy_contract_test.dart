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
    expect(source, contains('raw.isEmpty'));
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

  test('shadow lifetime is the capture lifetime, not the app lifetime', () {
    expect(
      mainSource,
      isNot(contains('VioDiagnosticsRecorder.instance.start()')),
    );
    expect(captureSource, contains('_startVioShadowForCapture()'));
    expect(captureSource, contains('_stopVioShadowForCapture()'));

    final int finishStart = captureSource.indexOf(
      'Future<void> _finalizeRecording(',
    );
    final int finishEnd = captureSource.indexOf(
      'void _exitToDrafts()',
      finishStart,
    );
    expect(finishStart, greaterThanOrEqualTo(0));
    expect(finishEnd, greaterThan(finishStart));
    final String finishBody = captureSource.substring(finishStart, finishEnd);
    expect(finishBody, contains('await _stopVioShadowForCapture()'));
    expect(
      finishBody.indexOf('await _stopVioShadowForCapture()'),
      lessThan(finishBody.indexOf("invokeMethod<void>('stopSession')")),
      reason: 'the terminal XRSLAM receipt must precede camera teardown',
    );
  });
}
