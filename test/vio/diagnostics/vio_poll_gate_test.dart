import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/diagnostics/vio_diagnostics_recorder.dart';
import 'package:pocketworld_flutter/vio/thermal/thermal_signal.dart';
import 'package:pocketworld_flutter/vio/thermal/vio_thermal_channel.dart';
import 'package:pocketworld_flutter/vio/timebase/ios_timebase_channel.dart';

class _BarrierTimebase extends IosTimebaseChannel {
  _BarrierTimebase(this.firstBeginEntered, this.firstBeginRelease);

  final Completer<void> firstBeginEntered;
  final Completer<void> firstBeginRelease;
  final List<String> events = <String>[];
  int beginCount = 0;

  @override
  Future<void> beginSession({
    required String sessionId,
    required int sessionEpoch,
  }) async {
    beginCount++;
    events.add('begin:$sessionEpoch');
    if (beginCount == 1) {
      firstBeginEntered.complete();
      await firstBeginRelease.future;
    }
    events.add('begin-complete:$sessionEpoch');
  }

  @override
  Future<bool> startRawCoreMotionFeed({
    required double accelerometerHz,
    required double gyroscopeHz,
  }) async {
    events.add('motion-start');
    return true;
  }

  @override
  Future<void> stopRawCoreMotionFeed() async {
    events.add('motion-stop');
  }

  @override
  Future<IosTimebaseSnapshot?> snapshot() async {
    events.add('snapshot');
    return null;
  }

  @override
  Future<Map<String, Object?>?> latestIntrinsics() async {
    events.add('intrinsics');
    return null;
  }

  @override
  Future<Map<String, Object?>?> slamStop() async {
    events.add('slam-stop');
    return const <String, Object?>{};
  }
}

class _FakeThermal extends VioThermalChannel {
  final List<String> events = <String>[];

  @override
  Future<void> start() async => events.add('start');

  @override
  Future<void> stop() async => events.add('stop');

  @override
  Stream<ThermalSignal> signals() => const Stream<ThermalSignal>.empty();

  @override
  Future<ThermalSignal?> snapshot() async => null;
}

VioDiagnosticsRecorder _recorder(
  _BarrierTimebase timebase,
  _FakeThermal thermal,
  Directory output,
) => VioDiagnosticsRecorder(
  timebase: timebase,
  thermal: thermal,
  pollInterval: const Duration(hours: 1),
  flushInterval: const Duration(hours: 1),
  documentsDirProvider: () async => output,
  sessionIdFactory: () => '123e4567-e89b-42d3-a456-426614174000',
  supportedOverride: true,
);

void main() {
  test(
    'stop drains one in-flight tick and invalidates its generation',
    () async {
      final VioDiagnosticPollGate gate = VioDiagnosticPollGate();
      gate.open();
      final Completer<void> entered = Completer<void>();
      final Completer<void> release = Completer<void>();
      int applied = 0;

      final Future<bool> tick = gate.run((int token) async {
        entered.complete();
        await release.future;
        if (gate.isCurrent(token)) applied++;
      });
      await entered.future;
      final Future<void> stop = gate.closeAndDrain();
      release.complete();

      expect(await tick, isTrue);
      await stop;
      expect(applied, 0);
      expect(await gate.run((_) async => applied++), isFalse);
    },
  );

  test('only one tick is in flight and restart has a new token', () async {
    final VioDiagnosticPollGate gate = VioDiagnosticPollGate();
    final int first = gate.open();
    final Completer<void> release = Completer<void>();
    final Future<bool> active = gate.run((_) => release.future);
    expect(await gate.run((_) async {}), isFalse);
    release.complete();
    expect(await active, isTrue);
    await gate.closeAndDrain();
    final int second = gate.open();
    expect(second, greaterThan(first));
    expect(gate.isCurrent(first), isFalse);
    expect(gate.isCurrent(second), isTrue);
  });

  test(
    'start and stop are one serialized transaction across an await',
    () async {
      final Completer<void> entered = Completer<void>();
      final Completer<void> release = Completer<void>();
      final _BarrierTimebase timebase = _BarrierTimebase(entered, release);
      final _FakeThermal thermal = _FakeThermal();
      final Directory output = Directory.systemTemp.createTempSync(
        'pw-vio-lifecycle-',
      );
      addTearDown(() {
        if (output.existsSync()) output.deleteSync(recursive: true);
      });
      final VioDiagnosticsRecorder recorder = _recorder(
        timebase,
        thermal,
        output,
      );

      final Future<void> start = recorder.start();
      await entered.future;
      final Future<void> stop = recorder.stop();
      await Future<void>.delayed(Duration.zero);
      expect(timebase.events, isNot(contains('slam-stop')));

      release.complete();
      await start;
      await stop;
      expect(recorder.isRunning, isFalse);
      expect(
        timebase.events.indexOf('motion-start'),
        lessThan(timebase.events.indexOf('slam-stop')),
      );
    },
  );

  test('start-stop-start queues cleanly without losing the restart', () async {
    final Completer<void> entered = Completer<void>();
    final Completer<void> release = Completer<void>();
    final _BarrierTimebase timebase = _BarrierTimebase(entered, release);
    final _FakeThermal thermal = _FakeThermal();
    final Directory output = Directory.systemTemp.createTempSync(
      'pw-vio-restart-',
    );
    addTearDown(() {
      if (output.existsSync()) output.deleteSync(recursive: true);
    });
    final VioDiagnosticsRecorder recorder = _recorder(
      timebase,
      thermal,
      output,
    );

    final Future<void> firstStart = recorder.start();
    await entered.future;
    final Future<void> stop = recorder.stop();
    final Future<void> secondStart = recorder.start();
    release.complete();
    await Future.wait<void>(<Future<void>>[firstStart, stop, secondStart]);

    expect(recorder.isRunning, isTrue);
    expect(timebase.beginCount, 2);
    expect(timebase.events.where((String e) => e == 'motion-start').length, 2);
    await recorder.stop();
  });
}
