import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/sfm_recon_lifecycle.dart';

void main() {
  group('SfmDeliveryLedger', () {
    test(
      'reserves a worker slot before asynchronous dispatch can interleave',
      () {
        final ledger = SfmDeliveryLedger(maxInFlight: 2)
          ..offer(seq: 1, jpegPath: '/capture/1.jpg')
          ..offer(seq: 2, jpegPath: '/capture/2.jpg')
          ..offer(seq: 3, jpegPath: '/capture/3.jpg');

        expect(ledger.reserve(1), isTrue);
        expect(ledger.reserve(2), isTrue);
        expect(ledger.reserve(3), isFalse);
        expect(ledger.inFlightCount, 2);

        ledger.acknowledgeSuccess(1);
        expect(ledger.reserve(3), isTrue);
        expect(ledger.inFlightCount, 2);
      },
    );

    test('permanent delivery debt blocks finalize', () {
      final ledger = SfmDeliveryLedger()
        ..offer(seq: 1, jpegPath: '/capture/1.jpg');

      expect(ledger.reserve(1), isTrue);
      ledger.acknowledgeFailure(1, result: 'missingJpeg');

      expect(ledger.canFinalize, isFalse);
      expect(ledger.failures.single.result, 'missingJpeg');
      expect(ledger.failures.single.jpegPath, '/capture/1.jpg');
    });

    test(
      'extract retry keeps one offer identity and a second failure blocks',
      () {
        final ledger = SfmDeliveryLedger()
          ..offer(seq: 7, jpegPath: '/capture/7.jpg');

        expect(ledger.reserve(7), isTrue);
        ledger.retry(7);
        expect(ledger.offeredCount, 1);
        expect(ledger.reserve(7), isTrue);
        ledger.acknowledgeFailure(7, result: 'errExtract');

        expect(ledger.offeredCount, 1);
        expect(ledger.inFlightCount, 0);
        expect(ledger.canFinalize, isFalse);
      },
    );

    test('worker exit settles every queued and in-flight offer as debt', () {
      final ledger = SfmDeliveryLedger()
        ..offer(seq: 1, jpegPath: '/capture/1.jpg')
        ..offer(seq: 2, jpegPath: '/capture/2.jpg');
      expect(ledger.reserve(1), isTrue);

      ledger.failOutstanding(result: 'workerExited');

      expect(ledger.inFlightCount, 0);
      expect(ledger.failures.map((failure) => failure.seq), [1, 2]);
      expect(ledger.canFinalize, isFalse);
    });

    test('pending native removal blocks finalize and settles as debt', () {
      final ledger = SfmDeliveryLedger()
        ..offer(seq: 1, jpegPath: '/capture/1.jpg');
      expect(ledger.reserve(1), isTrue);
      ledger.acknowledgeSuccess(1);

      ledger.beginRemoval(1);
      expect(ledger.hasPendingRemoval, isTrue);
      expect(ledger.canFinalize, isFalse);

      ledger.completeRemoval(1, removed: false, result: 'removeTimeout');
      expect(ledger.hasPendingRemoval, isFalse);
      expect(ledger.failures.single.result, 'removeTimeout');
    });
  });

  test('terminal gate emits exactly one typed failure', () {
    final gate = SfmTerminalGate();

    final first = gate.fail(
      kind: SfmTerminalFailureKind.startupFailed,
      stage: 'startup',
      message: 'resource unavailable',
    );
    final duplicate = gate.fail(
      kind: SfmTerminalFailureKind.workerExited,
      stage: 'worker',
      message: 'exit after error',
    );

    expect(first, isNotNull);
    expect(first!.kind, SfmTerminalFailureKind.startupFailed);
    expect(duplicate, isNull);
    expect(gate.failure, same(first));
  });

  test('scoped environment override restores the exact prior value once', () {
    String? value = 'launch-value';
    var restoreWrites = 0;
    final override = SfmScopedEnvironmentOverride(
      initialValue: value,
      setValue: (next) => value = next,
      unsetValue: () => value = null,
      onRestore: () => restoreWrites++,
    );

    override.enable('1');
    expect(value, '1');
    override.restore();
    override.restore();

    expect(value, 'launch-value');
    expect(restoreWrites, 1);
  });

  test(
    'latest-wins publisher emits leading and newest trailing snapshot',
    () async {
      final published = <int>[];
      final publisher = SfmLatestWinsPublisher<int>(
        interval: const Duration(milliseconds: 15),
        publish: published.add,
      );

      publisher.add(1);
      publisher.add(2);
      publisher.add(3);
      expect(published, [1]);

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(published, [1, 3]);
      publisher.dispose();
    },
  );

  test(
    'production facade wires fatal exit, reservation, and ownership gates',
    () {
      final source = File(
        'lib/official_capture/sfm_live_recon.dart',
      ).readAsStringSync();

      expect(source, contains('onError: fromWorker.sendPort'));
      expect(source, contains('onExit: fromWorker.sendPort'));
      expect(source, contains('SfmTerminalFailureKind.workerFatal'));
      expect(source, contains('SfmTerminalFailureKind.workerExited'));
      expect(source, contains('_finalizeLivenessLimit'));
      expect(source, contains('_previewPublisher.add(snapshot)'));
      expect(source, contains('_publishTerminalFailureIfReady()'));
      expect(source, isNot(contains('aether_gpu_match_get_capture_active')));
      expect(source, isNot(contains('AetherMatchFlags.setCaptureActive')));

      final pumpStart = source.indexOf('Future<void> _pump()');
      final pumpEnd = source.indexOf('void _maybeSendFinalize()', pumpStart);
      final pump = source.substring(pumpStart, pumpEnd);
      expect(
        pump.indexOf('_deliveries.reserve(entry.seq)'),
        lessThan(pump.indexOf('await File(entry.path).exists()')),
      );

      final releaseStart = source.indexOf(
        'Future<void> _releaseWorkerResourcesAfterConfirmedExit()',
      );
      final release = source.substring(releaseStart);
      expect(
        release.indexOf("throw StateError('cannot release"),
        lessThan(release.indexOf('reconstructionLease.release(_leaseOwner)')),
      );
    },
  );
}
