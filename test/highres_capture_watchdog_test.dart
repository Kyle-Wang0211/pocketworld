import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/highres_capture_watchdog.dart';
import 'package:pocketworld_flutter/official_capture/manual_capture_queue.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';

Future<void> _flush() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await Future<void>.delayed(Duration.zero);
}

void main() {
  test(
    'a missing native completion becomes a typed terminal timeout',
    () async {
      final never = Completer<int>();

      await expectLater(
        awaitOfficialHighResTerminal(
          never.future,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(
          isA<OfficialHighResCaptureException>().having(
            (error) => error.failure,
            'failure',
            OfficialHighResInputFailure.captureTimedOut,
          ),
        ),
      );
    },
  );

  test(
    'watchdog failure releases the serial queue for the next ticket',
    () async {
      final never = Completer<void>();
      final started = <int>[];
      final failed = <int>[];
      final queue = ManualCaptureQueue(
        maxTickets: 2,
        execute: (ticket) async {
          started.add(ticket.id);
          if (ticket.id == 1) {
            await awaitOfficialHighResTerminal(
              never.future,
              timeout: const Duration(milliseconds: 5),
            );
          }
        },
        onError: (ticket, _, _) => failed.add(ticket.id),
      );

      queue.enqueue(verifiedCount: 0);
      await _flush();
      expect(failed, <int>[1]);
      expect(queue.outstandingCount, 0);

      queue.enqueue(verifiedCount: 0);
      await _flush();

      expect(failed, <int>[1]);
      expect(started, <int>[1, 2]);
      expect(queue.outstandingCount, 0);
    },
  );

  test('a completion after timeout is delivered only to cleanup', () async {
    final operation = Completer<int>();
    final late = <int>[];

    await expectLater(
      awaitOfficialHighResTerminal(
        operation.future,
        timeout: const Duration(milliseconds: 5),
        onLateCompletion: late.add,
      ),
      throwsA(isA<OfficialHighResCaptureException>()),
    );
    operation.complete(42);
    await _flush();

    expect(late, <int>[42]);
  });
}
