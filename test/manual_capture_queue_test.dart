import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/manual_capture_queue.dart';

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test('ticket preserves whether admission came from automatic capture', () {
    final queue = ManualCaptureQueue(maxTickets: 2, execute: (_) async {});
    expect(
      queue
          .enqueue(verifiedCount: 0, automaticSelection: true)!
          .automaticSelection,
      isTrue,
    );
    expect(queue.enqueue(verifiedCount: 0)!.automaticSelection, isFalse);
  });

  test(
    'runs 100 synchronous admissions one at a time in strict FIFO order',
    () async {
      final gates = List<Completer<void>>.generate(
        100,
        (_) => Completer<void>(),
      );
      final started = <int>[];
      var activeExecutors = 0;
      var maxConcurrentExecutors = 0;
      var listenerCalls = 0;
      final queue = ManualCaptureQueue(
        maxTickets: 100,
        nowMicros: () => 123,
        execute: (ticket) async {
          started.add(ticket.id);
          activeExecutors += 1;
          if (activeExecutors > maxConcurrentExecutors) {
            maxConcurrentExecutors = activeExecutors;
          }
          await gates[ticket.id - 1].future;
          activeExecutors -= 1;
        },
      );
      queue.addListener(() => listenerCalls += 1);

      final accepted = <ManualCaptureTicket?>[
        for (var index = 0; index < 100; index += 1)
          queue.enqueue(verifiedCount: 0),
      ];

      expect(accepted, everyElement(isNotNull));
      expect(listenerCalls, 0);
      expect(started, isEmpty);
      expect(queue.inFlightCount, 0);
      expect(queue.pendingCount, 100);
      expect(queue.outstandingCount, 100);
      await _flushAsyncWork();
      expect(listenerCalls, 1);
      expect(started, <int>[1]);
      expect(queue.inFlightCount, 1);
      expect(queue.pendingCount, 99);
      expect(maxConcurrentExecutors, 1);

      for (var index = 0; index < gates.length; index += 1) {
        gates[index].complete();
        await _flushAsyncWork();
        expect(
          started,
          List<int>.generate(index + 2 > 100 ? 100 : index + 2, (i) => i + 1),
        );
        expect(maxConcurrentExecutors, 1);
      }

      expect(queue.pendingCount, 0);
      expect(queue.inFlightCount, 0);
      expect(queue.outstandingCount, 0);
    },
  );

  test(
    'freeze rejects admission, drains queued work, and resume reopens it',
    () async {
      final gates = List<Completer<void>>.generate(3, (_) => Completer<void>());
      final started = <int>[];
      final queue = ManualCaptureQueue(
        maxTickets: 3,
        execute: (ticket) async {
          started.add(ticket.id);
          await gates[ticket.id - 1].future;
        },
      );

      expect(queue.enqueue(verifiedCount: 0)?.id, 1);
      expect(queue.enqueue(verifiedCount: 0)?.id, 2);
      var drained = false;
      final drain = queue.freezeAndDrain().then((_) => drained = true);

      expect(queue.accepting, isFalse);
      expect(queue.canEnqueue(verifiedCount: 0), isFalse);
      expect(queue.enqueue(verifiedCount: 0), isNull);
      expect(drained, isFalse);

      gates[0].complete();
      await _flushAsyncWork();
      expect(started, <int>[1, 2]);
      expect(drained, isFalse);

      gates[1].complete();
      await drain;
      expect(queue.outstandingCount, 0);

      queue.resume();
      expect(queue.accepting, isTrue);
      expect(queue.enqueue(verifiedCount: 0)?.id, 3);
      gates[2].complete();
      await queue.freezeAndDrain();
      expect(started, <int>[1, 2, 3]);
    },
  );

  test('cancelPending removes only tickets that have not started', () async {
    final activeGate = Completer<void>();
    final started = <int>[];
    final queue = ManualCaptureQueue(
      maxTickets: 3,
      execute: (ticket) async {
        started.add(ticket.id);
        await activeGate.future;
      },
    );

    queue.enqueue(verifiedCount: 0);
    queue.enqueue(verifiedCount: 0);
    queue.enqueue(verifiedCount: 0);
    await _flushAsyncWork();
    queue.cancelPending();

    expect(queue.accepting, isFalse);
    expect(queue.pendingCount, 0);
    expect(queue.inFlightCount, 1);
    expect(queue.outstandingCount, 1);
    expect(started, <int>[1]);
    expect(queue.enqueue(verifiedCount: 0), isNull);

    final drain = queue.freezeAndDrain();
    activeGate.complete();
    await drain;
    expect(started, <int>[1]);
  });

  test('capacity includes verified and outstanding tickets', () async {
    final gates = List<Completer<void>>.generate(2, (_) => Completer<void>());
    final queue = ManualCaptureQueue(
      maxTickets: 3,
      execute: (ticket) => gates[ticket.id - 1].future,
    );

    expect(queue.canEnqueue(verifiedCount: 1), isTrue);
    expect(queue.enqueue(verifiedCount: 1)?.id, 1);
    expect(queue.canEnqueue(verifiedCount: 1), isTrue);
    expect(queue.enqueue(verifiedCount: 1)?.id, 2);
    expect(queue.canEnqueue(verifiedCount: 1), isFalse);
    expect(queue.enqueue(verifiedCount: 1), isNull);

    final drain = queue.freezeAndDrain();
    gates[0].complete();
    await _flushAsyncWork();
    gates[1].complete();
    await drain;
  });

  test('negative verified counts are rejected on both admission paths', () {
    final queue = ManualCaptureQueue(maxTickets: 1, execute: (_) async {});

    expect(() => queue.canEnqueue(verifiedCount: -1), throwsArgumentError);
    expect(() => queue.enqueue(verifiedCount: -1), throwsArgumentError);
  });

  test('tickets use deterministic timestamps and monotonic ids', () async {
    final timestamps = <int>[8001, 8002].iterator;
    final queue = ManualCaptureQueue(
      maxTickets: 2,
      nowMicros: () {
        timestamps.moveNext();
        return timestamps.current;
      },
      execute: (_) async {},
    );

    final first = queue.enqueue(verifiedCount: 0)!;
    final second = queue.enqueue(verifiedCount: 0)!;

    expect(first.id, 1);
    expect(first.tapTimestampMicros, 8001);
    expect(second.id, 2);
    expect(second.tapTimestampMicros, 8002);
    await queue.freezeAndDrain();
  });

  test('reports executor errors with their ticket and continues', () async {
    final started = <int>[];
    final failures = <(ManualCaptureTicket, Object, StackTrace)>[];
    final queue = ManualCaptureQueue(
      maxTickets: 2,
      execute: (ticket) async {
        started.add(ticket.id);
        if (ticket.id == 1) throw StateError('capture failed');
      },
      onError: (ticket, error, stackTrace) {
        failures.add((ticket, error, stackTrace));
      },
    );

    queue.enqueue(verifiedCount: 0);
    queue.enqueue(verifiedCount: 0);
    await queue.freezeAndDrain();

    expect(started, <int>[1, 2]);
    expect(failures, hasLength(1));
    expect(failures.single.$1.id, 1);
    expect(failures.single.$2, isA<StateError>());
    expect(failures.single.$3, isA<StackTrace>());
  });

  test(
    'a throwing error handler is reported and does not stop the queue',
    () async {
      final previousErrorHandler = FlutterError.onError;
      final reported = <FlutterErrorDetails>[];
      final started = <int>[];
      FlutterError.onError = reported.add;
      try {
        final queue = ManualCaptureQueue(
          maxTickets: 2,
          execute: (ticket) async {
            started.add(ticket.id);
            if (ticket.id == 1) throw StateError('executor failed');
          },
          onError: (_, _, _) => throw ArgumentError('handler failed'),
        );

        queue.enqueue(verifiedCount: 0);
        queue.enqueue(verifiedCount: 0);
        await queue.freezeAndDrain();

        expect(started, <int>[1, 2]);
        expect(reported, hasLength(1));
        expect(reported.single.exception, isA<ArgumentError>());
        expect(reported.single.context.toString(), contains('ticket 1'));
      } finally {
        FlutterError.onError = previousErrorHandler;
      }
    },
  );

  test('resume is rejected until the current drain epoch completes', () async {
    final gate = Completer<void>();
    final queue = ManualCaptureQueue(
      maxTickets: 1,
      execute: (_) => gate.future,
    );

    queue.enqueue(verifiedCount: 0);
    await _flushAsyncWork();
    final drain = queue.freezeAndDrain();

    expect(queue.resume, throwsStateError);
    expect(queue.accepting, isFalse);

    gate.complete();
    await drain;
    queue.resume();
    expect(queue.accepting, isTrue);
  });

  test(
    'dispose before the scheduled pump cancels pending work safely',
    () async {
      final started = <int>[];
      var listenerCalls = 0;
      final queue = ManualCaptureQueue(
        maxTickets: 1,
        execute: (ticket) async => started.add(ticket.id),
      );
      queue.addListener(() => listenerCalls += 1);

      queue.enqueue(verifiedCount: 0);
      final drain = queue.freezeAndDrain();
      queue.dispose();

      await drain;
      await _flushAsyncWork();
      expect(started, isEmpty);
      expect(listenerCalls, 0);
      expect(queue.pendingCount, 0);
      expect(queue.inFlightCount, 0);
      expect(queue.outstandingCount, 0);
      expect(queue.accepting, isFalse);
      expect(queue.enqueue(verifiedCount: 0), isNull);
      expect(queue.canEnqueue(verifiedCount: 0), isFalse);
      expect(queue.resume, returnsNormally);
      expect(queue.cancelPending, returnsNormally);
      await expectLater(queue.freezeAndDrain(), completes);
    },
  );

  test(
    'dispose drops queued tickets while an active executor finishes',
    () async {
      final gate = Completer<void>();
      final started = <int>[];
      var listenerCalls = 0;
      final queue = ManualCaptureQueue(
        maxTickets: 2,
        execute: (ticket) async {
          started.add(ticket.id);
          await gate.future;
        },
      );
      queue.addListener(() => listenerCalls += 1);

      queue.enqueue(verifiedCount: 0);
      queue.enqueue(verifiedCount: 0);
      await _flushAsyncWork();
      expect(started, <int>[1]);
      final callsBeforeDispose = listenerCalls;
      final drain = queue.freezeAndDrain();
      var drained = false;
      unawaited(drain.then((_) => drained = true));

      queue.dispose();
      final postDisposeDrain = queue.freezeAndDrain();
      var postDisposeDrained = false;
      unawaited(postDisposeDrain.then((_) => postDisposeDrained = true));
      await _flushAsyncWork();
      expect(drained, isFalse);
      expect(postDisposeDrained, isFalse);
      expect(queue.pendingCount, 0);
      expect(queue.inFlightCount, 1);
      expect(queue.enqueue(verifiedCount: 0), isNull);

      gate.complete();
      await Future.wait(<Future<void>>[drain, postDisposeDrain]);
      expect(started, <int>[1]);
      expect(queue.inFlightCount, 0);
      expect(queue.outstandingCount, 0);
      expect(drained, isTrue);
      expect(postDisposeDrained, isTrue);
      expect(listenerCalls, callsBeforeDispose);
    },
  );

  test(
    'executor failure after dispose has no external error callbacks',
    () async {
      final gate = Completer<void>();
      final previousErrorHandler = FlutterError.onError;
      final frameworkErrors = <FlutterErrorDetails>[];
      var callbackCalls = 0;
      FlutterError.onError = frameworkErrors.add;
      try {
        final queue = ManualCaptureQueue(
          maxTickets: 1,
          execute: (_) async {
            await gate.future;
            throw StateError('late failure');
          },
          onError: (_, _, _) {
            callbackCalls += 1;
            throw StateError('callback must be suppressed');
          },
        );

        queue.enqueue(verifiedCount: 0);
        await _flushAsyncWork();
        queue.dispose();
        final drain = queue.freezeAndDrain();
        gate.complete();
        await drain;

        expect(callbackCalls, 0);
        expect(frameworkErrors, isEmpty);
        expect(queue.outstandingCount, 0);
      } finally {
        FlutterError.onError = previousErrorHandler;
      }
    },
  );

  test('production source has a metadata-only structural contract', () {
    final source = File(
      'lib/official_capture/manual_capture_queue.dart',
    ).readAsStringSync();
    final imports = RegExp(
      r"^import '([^']+)';$",
      multiLine: true,
    ).allMatches(source).map((match) => match.group(1)).toList();
    expect(imports, <String>[
      'dart:async',
      'dart:collection',
      'package:flutter/foundation.dart',
    ]);

    final ticketStart = source.indexOf('class ManualCaptureTicket');
    final ticketEnd = source.indexOf('typedef ManualCaptureExecutor');
    final ticketSource = source.substring(ticketStart, ticketEnd);
    final fields = RegExp(
      r'^\s*final\s+([^;]+);$',
      multiLine: true,
    ).allMatches(ticketSource).map((match) => match.group(1)).toList();
    expect(fields, <String>[
      'int id',
      'int tapTimestampMicros',
      'bool automaticSelection',
    ]);
    expect(
      source,
      contains(
        'final Queue<ManualCaptureTicket> _pending = '
        'Queue<ManualCaptureTicket>();',
      ),
    );
    const forbiddenTokens = <String>[
      'dart:typed_data',
      'dart:ui',
      'Uint8List',
      'ByteData',
      'Image',
      'CVPixelBuffer',
    ];
    for (final token in forbiddenTokens) {
      expect(source, isNot(contains(token)), reason: 'forbidden token: $token');
    }
  });
}
