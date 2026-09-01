import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';

void main() {
  test('native presentation receipts map to one explicit terminal', () {
    expect(
      acceptedPhotoPresentationOutcomeFromReceipt(<String, Object?>{
        'rendered': true,
      }),
      AcceptedPhotoPresentationOutcome.presented,
    );
    expect(
      acceptedPhotoPresentationOutcomeFromReceipt(<String, Object?>{
        'suppressed': true,
      }),
      AcceptedPhotoPresentationOutcome.suppressed,
    );
    expect(
      acceptedPhotoPresentationOutcomeFromReceipt(null),
      AcceptedPhotoPresentationOutcome.failed,
    );
  });

  group('AcceptedPhotoTransactionCoordinator', () {
    test('data and presentation outcomes are independent and exactly once', () {
      final coordinator = AcceptedPhotoTransactionCoordinator();
      coordinator.openNextGeneration();
      final transaction = coordinator.begin('tap-1');

      expect(coordinator.acceptData(transaction), isTrue);
      expect(
        coordinator.resolvePresentation(
          transaction,
          AcceptedPhotoPresentationOutcome.failed,
        ),
        isTrue,
      );

      expect(transaction.dataOutcome, AcceptedPhotoDataOutcome.accepted);
      expect(
        transaction.presentationOutcome,
        AcceptedPhotoPresentationOutcome.failed,
      );
      expect(coordinator.acceptData(transaction), isFalse);
      expect(coordinator.rejectData(transaction), isFalse);
      expect(
        coordinator.resolvePresentation(
          transaction,
          AcceptedPhotoPresentationOutcome.presented,
        ),
        isFalse,
      );
      expect(transaction.dataOutcome, AcceptedPhotoDataOutcome.accepted);
    });

    test(
      'sealing a generation cancels pending data and forbids late commit',
      () {
        final coordinator = AcceptedPhotoTransactionCoordinator();
        final firstGeneration = coordinator.openNextGeneration();
        final stale = coordinator.begin('tap-1');

        coordinator.sealCurrentGeneration();

        expect(stale.generation, firstGeneration);
        expect(stale.dataOutcome, AcceptedPhotoDataOutcome.cancelled);
        expect(coordinator.isOpen(stale), isFalse);
        expect(coordinator.acceptData(stale), isFalse);

        final secondGeneration = coordinator.openNextGeneration();
        final current = coordinator.begin('tap-2');
        expect(secondGeneration, firstGeneration + 1);
        expect(coordinator.isOpen(current), isTrue);
        expect(coordinator.acceptData(current), isTrue);
        expect(current.dataOutcome, AcceptedPhotoDataOutcome.accepted);
        expect(stale.dataOutcome, AcceptedPhotoDataOutcome.cancelled);
      },
    );

    test(
      'sealing admission keeps the admitted transaction terminal eligible',
      () {
        final coordinator = AcceptedPhotoTransactionCoordinator();
        coordinator.openNextGeneration();
        final active = coordinator.begin('tap-active-at-finish');

        coordinator.sealAdmission();

        expect(coordinator.hasOpenGeneration, isFalse);
        expect(() => coordinator.begin('tap-after-finish'), throwsStateError);
        expect(active.dataOutcome, AcceptedPhotoDataOutcome.pending);
        expect(coordinator.isOpen(active), isTrue);
        expect(coordinator.beginDataPublication(active), isTrue);
        expect(coordinator.acceptData(active), isTrue);
        expect(active.dataOutcome, AcceptedPhotoDataOutcome.accepted);
      },
    );

    test('reject is terminal without changing presentation state', () {
      final coordinator = AcceptedPhotoTransactionCoordinator();
      coordinator.openNextGeneration();
      final transaction = coordinator.begin('tap-1');

      expect(coordinator.rejectData(transaction), isTrue);
      expect(transaction.dataOutcome, AcceptedPhotoDataOutcome.rejected);
      expect(
        transaction.presentationOutcome,
        AcceptedPhotoPresentationOutcome.pending,
      );
      expect(coordinator.acceptData(transaction), isFalse);
    });

    test('presentation may terminate after data generation is sealed', () {
      final coordinator = AcceptedPhotoTransactionCoordinator();
      coordinator.openNextGeneration();
      final transaction = coordinator.begin('tap-1');
      expect(coordinator.acceptData(transaction), isTrue);

      coordinator.sealCurrentGeneration();

      expect(
        coordinator.resolvePresentation(
          transaction,
          AcceptedPhotoPresentationOutcome.suppressed,
        ),
        isTrue,
      );
      expect(transaction.dataOutcome, AcceptedPhotoDataOutcome.accepted);
      expect(
        transaction.presentationOutcome,
        AcceptedPhotoPresentationOutcome.suppressed,
      );
    });

    test('atomic publication has a precise generation-seal linearization', () {
      final coordinator = AcceptedPhotoTransactionCoordinator();
      coordinator.openNextGeneration();
      final submitted = coordinator.begin('tap-submitted');

      expect(coordinator.beginDataPublication(submitted), isTrue);
      coordinator.sealCurrentGeneration();
      expect(
        coordinator.acceptData(submitted),
        isTrue,
        reason: 'rename submission happened before the synchronous seal',
      );

      coordinator.openNextGeneration();
      final late = coordinator.begin('tap-late');
      coordinator.sealCurrentGeneration();
      expect(coordinator.beginDataPublication(late), isFalse);
      expect(coordinator.acceptData(late), isFalse);
      expect(late.dataOutcome, AcceptedPhotoDataOutcome.cancelled);
    });
  });
}
