import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/manual_capture_queue.dart';

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'enqueue starts the executor synchronously and never creates backlog',
    () async {
      final gate = Completer<void>();
      final events = <String>[];
      final queue = ManualCaptureQueue(
        maxTickets: 3,
        execute: (ticket) async {
          events.add('execute:${ticket.id}');
          await gate.future;
          events.add('complete:${ticket.id}');
        },
      );

      events.add('before');
      final ticket = queue.enqueue(verifiedCount: 0);
      events.add('after');

      expect(ticket?.id, 1);
      expect(events, <String>['before', 'execute:1', 'after']);
      expect(queue.pendingCount, 0);
      expect(queue.inFlightCount, 1);
      expect(queue.outstandingCount, 1);

      gate.complete();
      await queue.freezeAndDrain();
      expect(events, <String>['before', 'execute:1', 'after', 'complete:1']);
    },
  );

  test('busy latch rejects both manual and automatic requests', () async {
    final gate = Completer<void>();
    final started = <int>[];
    final queue = ManualCaptureQueue(
      maxTickets: 300,
      execute: (ticket) async {
        started.add(ticket.id);
        await gate.future;
      },
    );

    expect(queue.enqueue(verifiedCount: 20)?.id, 1);
    expect(queue.enqueue(verifiedCount: 20), isNull);
    expect(
      queue.enqueue(
        verifiedCount: 20,
        automaticSelection: true,
        automaticStillTicket: const AutomaticStillTicket(
          runGeneration: 1,
          ticketId: 7,
        ),
      ),
      isNull,
    );
    expect(started, <int>[1]);
    expect(queue.pendingCount, 0);

    gate.complete();
    await queue.freezeAndDrain();
  });

  test(
    'freeze cannot start a late ticket and resume opens a new epoch',
    () async {
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      final started = <int>[];
      final queue = ManualCaptureQueue(
        maxTickets: 2,
        execute: (ticket) async {
          started.add(ticket.id);
          await (ticket.id == 1 ? firstGate.future : secondGate.future);
        },
      );

      expect(queue.enqueue(verifiedCount: 0)?.id, 1);
      expect(queue.enqueue(verifiedCount: 0), isNull);
      final drain = queue.freezeAndDrain();
      expect(queue.enqueue(verifiedCount: 0), isNull);
      expect(started, <int>[1]);

      firstGate.complete();
      await drain;
      expect(started, <int>[1]);

      queue.resume();
      expect(queue.enqueue(verifiedCount: 0)?.id, 2);
      expect(started, <int>[1, 2]);
      secondGate.complete();
      await queue.freezeAndDrain();
    },
  );

  test('executor error releases the latch for the next request', () async {
    final failures = <Object>[];
    final started = <int>[];
    final queue = ManualCaptureQueue(
      maxTickets: 2,
      execute: (ticket) async {
        started.add(ticket.id);
        if (ticket.id == 1) throw StateError('capture failed');
      },
      onError: (_, error, _) => failures.add(error),
    );

    expect(queue.enqueue(verifiedCount: 0)?.id, 1);
    await _flushAsyncWork();
    expect(queue.inFlightCount, 0);
    expect(failures.single, isA<StateError>());

    expect(queue.enqueue(verifiedCount: 0)?.id, 2);
    expect(started, <int>[1, 2]);
    await queue.freezeAndDrain();
  });

  test(
    'a synchronous executor throw also releases the latch immediately',
    () async {
      final failures = <Object>[];
      final started = <int>[];
      final queue = ManualCaptureQueue(
        maxTickets: 2,
        execute: (ticket) {
          started.add(ticket.id);
          if (ticket.id == 1) throw StateError('synchronous failure');
          return Future<void>.value();
        },
        onError: (_, error, _) => failures.add(error),
      );

      expect(queue.enqueue(verifiedCount: 0)?.id, 1);
      expect(queue.inFlightCount, 0);
      expect(failures.single, isA<StateError>());
      expect(queue.enqueue(verifiedCount: 0)?.id, 2);
      expect(started, <int>[1, 2]);
      await queue.freezeAndDrain();
    },
  );

  test('cancel then drain has no queued executor to launch', () async {
    final gate = Completer<void>();
    final started = <int>[];
    final queue = ManualCaptureQueue(
      maxTickets: 3,
      execute: (ticket) async {
        started.add(ticket.id);
        await gate.future;
      },
    );

    expect(queue.enqueue(verifiedCount: 0)?.id, 1);
    expect(queue.enqueue(verifiedCount: 0), isNull);
    queue.cancelPending();
    final drain = queue.freezeAndDrain();
    expect(started, <int>[1]);
    expect(queue.pendingCount, 0);

    gate.complete();
    await drain;
    await _flushAsyncWork();
    expect(started, <int>[1]);
  });
}
