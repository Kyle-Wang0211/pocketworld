import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/capture_finish_coordinator.dart';

CaptureFinishCoordinator coordinator({
  CaptureFinishStateListener? onStateChanged,
}) => CaptureFinishCoordinator(
  stageTimeout: const Duration(milliseconds: 50),
  onStateChanged: onStateChanged,
);

Future<void> flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

Future<CaptureFinishAttempt> reachProcessing(
  CaptureFinishCoordinator subject,
) async {
  final attempt = subject.beginFinish(
    exitIntent: CaptureFinishExitIntent.popToDrafts,
  )!;
  expect(
    await subject.orchestrateToProcessing(
      attempt: attempt,
      drainActiveTicket: () async {},
      stopCamera: () async {},
      beginProcessing: () async {},
    ),
    isTrue,
  );
  return attempt;
}

void main() {
  test('happy path follows the one legal finish sequence', () async {
    final states = <CaptureFinishPhase>[];
    final subject = coordinator(onStateChanged: states.add);

    expect(subject.phase, CaptureFinishPhase.capturing);
    expect(subject.captureAdmissionOpen, isTrue);
    expect(subject.captureRootTombstoned, isFalse);
    expect(subject.shouldShowOpaqueOverlay, isFalse);
    expect(subject.canPop, isTrue);

    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    )!;
    expect(subject.phase, CaptureFinishPhase.committing);
    expect(subject.exitIntent, CaptureFinishExitIntent.popToDrafts);
    expect(subject.captureAdmissionOpen, isFalse);
    expect(subject.captureRootTombstoned, isTrue);
    expect(subject.shouldShowOpaqueOverlay, isTrue);
    expect(subject.canPop, isFalse);

    expect(
      await subject.orchestrateToProcessing(
        attempt: attempt,
        drainActiveTicket: () async {},
        stopCamera: () async {},
        beginProcessing: () async {},
      ),
      isTrue,
    );
    expect(subject.completeSuccess(attempt), isTrue);
    expect(subject.terminalOutcome, CaptureFinishTerminalOutcome.success);
    expect(subject.completeSuccess(attempt), isFalse);
    expect(subject.beginExit(attempt), isTrue);
    expect(subject.markExited(attempt), isTrue);

    expect(states, <CaptureFinishPhase>[
      CaptureFinishPhase.committing,
      CaptureFinishPhase.drainingActiveTicket,
      CaptureFinishPhase.cameraStopped,
      CaptureFinishPhase.processing,
      CaptureFinishPhase.success,
      CaptureFinishPhase.exiting,
      CaptureFinishPhase.exited,
    ]);
    expect(subject.shouldShowOpaqueOverlay, isFalse);
    expect(subject.captureRootTombstoned, isTrue);
    expect(subject.canPop, isTrue);
  });

  test(
    'duplicate Finish cannot replace the synchronously latched exit intent',
    () {
      final subject = coordinator();

      final first = subject.beginFinish(
        exitIntent: CaptureFinishExitIntent.popToDrafts,
      );
      final duplicate = subject.beginFinish(
        exitIntent: CaptureFinishExitIntent.remainOnRoute,
      );

      expect(first, isNotNull);
      expect(duplicate, isNull);
      expect(subject.currentGeneration, first!.generation);
      expect(subject.exitIntent, CaptureFinishExitIntent.popToDrafts);
      expect(subject.phase, CaptureFinishPhase.committing);
    },
  );

  test('illegal transitions and stale generations are rejected', () async {
    final subject = coordinator();
    const stale = CaptureFinishAttempt(-1);
    var ran = false;

    expect(subject.completeSuccess(stale), isFalse);
    expect(subject.beginExit(stale), isFalse);
    expect(subject.markExited(stale), isFalse);
    expect(
      await subject.runProcessingStep(
        attempt: stale,
        stage: 'stale',
        operation: () async => ran = true,
      ),
      isFalse,
    );
    expect(ran, isFalse);

    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.remainOnRoute,
    )!;
    expect(subject.completeSuccess(attempt), isFalse);
    expect(subject.beginExit(attempt), isFalse);
    expect(subject.markExited(attempt), isFalse);
    expect(subject.cancelBeforeCommit(), isNull);
    expect(subject.phase, CaptureFinishPhase.committing);
  });

  for (final failingStage in <String>[
    'drainActiveTicket',
    'stopCamera',
    'beginProcessing',
  ]) {
    test(
      '$failingStage throw becomes the exactly-once error terminal',
      () async {
        final subject = coordinator();
        final attempt = subject.beginFinish(
          exitIntent: CaptureFinishExitIntent.popToDrafts,
        )!;
        var cameraCalls = 0;
        var processingCalls = 0;

        Future<void> failIf(String stage) async {
          if (stage == failingStage) throw StateError('$stage failed');
        }

        expect(
          await subject.orchestrateToProcessing(
            attempt: attempt,
            drainActiveTicket: () => failIf('drainActiveTicket'),
            stopCamera: () async {
              cameraCalls++;
              await failIf('stopCamera');
            },
            beginProcessing: () async {
              processingCalls++;
              await failIf('beginProcessing');
            },
          ),
          isFalse,
        );
        expect(subject.phase, CaptureFinishPhase.error);
        expect(subject.terminalOutcome, CaptureFinishTerminalOutcome.error);
        expect(subject.failure?.stage, failingStage);
        expect(subject.failure?.timedOut, isFalse);
        expect(subject.completeSuccess(attempt), isFalse);
        expect(
          cameraCalls,
          1,
          reason: 'committed Finish must always stop the camera exactly once',
        );
        expect(
          processingCalls,
          1,
          reason: 'committed Finish must always terminalize session resources',
        );
      },
    );
  }

  test('a never-completing await times out to error', () async {
    final subject = coordinator();
    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    )!;
    final never = Completer<void>();
    var cameraCalls = 0;
    var processingCalls = 0;

    expect(
      await subject.orchestrateToProcessing(
        attempt: attempt,
        drainActiveTicket: () => never.future,
        stopCamera: () async {
          cameraCalls++;
        },
        beginProcessing: () async {
          processingCalls++;
        },
      ),
      isFalse,
    );
    expect(subject.phase, CaptureFinishPhase.error);
    expect(subject.failure?.stage, 'drainActiveTicket');
    expect(subject.failure?.timedOut, isTrue);
    expect(cameraCalls, 1);
    expect(processingCalls, 1);

    never.complete();
    await flushMicrotasks();
    expect(subject.completeSuccess(attempt), isFalse);
    expect(subject.phase, CaptureFinishPhase.error);
  });

  test(
    'accepted data survives a stuck presentation while teardown suppresses once',
    () async {
      final subject = coordinator();
      final attempt = subject.beginFinish(
        exitIntent: CaptureFinishExitIntent.popToDrafts,
      )!;
      final photos = AcceptedPhotoTransactionCoordinator();
      photos.openNextGeneration();
      final photo = photos.begin('accepted-before-finish');
      expect(photos.acceptData(photo), isTrue);
      final never = Completer<void>();
      var cameraCalls = 0;

      expect(
        await subject.orchestrateToProcessing(
          attempt: attempt,
          drainActiveTicket: () {
            expect(
              photos.resolvePresentation(
                photo,
                AcceptedPhotoPresentationOutcome.suppressed,
              ),
              isTrue,
            );
            return never.future;
          },
          stopCamera: () async {
            cameraCalls++;
          },
          beginProcessing: () async => photos.sealCurrentGeneration(),
        ),
        isFalse,
      );

      expect(cameraCalls, 1);
      expect(photo.dataOutcome, AcceptedPhotoDataOutcome.accepted);
      expect(
        photo.presentationOutcome,
        AcceptedPhotoPresentationOutcome.suppressed,
      );
      expect(
        photos.resolvePresentation(
          photo,
          AcceptedPhotoPresentationOutcome.presented,
        ),
        isFalse,
        reason: 'a late native render cannot replace Finish suppression',
      );
    },
  );

  test('a stuck pending photo is cancelled during committed cleanup', () async {
    final subject = coordinator();
    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    )!;
    final photos = AcceptedPhotoTransactionCoordinator();
    photos.openNextGeneration();
    final photo = photos.begin('pending-at-timeout');
    final never = Completer<void>();

    expect(
      await subject.orchestrateToProcessing(
        attempt: attempt,
        drainActiveTicket: () {
          photos.resolvePresentation(
            photo,
            AcceptedPhotoPresentationOutcome.suppressed,
          );
          return never.future;
        },
        stopCamera: () async {},
        beginProcessing: () async => photos.sealCurrentGeneration(),
      ),
      isFalse,
    );

    expect(photo.dataOutcome, AcceptedPhotoDataOutcome.cancelled);
    expect(
      photo.presentationOutcome,
      AcceptedPhotoPresentationOutcome.suppressed,
    );
  });

  test(
    'cleanup failures are secondary evidence and never replace the cause',
    () async {
      final subject = coordinator();
      final attempt = subject.beginFinish(
        exitIntent: CaptureFinishExitIntent.popToDrafts,
      )!;
      final never = Completer<void>();

      expect(
        await subject.orchestrateToProcessing(
          attempt: attempt,
          drainActiveTicket: () async =>
              throw StateError('primary drain error'),
          stopCamera: () async => throw StateError('camera cleanup error'),
          beginProcessing: () => never.future,
        ),
        isFalse,
      );

      expect(subject.failure?.stage, 'drainActiveTicket');
      expect(subject.failure?.error, isA<StateError>());
      expect(subject.cleanupFailures.map((failure) => failure.stage), <String>[
        'stopCameraCleanup',
        'beginProcessingCleanup',
      ]);
      expect(subject.cleanupFailures.first.timedOut, isFalse);
      expect(subject.cleanupFailures.last.timedOut, isTrue);
    },
  );

  test('processing step throw and timeout are terminalized', () async {
    final thrown = coordinator();
    final thrownAttempt = await reachProcessing(thrown);
    expect(
      await thrown.runProcessingStep(
        attempt: thrownAttempt,
        stage: 'colorize',
        operation: () async => throw StateError('bad snapshot'),
      ),
      isFalse,
    );
    expect(thrown.phase, CaptureFinishPhase.error);
    expect(thrown.failure?.stage, 'colorize');
    expect(thrown.failure?.timedOut, isFalse);

    final timedOut = coordinator();
    final timedOutAttempt = await reachProcessing(timedOut);
    final never = Completer<void>();
    expect(
      await timedOut.runProcessingStep(
        attempt: timedOutAttempt,
        stage: 'persistSparseSnapshot',
        operation: () => never.future,
      ),
      isFalse,
    );
    expect(timedOut.phase, CaptureFinishPhase.error);
    expect(timedOut.failure?.stage, 'persistSparseSnapshot');
    expect(timedOut.failure?.timedOut, isTrue);
  });

  test(
    'late success, duplicate error, and stale callbacks cannot replace error',
    () async {
      final subject = coordinator();
      final attempt = await reachProcessing(subject);

      expect(
        subject.completeError(
          attempt,
          stage: 'workerExit',
          error: StateError('worker exited'),
        ),
        isTrue,
      );
      expect(subject.completeSuccess(attempt), isFalse);
      expect(
        subject.completeError(
          attempt,
          stage: 'lateColorize',
          error: StateError('late'),
        ),
        isFalse,
      );
      expect(
        subject.completeSuccess(CaptureFinishAttempt(attempt.generation - 1)),
        isFalse,
      );
      expect(subject.phase, CaptureFinishPhase.error);
      expect(subject.failure?.stage, 'workerExit');
    },
  );

  test('cancellation is terminal only before commit', () {
    final cancelled = coordinator();
    final attempt = cancelled.cancelBeforeCommit(
      exitIntent: CaptureFinishExitIntent.remainOnRoute,
    )!;

    expect(cancelled.phase, CaptureFinishPhase.cancelled);
    expect(cancelled.terminalOutcome, CaptureFinishTerminalOutcome.cancelled);
    expect(cancelled.captureAdmissionOpen, isFalse);
    expect(cancelled.captureRootTombstoned, isFalse);
    expect(cancelled.shouldShowOpaqueOverlay, isFalse);
    expect(cancelled.canPop, isTrue);
    expect(
      cancelled.beginFinish(exitIntent: CaptureFinishExitIntent.popToDrafts),
      isNull,
    );
    expect(cancelled.beginExit(attempt), isTrue);
    expect(cancelled.markExited(attempt), isTrue);

    final committed = coordinator();
    committed.beginFinish(exitIntent: CaptureFinishExitIntent.popToDrafts);
    expect(committed.cancelBeforeCommit(), isNull);
    expect(committed.phase, CaptureFinishPhase.committing);
  });

  test('discard navigation intent is synchronously latched at commit', () {
    final subject = coordinator();

    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.discardCapture,
    );

    expect(attempt, isNotNull);
    expect(subject.exitIntent, CaptureFinishExitIntent.discardCapture);
    expect(subject.captureAdmissionOpen, isFalse);
    expect(subject.captureRootTombstoned, isTrue);
    expect(subject.shouldShowOpaqueOverlay, isTrue);
  });

  test('back remains disabled throughout committed processing', () async {
    final subject = coordinator();
    final drain = Completer<void>();
    final camera = Completer<void>();
    final processing = Completer<void>();
    final attempt = subject.beginFinish(
      exitIntent: CaptureFinishExitIntent.popToDrafts,
    )!;

    final orchestration = subject.orchestrateToProcessing(
      attempt: attempt,
      drainActiveTicket: () => drain.future,
      stopCamera: () => camera.future,
      beginProcessing: () => processing.future,
    );
    expect(subject.phase, CaptureFinishPhase.drainingActiveTicket);
    expect(subject.canPop, isFalse);
    expect(subject.shouldShowOpaqueOverlay, isTrue);

    drain.complete();
    await flushMicrotasks();
    expect(subject.canPop, isFalse);

    camera.complete();
    await flushMicrotasks();
    expect(subject.phase, CaptureFinishPhase.processing);
    expect(subject.canPop, isFalse);
    expect(subject.shouldShowOpaqueOverlay, isTrue);

    processing.complete();
    expect(await orchestration, isTrue);
    expect(subject.phase, CaptureFinishPhase.processing);
    expect(subject.canPop, isFalse);
  });

  test(
    'a failed route reveal can retry without regressing exit state',
    () async {
      final subject = coordinator();
      final attempt = await reachProcessing(subject);
      expect(subject.completeSuccess(attempt), isTrue);

      expect(subject.beginExit(attempt), isTrue);
      expect(subject.phase, CaptureFinishPhase.exiting);
      expect(
        subject.beginExit(attempt),
        isTrue,
        reason: 'navigation may throw after the first exit latch',
      );
      expect(subject.phase, CaptureFinishPhase.exiting);
      expect(subject.markExited(attempt), isTrue);
    },
  );
}
