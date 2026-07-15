import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/manual_capture_ledger.dart';

void main() {
  group('ManualCaptureLedger lifecycle', () {
    test('assigns an immutable capture job identity at attempted', () {
      final attempted = ManualCaptureEvent.attempted(
        captureJobId: 'job-001',
        identityToken: 'tap-42:photos/job-001.jpg',
      );

      final ledger = const ManualCaptureLedger.empty().reduce(attempted);
      final job = ledger.job('job-001');

      expect(job, isNotNull);
      expect(job!.captureJobId, 'job-001');
      expect(job.identityToken, 'tap-42:photos/job-001.jpg');
      expect(job.attempted, isTrue);
      expect(job.accepted, isFalse);
      expect(job.photoCommitted, isFalse);
      expect(job.sfmQueued, isFalse);
      expect(job.sfmIngested, isFalse);
      expect(job.registered, isFalse);
      expect(job.userDeleted, isFalse);
      expect(job.blocked, isFalse);
    });

    test('advances only through every evidence stage', () {
      var ledger = _attemptedLedger('job-001');

      ledger = ledger
          .reduce(ManualCaptureEvent.accepted('job-001'))
          .reduce(ManualCaptureEvent.photoCommitted('job-001'))
          .reduce(ManualCaptureEvent.sfmQueued('job-001'))
          .reduce(ManualCaptureEvent.sfmIngested('job-001'))
          .reduce(_registeredEvent('job-001'));

      final job = ledger.job('job-001')!;
      expect(job.stage, ManualCaptureStage.registered);
      expect(job.accepted, isTrue);
      expect(job.photoCommitted, isTrue);
      expect(job.sfmQueued, isTrue);
      expect(job.sfmIngested, isTrue);
      expect(job.registered, isTrue);
      expect(job.registrationMapping!.nativeImageId, 'native-image-job-001');
      expect(job.registrationMapping!.evidenceToken, 'mapping-proof-job-001');
      expect(ledger.events, hasLength(6));
    });

    test('treats duplicate evidence as idempotent', () {
      final attempt = ManualCaptureEvent.attempted(
        captureJobId: 'job-001',
        identityToken: 'identity-001',
      );
      final accepted = ManualCaptureEvent.accepted('job-001');

      final once = const ManualCaptureLedger.empty()
          .reduce(attempt)
          .reduce(accepted);
      final duplicated = once
          .reduce(attempt)
          .reduce(accepted)
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'job-001',
              identityToken: 'identity-001',
            ),
          );

      expect(identical(duplicated, once), isTrue);
      expect(duplicated.events, hasLength(2));
      expect(duplicated.toCanonicalJson(), once.toCanonicalJson());
    });

    test('permits different jobs to complete out of tap order', () {
      var ledger = _attemptedLedger('job-a')
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'job-b',
              identityToken: 'identity-job-b',
            ),
          )
          .reduce(ManualCaptureEvent.accepted('job-a'))
          .reduce(ManualCaptureEvent.accepted('job-b'));

      ledger = _advanceToRegistered(ledger, 'job-b');
      ledger = _advanceToRegistered(ledger, 'job-a');

      expect(ledger.job('job-a')!.registered, isTrue);
      expect(ledger.job('job-b')!.registered, isTrue);
    });

    test('rejects skipped evidence and leaves the ledger unchanged', () {
      final ledger = _attemptedLedger('job-001');

      expect(
        () => ledger.reduce(ManualCaptureEvent.photoCommitted('job-001')),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(ledger.job('job-001')!.stage, ManualCaptureStage.attempted);
      expect(ledger.events, hasLength(1));
    });

    test('rejects unknown and conflicting identities', () {
      final ledger = _attemptedLedger('job-001');

      expect(
        () => ledger.reduce(ManualCaptureEvent.accepted('unknown-job')),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        () => ledger.reduce(
          ManualCaptureEvent.attempted(
            captureJobId: 'job-001',
            identityToken: 'different-paths',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        () => ledger.reduce(
          ManualCaptureEvent.attempted(
            captureJobId: 'job-002',
            identityToken: 'identity-job-001',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });

    test(
      'registered evidence is persisted and identity conflicts fail closed',
      () {
        var ledger = _attemptedLedger(
          'job-001',
        ).reduce(ManualCaptureEvent.accepted('job-001'));
        ledger = ledger
            .reduce(ManualCaptureEvent.photoCommitted('job-001'))
            .reduce(ManualCaptureEvent.sfmQueued('job-001'))
            .reduce(ManualCaptureEvent.sfmIngested('job-001'));
        final registered = ledger.reduce(_registeredEvent('job-001'));

        expect(
          identical(registered.reduce(_registeredEvent('job-001')), registered),
          isTrue,
        );
        expect(
          () => registered.reduce(
            ManualCaptureEvent.registered(
              'job-001',
              reconstructionEpochId: 'epoch-live-001',
              nativeImageId: 'different-native-image',
              mappingEvidenceToken: 'mapping-proof-job-001',
            ),
          ),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );
        expect(
          () => registered.reduce(
            ManualCaptureEvent.registered(
              'job-001',
              reconstructionEpochId: 'epoch-live-001',
              nativeImageId: 'native-image-job-001',
              mappingEvidenceToken: 'different-proof',
            ),
          ),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );
      },
    );

    test('rejects native image aliases and unannounced epoch changes', () {
      var ledger = _attemptedLedger('job-a')
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'job-b',
              identityToken: 'identity-job-b',
            ),
          )
          .reduce(ManualCaptureEvent.accepted('job-a'))
          .reduce(ManualCaptureEvent.accepted('job-b'));
      for (final jobId in const ['job-a', 'job-b']) {
        ledger = ledger
            .reduce(ManualCaptureEvent.photoCommitted(jobId))
            .reduce(ManualCaptureEvent.sfmQueued(jobId))
            .reduce(ManualCaptureEvent.sfmIngested(jobId));
      }
      ledger = ledger.reduce(
        ManualCaptureEvent.registered(
          'job-a',
          reconstructionEpochId: 'epoch-live-001',
          nativeImageId: 'native-image-shared',
          mappingEvidenceToken: 'mapping-proof-job-a',
        ),
      );

      expect(
        () => ledger.reduce(
          ManualCaptureEvent.registered(
            'job-b',
            reconstructionEpochId: 'epoch-live-001',
            nativeImageId: 'native-image-shared',
            mappingEvidenceToken: 'mapping-proof-job-b',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        () => ledger.reduce(
          ManualCaptureEvent.registered(
            'job-b',
            reconstructionEpochId: 'stale-or-unannounced-epoch',
            nativeImageId: 'native-image-job-b',
            mappingEvidenceToken: 'mapping-proof-job-b',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });

    test('records blockers idempotently and rejects blocker conflicts', () {
      final blocked = _attemptedLedger('job-001').reduce(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-snapshot-001',
          code: 'snapshot_reservation_failed',
          message: 'No camera snapshot was available.',
        ),
      );
      final duplicate = blocked.reduce(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-snapshot-001',
          code: 'snapshot_reservation_failed',
          message: 'No camera snapshot was available.',
        ),
      );

      expect(identical(duplicate, blocked), isTrue);
      expect(blocked.job('job-001')!.blocked, isTrue);
      expect(blocked.job('job-001')!.blockers, hasLength(1));
      expect(
        () => blocked.reduce(
          ManualCaptureEvent.blocked(
            'job-001',
            blockerId: 'blocker-snapshot-001',
            code: 'snapshot_reservation_failed',
            message: 'A different claim for the same blocker.',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });

    test(
      'resolves an active blocker without changing stage or denominator',
      () {
        final blocked = _attemptedLedger('job-001')
            .reduce(ManualCaptureEvent.accepted('job-001'))
            .reduce(
              ManualCaptureEvent.blocked(
                'job-001',
                blockerId: 'blocker-disk-001',
                code: 'disk_full',
                message: 'The writer ran out of space.',
              ),
            );
        final beforeStage = blocked.job('job-001')!.stage;
        final beforeExpected = blocked
            .closureReport(finalRegistration: _finalObservation(const {}))
            .expected;

        final resolved = blocked.reduce(
          ManualCaptureEvent.blockerResolved(
            'job-001',
            blockerId: 'blocker-disk-001',
            resolutionEvidence: 'free-space-check:sha256:0123456789abcdef',
          ),
        );

        final job = resolved.job('job-001')!;
        expect(job.stage, beforeStage);
        final resolvedReport = resolved.closureReport(
          finalRegistration: _finalObservation(const {}),
        );
        expect(resolvedReport.expected, beforeExpected);
        expect(job.blocked, isFalse);
        expect(job.blockers, isEmpty);
        expect(job.resolvedBlockers['blocker-disk-001']!.code, 'disk_full');
        expect(
          job.resolvedBlockers['blocker-disk-001']!.resolutionEvidence,
          'free-space-check:sha256:0123456789abcdef',
        );
        expect(resolvedReport.blockingJobIds, isEmpty);
        expect(resolvedReport.isComplete, isFalse);
        expect(
          resolved.events.map(
            (event) => jsonDecode(event.toCanonicalJson())['event'],
          ),
          ['attempted', 'accepted', 'blocked', 'blocker_resolved'],
        );
      },
    );

    test('treats the same blocker resolution evidence as idempotent', () {
      final blocked = _attemptedLedger('job-001').reduce(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-snapshot-001',
          code: 'snapshot_failed',
          message: 'No exact snapshot.',
        ),
      );
      final resolved = blocked.reduce(
        ManualCaptureEvent.blockerResolved(
          'job-001',
          blockerId: 'blocker-snapshot-001',
          resolutionEvidence: 'retry-ticket:ticket-002',
        ),
      );

      final duplicate = resolved.reduce(
        ManualCaptureEvent.blockerResolved(
          'job-001',
          blockerId: 'blocker-snapshot-001',
          resolutionEvidence: 'retry-ticket:ticket-002',
        ),
      );

      expect(identical(duplicate, resolved), isTrue);
      expect(duplicate.events, hasLength(3));
    });

    test('rejects unknown or conflicting blocker resolution evidence', () {
      final blocked = _attemptedLedger('job-001').reduce(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-disk-001',
          code: 'disk_full',
          message: 'No space.',
        ),
      );

      expect(
        () => blocked.reduce(
          ManualCaptureEvent.blockerResolved(
            'job-001',
            blockerId: 'unknown-blocker-occurrence',
            resolutionEvidence: 'proof:unknown',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );

      final resolved = blocked.reduce(
        ManualCaptureEvent.blockerResolved(
          'job-001',
          blockerId: 'blocker-disk-001',
          resolutionEvidence: 'proof:first',
        ),
      );
      expect(
        () => resolved.reduce(
          ManualCaptureEvent.blockerResolved(
            'job-001',
            blockerId: 'blocker-disk-001',
            resolutionEvidence: 'proof:conflicting',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        resolved
            .job('job-001')!
            .resolvedBlockers['blocker-disk-001']!
            .resolutionEvidence,
        'proof:first',
      );

      final repeatedCode = resolved.reduce(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-disk-002',
          code: 'disk_full',
          message: 'The same condition recurred later.',
        ),
      );
      expect(repeatedCode.job('job-001')!.blockers.keys, {'blocker-disk-002'});
      expect(
        () => resolved.reduce(
          ManualCaptureEvent.blocked(
            'job-001',
            blockerId: 'blocker-disk-001',
            code: 'disk_full',
            message: 'Reusing a resolved occurrence is forbidden.',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });

    test('rejects blocker resolution after user deletion', () {
      final deleted = _attemptedLedger('job-001')
          .reduce(
            ManualCaptureEvent.blocked(
              'job-001',
              blockerId: 'blocker-snapshot-001',
              code: 'snapshot_failed',
              message: 'No exact snapshot.',
            ),
          )
          .reduce(ManualCaptureEvent.userDeletionRequested('job-001'))
          .reduce(
            ManualCaptureEvent.writersQuiesced(
              'job-001',
              evidenceToken: 'writers-quiesced-proof-job-001',
            ),
          )
          .reduce(ManualCaptureEvent.userDeleted('job-001'));

      expect(
        () => deleted.reduce(
          ManualCaptureEvent.blockerResolved(
            'job-001',
            blockerId: 'blocker-snapshot-001',
            resolutionEvidence: 'retry-ticket:ticket-002',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(deleted.job('job-001')!.userDeleted, isTrue);
    });

    test('requires request and writer quiescence before user tombstone', () {
      final accepted = _attemptedLedger(
        'job-001',
      ).reduce(ManualCaptureEvent.accepted('job-001'));

      expect(
        () => accepted.reduce(ManualCaptureEvent.userDeleted('job-001')),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        () => accepted.reduce(
          ManualCaptureEvent.writersQuiesced(
            'job-001',
            evidenceToken: 'writers-quiesced-proof-job-001',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );

      final requested = accepted.reduce(
        ManualCaptureEvent.userDeletionRequested('job-001'),
      );
      expect(
        requested
            .closureReport(finalRegistration: _finalObservation(const {}))
            .expected,
        {'job-001'},
      );
      final quiesced = requested.reduce(
        ManualCaptureEvent.writersQuiesced(
          'job-001',
          evidenceToken: 'writers-quiesced-proof-job-001',
        ),
      );
      expect(
        () => quiesced.reduce(
          ManualCaptureEvent.writersQuiesced(
            'job-001',
            evidenceToken: 'conflicting-writer-proof',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(
        quiesced
            .closureReport(finalRegistration: _finalObservation(const {}))
            .expected,
        {'job-001'},
      );

      final deleted = quiesced.reduce(
        ManualCaptureEvent.userDeleted('job-001'),
      );
      final duplicate = deleted.reduce(
        ManualCaptureEvent.userDeleted('job-001'),
      );

      expect(deleted.job('job-001')!.userDeleted, isTrue);
      expect(identical(duplicate, deleted), isTrue);
      expect(
        () => deleted.reduce(ManualCaptureEvent.photoCommitted('job-001')),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(deleted.job('job-001')!.stage, ManualCaptureStage.accepted);
    });

    test('rejects lifecycle advancement after writers are quiesced', () {
      final quiesced = _attemptedLedger('job-001')
          .reduce(ManualCaptureEvent.accepted('job-001'))
          .reduce(ManualCaptureEvent.userDeletionRequested('job-001'))
          .reduce(
            ManualCaptureEvent.writersQuiesced(
              'job-001',
              evidenceToken: 'writers-quiesced-proof-job-001',
            ),
          );

      expect(
        () => quiesced.reduce(ManualCaptureEvent.photoCommitted('job-001')),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
      expect(quiesced.job('job-001')!.stage, ManualCaptureStage.accepted);
    });
  });

  group('ManualCaptureLedger closure', () {
    test('reports exact sets plus missing IDs and blockers', () {
      var ledger = _attemptedLedger('job-a')
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'job-b',
              identityToken: 'identity-job-b',
            ),
          )
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'failed-reservation',
              identityToken: 'identity-failed-reservation',
            ),
          )
          .reduce(ManualCaptureEvent.accepted('job-a'))
          .reduce(ManualCaptureEvent.accepted('job-b'));
      ledger = _advanceToRegistered(ledger, 'job-a');
      ledger = ledger
          .reduce(ManualCaptureEvent.photoCommitted('job-b'))
          .reduce(ManualCaptureEvent.sfmQueued('job-b'))
          .reduce(
            ManualCaptureEvent.blocked(
              'failed-reservation',
              blockerId: 'blocker-snapshot-failed-reservation',
              code: 'snapshot_reservation_failed',
              message: 'No exact snapshot.',
            ),
          );

      final report = ledger.closureReport(
        finalRegistration: _finalObservation(const {'job-a'}),
      );

      expect(report.expected, {'job-a', 'job-b'});
      expect(report.committed, {'job-a', 'job-b'});
      expect(report.queued, {'job-a', 'job-b'});
      expect(report.ingested, {'job-a'});
      expect(report.registered, {'job-a'});
      expect(report.missing['committed'], isEmpty);
      expect(report.missing['queued'], isEmpty);
      expect(report.missing['ingested'], {'job-b'});
      expect(report.missing['registered'], {'job-b'});
      expect(report.extra.values.expand((ids) => ids), isEmpty);
      expect(report.blockingJobIds, {'failed-reservation'});
      expect(report.isComplete, isFalse);
    });

    test('detects foreign IDs in observed final registration output', () {
      final ledger = _advanceToRegistered(
        _attemptedLedger('job-a').reduce(ManualCaptureEvent.accepted('job-a')),
        'job-a',
      );

      final report = ledger.closureReport(
        finalRegistration: _finalObservation(const {'job-a', 'foreign-image'}),
      );

      expect(report.extra['registered'], {'foreign-image'});
      expect(report.isComplete, isFalse);
    });

    test('rejects swapped native mappings and stale final epochs', () {
      var ledger = _attemptedLedger('job-a')
          .reduce(
            ManualCaptureEvent.attempted(
              captureJobId: 'job-b',
              identityToken: 'identity-job-b',
            ),
          )
          .reduce(ManualCaptureEvent.accepted('job-a'))
          .reduce(ManualCaptureEvent.accepted('job-b'));
      ledger = _advanceToRegistered(ledger, 'job-a');
      ledger = _advanceToRegistered(ledger, 'job-b');

      final swapped = ledger.closureReport(
        finalRegistration: _finalObservation(
          const {'job-a', 'job-b'},
          jobToNativeImageId: const {
            'job-a': 'native-image-job-b',
            'job-b': 'native-image-job-a',
          },
        ),
      );
      expect(swapped.registered, swapped.expected);
      expect(swapped.finalRegistrationMappingMatchesCurrentEpoch, isFalse);
      expect(swapped.isComplete, isFalse);

      final staleEpoch = ledger.closureReport(
        finalRegistration: _finalObservation(const {
          'job-a',
          'job-b',
        }, reconstructionEpochId: 'stale-epoch'),
      );
      expect(staleEpoch.finalRegistrationEpochMatches, isFalse);
      expect(staleEpoch.isComplete, isFalse);
    });

    test('requires identified final-registration evidence', () {
      expect(
        () => FinalRegistrationObservation(
          artifactIdentity: '',
          evidenceToken: 'observation-proof',
          reconstructionEpochId: 'epoch-live-001',
          jobToNativeImageId: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => FinalRegistrationObservation(
          artifactIdentity: 'final-ply:sha256:abc',
          evidenceToken: ' ',
          reconstructionEpochId: 'epoch-live-001',
          jobToNativeImageId: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => FinalRegistrationObservation(
          artifactIdentity: 'final-ply:sha256:abc',
          evidenceToken: 'observation-proof',
          reconstructionEpochId: 'epoch-live-001',
          jobToNativeImageId: const {'invalid\njob': 'native-image-001'},
        ),
        throwsArgumentError,
      );
      expect(
        () => FinalRegistrationObservation(
          artifactIdentity: 'final-ply:sha256:abc',
          evidenceToken: 'observation-proof',
          reconstructionEpochId: 'epoch-live-001',
          jobToNativeImageId: const {
            'job-a': 'native-image-shared',
            'job-b': 'native-image-shared',
          },
        ),
        throwsArgumentError,
      );
    });

    test(
      'completes only when every exact set matches and no blocker remains',
      () {
        var ledger = _attemptedLedger(
          'job-a',
        ).reduce(ManualCaptureEvent.accepted('job-a'));
        ledger = _advanceToRegistered(ledger, 'job-a');

        final complete = ledger.closureReport(
          finalRegistration: _finalObservation(const {'job-a'}),
        );

        expect(complete.expected, {'job-a'});
        expect(complete.committed, complete.expected);
        expect(complete.queued, complete.expected);
        expect(complete.ingested, complete.expected);
        expect(complete.registered, complete.expected);
        expect(complete.missing.values.expand((ids) => ids), isEmpty);
        expect(complete.extra.values.expand((ids) => ids), isEmpty);
        expect(complete.blockingJobIds, isEmpty);
        expect(complete.isComplete, isTrue);
      },
    );

    test('only a user tombstone removes an accepted job from expected', () {
      final accepted = _attemptedLedger(
        'job-a',
      ).reduce(ManualCaptureEvent.accepted('job-a'));
      final blocked = accepted.reduce(
        ManualCaptureEvent.blocked(
          'job-a',
          blockerId: 'blocker-disk-job-a',
          code: 'disk_full',
          message: 'Reservation cannot commit.',
        ),
      );

      expect(
        accepted
            .closureReport(finalRegistration: _finalObservation(const {}))
            .expected,
        {'job-a'},
      );
      expect(
        blocked
            .closureReport(finalRegistration: _finalObservation(const {}))
            .expected,
        {'job-a'},
      );

      final deleted = _requestQuiesceDelete(blocked, 'job-a');
      final deletedReport = deleted.closureReport(
        finalRegistration: _finalObservation(const {}),
      );
      expect(deletedReport.expected, isEmpty);
      expect(deletedReport.blockingJobIds, isEmpty);
      expect(deletedReport.isComplete, isTrue);
    });

    test('an unresolved attempted job blocks an otherwise empty closure', () {
      final report = _attemptedLedger(
        'job-a',
      ).closureReport(finalRegistration: _finalObservation(const {}));

      expect(report.expected, isEmpty);
      expect(report.blockingJobIds, {'job-a'});
      expect(report.isComplete, isFalse);
    });

    test(
      'ingested deletion requires exact rebuild evidence before closure',
      () {
        var ledger = _attemptedLedger('job-a')
            .reduce(
              ManualCaptureEvent.attempted(
                captureJobId: 'job-b',
                identityToken: 'identity-job-b',
              ),
            )
            .reduce(ManualCaptureEvent.accepted('job-a'))
            .reduce(ManualCaptureEvent.accepted('job-b'));
        ledger = _advanceToRegistered(ledger, 'job-a');
        ledger = _advanceToRegistered(ledger, 'job-b');
        ledger = _requestQuiesceDelete(ledger, 'job-a');

        expect(ledger.rebuildRequired, isTrue);
        expect(ledger.pendingRebuildDeletedJobIds, {'job-a'});
        final beforeRebuild = ledger.closureReport(
          finalRegistration: _finalObservation(const {
            'job-b',
          }, artifactIdentity: 'final-before-rebuild:sha256:aaa'),
        );
        expect(beforeRebuild.isComplete, isFalse);
        expect(beforeRebuild.blockingJobIds, contains('job-a'));
        final staleOutput = ledger.closureReport(
          finalRegistration: _finalObservation(const {
            'job-a',
            'job-b',
          }, artifactIdentity: 'stale-final:sha256:bbb'),
        );
        expect(staleOutput.extra['registered'], {'job-a'});

        expect(
          () => ledger.reduce(
            ManualCaptureEvent.reconstructionRebuilt(
              reconstructionEpochId: 'epoch-rebuild-001',
              artifactIdentity: 'final-after-delete:sha256:ccc',
              evidenceToken: 'rebuild-proof-001',
              jobToNativeImageId: const {
                'job-a': 'native-image-job-a',
                'job-b': 'native-image-job-b',
              },
            ),
          ),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );

        final rebuilt = ledger.reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-rebuild-001',
            artifactIdentity: 'final-after-delete:sha256:ccc',
            evidenceToken: 'rebuild-proof-001',
            jobToNativeImageId: const {'job-b': 'native-image-rebuilt-job-b'},
          ),
        );
        expect(rebuilt.rebuildRequired, isFalse);
        expect(rebuilt.pendingRebuildDeletedJobIds, isEmpty);
        expect(rebuilt.currentReconstructionEpochId, 'epoch-rebuild-001');
        expect(rebuilt.currentJobToNativeImageId, {
          'job-b': 'native-image-rebuilt-job-b',
        });
        expect(
          rebuilt.job('job-b')!.registrationMapping!.reconstructionEpochId,
          'epoch-rebuild-001',
        );
        expect(
          rebuilt.job('job-b')!.registrationMapping!.nativeImageId,
          'native-image-rebuilt-job-b',
        );
        expect(
          () => rebuilt.reduce(
            ManualCaptureEvent.registered(
              'job-b',
              reconstructionEpochId: 'epoch-live-001',
              nativeImageId: 'native-image-job-b',
              mappingEvidenceToken: 'mapping-proof-job-b',
            ),
          ),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );
        expect(
          rebuilt
              .closureReport(
                finalRegistration: _finalObservation(
                  const {'job-b'},
                  artifactIdentity: 'different-artifact:sha256:ddd',
                  reconstructionEpochId: 'epoch-rebuild-001',
                  jobToNativeImageId: const {
                    'job-b': 'native-image-rebuilt-job-b',
                  },
                ),
              )
              .isComplete,
          isFalse,
        );
        final stalePreRebuildMapping = rebuilt.closureReport(
          finalRegistration: _finalObservation(
            const {'job-b'},
            artifactIdentity: 'final-after-delete:sha256:ccc',
            reconstructionEpochId: 'epoch-rebuild-001',
            jobToNativeImageId: const {'job-b': 'native-image-job-b'},
          ),
        );
        expect(
          stalePreRebuildMapping.finalRegistrationMappingMatchesCurrentEpoch,
          isFalse,
        );
        expect(stalePreRebuildMapping.isComplete, isFalse);
        final complete = rebuilt.closureReport(
          finalRegistration: _finalObservation(
            const {'job-b'},
            artifactIdentity: 'final-after-delete:sha256:ccc',
            reconstructionEpochId: 'epoch-rebuild-001',
            jobToNativeImageId: const {'job-b': 'native-image-rebuilt-job-b'},
          ),
        );
        expect(complete.isComplete, isTrue);
        expect(complete.finalRegistrationArtifactMatchesRebuild, isTrue);
      },
    );

    test('one rebuild covers current pending deletions but not later ones', () {
      var ledger = const ManualCaptureLedger.empty();
      for (final jobId in const ['job-a', 'job-b', 'job-c']) {
        ledger = ledger
            .reduce(
              ManualCaptureEvent.attempted(
                captureJobId: jobId,
                identityToken: 'identity-$jobId',
              ),
            )
            .reduce(ManualCaptureEvent.accepted(jobId));
        ledger = _advanceToRegistered(ledger, jobId);
      }
      ledger = _requestQuiesceDelete(ledger, 'job-a');
      ledger = _requestQuiesceDelete(ledger, 'job-b');
      expect(ledger.pendingRebuildDeletedJobIds, {'job-a', 'job-b'});

      ledger = ledger.reduce(
        ManualCaptureEvent.reconstructionRebuilt(
          reconstructionEpochId: 'epoch-rebuild-ab',
          artifactIdentity: 'final-only-c:sha256:abc',
          evidenceToken: 'rebuild-proof-ab',
          jobToNativeImageId: const {'job-c': 'native-image-job-c'},
        ),
      );
      expect(ledger.rebuildRequired, isFalse);

      ledger = _requestQuiesceDelete(ledger, 'job-c');
      expect(ledger.rebuildRequired, isTrue);
      expect(ledger.pendingRebuildDeletedJobIds, {'job-c'});
    });

    test('ambiguous pre-ingest result taints until exact clean replay', () {
      var ledger = _attemptedLedger(
        'job-a',
      ).reduce(ManualCaptureEvent.accepted('job-a'));
      ledger = ledger
          .reduce(ManualCaptureEvent.photoCommitted('job-a'))
          .reduce(ManualCaptureEvent.sfmQueued('job-a'));
      final taint = ManualCaptureEvent.reconstructionTainted(
        'job-a',
        taintId: 'taint-native-ingest-001',
        reasonCode: 'native_add_frame_ambiguous',
        evidenceToken: 'native-error-receipt:sha256:abc',
      );
      final tainted = ledger.reduce(taint);

      expect(tainted.job('job-a')!.sfmIngested, isFalse);
      expect(tainted.reconstructionTainted, isTrue);
      expect(tainted.activeReconstructionTaints.keys, {
        'taint-native-ingest-001',
      });
      expect(tainted.rebuildRequired, isTrue);
      final blocked = tainted.closureReport(
        finalRegistration: _finalObservation(const {}),
      );
      expect(blocked.isComplete, isFalse);
      expect(blocked.blockingJobIds, contains('job-a'));

      expect(
        () => tainted.reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-clean-replay-001',
            artifactIdentity: 'clean-final:sha256:def',
            evidenceToken: 'clean-replay-proof:sha256:def',
            jobToNativeImageId: const {},
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );

      final rebuilt = tainted.reduce(
        ManualCaptureEvent.reconstructionRebuilt(
          reconstructionEpochId: 'epoch-clean-replay-001',
          artifactIdentity: 'clean-final:sha256:def',
          evidenceToken: 'clean-replay-proof:sha256:def',
          jobToNativeImageId: const {'job-a': 'native-clean-job-a'},
        ),
      );
      expect(rebuilt.reconstructionTainted, isFalse);
      expect(rebuilt.activeReconstructionTaints, isEmpty);
      expect(rebuilt.resolvedReconstructionTaints.keys, {
        'taint-native-ingest-001',
      });
      expect(rebuilt.job('job-a')!.registered, isTrue);
      expect(identical(rebuilt.reduce(taint), rebuilt), isTrue);
      expect(
        () => rebuilt.reduce(
          ManualCaptureEvent.reconstructionTainted(
            'job-a',
            taintId: 'taint-native-ingest-001',
            reasonCode: 'native_add_frame_ambiguous',
            evidenceToken: 'conflicting-error-receipt',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );

      final complete = rebuilt.closureReport(
        finalRegistration: _finalObservation(
          const {'job-a'},
          artifactIdentity: 'clean-final:sha256:def',
          reconstructionEpochId: 'epoch-clean-replay-001',
          jobToNativeImageId: const {'job-a': 'native-clean-job-a'},
        ),
      );
      expect(complete.isComplete, isTrue);
    });

    test(
      'ambiguous native ingest taints the whole session through deletion',
      () {
        var ledger = const ManualCaptureLedger.empty();
        for (final jobId in const ['job-a', 'job-b']) {
          ledger = ledger
              .reduce(
                ManualCaptureEvent.attempted(
                  captureJobId: jobId,
                  identityToken: 'identity-$jobId',
                ),
              )
              .reduce(ManualCaptureEvent.accepted(jobId))
              .reduce(ManualCaptureEvent.photoCommitted(jobId))
              .reduce(ManualCaptureEvent.sfmQueued(jobId));
        }

        final tainted = ledger.reduce(
          ManualCaptureEvent.nativeIngestAmbiguous(
            'job-a',
            taintId: 'taint-partial-native-write-001',
            reasonCode: 'native_add_frame_internal_error',
            evidenceToken: 'native-error-receipt:sha256:aaa',
          ),
        );

        expect(tainted.reconstructionTainted, isTrue);
        expect(
          () => tainted.reduce(ManualCaptureEvent.sfmIngested('job-a')),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );
        expect(
          () => tainted.reduce(ManualCaptureEvent.sfmIngested('job-b')),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );

        final blockerResolved = tainted
            .reduce(
              ManualCaptureEvent.blocked(
                'job-a',
                blockerId: 'blocker-native-error-001',
                code: 'native_add_frame_internal_error',
                message: 'Native ingestion may have partially mutated state.',
              ),
            )
            .reduce(
              ManualCaptureEvent.blockerResolved(
                'job-a',
                blockerId: 'blocker-native-error-001',
                resolutionEvidence: 'operator-acknowledged-error',
              ),
            );
        expect(blockerResolved.reconstructionTainted, isTrue);

        final deleted = _requestQuiesceDelete(blockerResolved, 'job-a');
        expect(deleted.reconstructionTainted, isTrue);
        expect(deleted.rebuildRequired, isTrue);
        expect(
          deleted
              .closureReport(finalRegistration: _finalObservation(const {}))
              .blockingJobIds,
          contains('job-a'),
        );
        expect(
          () => deleted.reduce(
            ManualCaptureEvent.reconstructionRebuilt(
              reconstructionEpochId: 'epoch-clean-after-ambiguous-001',
              artifactIdentity: 'clean-final:sha256:bbb',
              evidenceToken: 'clean-replay-proof:sha256:bbb',
              jobToNativeImageId: const {},
            ),
          ),
          throwsA(isA<ManualCaptureLedgerViolation>()),
        );

        final rebuilt = deleted.reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-clean-after-ambiguous-001',
            artifactIdentity: 'clean-final:sha256:bbb',
            evidenceToken: 'clean-replay-proof:sha256:bbb',
            jobToNativeImageId: const {'job-b': 'native-clean-job-b'},
          ),
        );
        expect(rebuilt.reconstructionTainted, isFalse);
        expect(rebuilt.currentJobToNativeImageId, {
          'job-b': 'native-clean-job-b',
        });
        expect(
          rebuilt
              .closureReport(
                finalRegistration: _finalObservation(
                  const {'job-b'},
                  artifactIdentity: 'clean-final:sha256:bbb',
                  reconstructionEpochId: 'epoch-clean-after-ambiguous-001',
                  jobToNativeImageId: const {'job-b': 'native-clean-job-b'},
                ),
              )
              .isComplete,
          isTrue,
        );
      },
    );

    test('ambiguous native ingest is recorded only before sfm_ingested', () {
      var ledger = _attemptedLedger(
        'job-a',
      ).reduce(ManualCaptureEvent.accepted('job-a'));
      ledger = ledger
          .reduce(ManualCaptureEvent.photoCommitted('job-a'))
          .reduce(ManualCaptureEvent.sfmQueued('job-a'))
          .reduce(ManualCaptureEvent.sfmIngested('job-a'));

      expect(
        () => ledger.reduce(
          ManualCaptureEvent.nativeIngestAmbiguous(
            'job-a',
            taintId: 'taint-too-late-001',
            reasonCode: 'native_add_frame_internal_error',
            evidenceToken: 'native-error-receipt:sha256:late',
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });
  });

  group('ManualCaptureLedger canonical JSON', () {
    test('serializes events with canonical key ordering', () {
      final event = ManualCaptureEvent.attempted(
        captureJobId: 'job-b',
        identityToken: 'identity-b',
      );

      expect(
        event.toCanonicalJson(),
        '{"capture_job_id":"job-b","event":"attempted",'
        '"identity_token":"identity-b","schema_version":1}',
      );
      expect(jsonDecode(event.toCanonicalJson()), event.toJson());
    });

    test('serializes blocker resolution evidence canonically', () {
      final event = ManualCaptureEvent.blockerResolved(
        'job-001',
        blockerId: 'blocker-disk-001',
        resolutionEvidence: 'free-space-check:sha256:abc',
      );

      expect(
        event.toCanonicalJson(),
        '{"blocker_id":"blocker-disk-001","capture_job_id":"job-001",'
        '"event":"blocker_resolved",'
        '"resolution_evidence":"free-space-check:sha256:abc",'
        '"schema_version":1}',
      );
    });

    test('sorts exact rebuild IDs in canonical event JSON', () {
      final event = ManualCaptureEvent.reconstructionRebuilt(
        reconstructionEpochId: 'epoch-rebuild-001',
        artifactIdentity: 'rebuilt-final:sha256:abc',
        evidenceToken: 'rebuild-proof-001',
        jobToNativeImageId: const {
          'job-z': 'native-image-z',
          'job-a': 'native-image-a',
        },
      );

      expect(
        event.toCanonicalJson(),
        '{"artifact_identity":"rebuilt-final:sha256:abc",'
        '"event":"reconstruction_rebuilt",'
        '"evidence_token":"rebuild-proof-001",'
        '"job_to_native_image_id":{"job-a":"native-image-a",'
        '"job-z":"native-image-z"},'
        '"reconstruction_epoch_id":"epoch-rebuild-001",'
        '"schema_version":1}',
      );
    });

    test('serializes snapshots independently of insertion order', () {
      final aThenB = _attemptedLedger('job-a').reduce(
        ManualCaptureEvent.attempted(
          captureJobId: 'job-b',
          identityToken: 'identity-job-b',
        ),
      );
      final bThenA = _attemptedLedger('job-b').reduce(
        ManualCaptureEvent.attempted(
          captureJobId: 'job-a',
          identityToken: 'identity-job-a',
        ),
      );

      expect(aThenB.toCanonicalJson(), bThenA.toCanonicalJson());
      final decoded =
          jsonDecode(aThenB.toCanonicalJson()) as Map<String, Object?>;
      final jobs = decoded['jobs']! as List<Object?>;
      expect((jobs.first! as Map<String, Object?>)['capture_job_id'], 'job-a');
    });
  });

  group('ManualCaptureLedger input normalization', () {
    test('rejects whitespace edges and control bytes in IDs and tokens', () {
      for (final invalid in <String>[
        '',
        ' job-001',
        'job-001 ',
        '\tjob-001',
        'job\n001',
        'job\r001',
        'job\u0000001',
      ]) {
        expect(
          () => ManualCaptureEvent.attempted(
            captureJobId: invalid,
            identityToken: 'identity-001',
          ),
          throwsArgumentError,
          reason: 'capture_job_id=$invalid',
        );
      }

      for (final invalid in <String>[
        '',
        ' identity',
        'identity ',
        'identity\nsecond-line',
        'identity\rsecond-line',
        'identity\u0000suffix',
      ]) {
        expect(
          () => ManualCaptureEvent.attempted(
            captureJobId: 'job-001',
            identityToken: invalid,
          ),
          throwsArgumentError,
          reason: 'identity_token=$invalid',
        );
      }
    });

    test('rejects non-normalized blocker codes', () {
      for (final invalid in <String>[
        '',
        ' disk_full',
        'disk_full ',
        'disk\nfull',
        'disk\rfull',
        'disk\u0000full',
      ]) {
        expect(
          () => ManualCaptureEvent.blocked(
            'job-001',
            blockerId: 'blocker-normalization-001',
            code: invalid,
            message: 'Evidence message.',
          ),
          throwsArgumentError,
          reason: 'blocker_code=$invalid',
        );
      }
    });

    test('rejects non-normalized blocker occurrence IDs', () {
      for (final invalid in <String>[
        '',
        ' blocker-001',
        'blocker-001 ',
        'blocker\n001',
        'blocker\r001',
        'blocker\u0000001',
      ]) {
        expect(
          () => ManualCaptureEvent.blocked(
            'job-001',
            blockerId: invalid,
            code: 'disk_full',
            message: 'Evidence message.',
          ),
          throwsArgumentError,
          reason: 'blocker_id=$invalid',
        );
      }
    });

    test('rejects non-normalized registration mapping evidence', () {
      for (final invalid in <String>['', ' native-image', 'native\nimage']) {
        expect(
          () => ManualCaptureEvent.registered(
            'job-001',
            reconstructionEpochId: 'epoch-live-001',
            nativeImageId: invalid,
            mappingEvidenceToken: 'mapping-proof',
          ),
          throwsArgumentError,
          reason: 'native_image_id=$invalid',
        );
      }
      expect(
        () => ManualCaptureEvent.registered(
          'job-001',
          reconstructionEpochId: 'epoch-live-001',
          nativeImageId: 'native-image-001',
          mappingEvidenceToken: 'mapping-proof ',
        ),
        throwsArgumentError,
      );
    });

    test('allows ordinary message newlines but rejects NUL', () {
      expect(
        ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-message-001',
          code: 'disk_full',
          message: 'Line one.\nLine two.',
        ),
        isA<ManualCaptureEvent>(),
      );
      expect(
        () => ManualCaptureEvent.blocked(
          'job-001',
          blockerId: 'blocker-message-002',
          code: 'disk_full',
          message: 'Before\u0000after',
        ),
        throwsArgumentError,
      );
    });

    test('requires non-empty NUL-free resolution evidence', () {
      for (final invalid in <String>['', '   ', '\n', 'proof\u0000suffix']) {
        expect(
          () => ManualCaptureEvent.blockerResolved(
            'job-001',
            blockerId: 'blocker-disk-001',
            resolutionEvidence: invalid,
          ),
          throwsArgumentError,
          reason: 'resolution_evidence=$invalid',
        );
      }
      expect(
        ManualCaptureEvent.blockerResolved(
          'job-001',
          blockerId: 'blocker-disk-001',
          resolutionEvidence: 'retry receipt\nsha256:abc',
        ),
        isA<ManualCaptureEvent>(),
      );
    });
  });
}

ManualCaptureLedger _attemptedLedger(String jobId) {
  return const ManualCaptureLedger.empty().reduce(
    ManualCaptureEvent.attempted(
      captureJobId: jobId,
      identityToken: 'identity-$jobId',
    ),
  );
}

ManualCaptureLedger _advanceToRegistered(
  ManualCaptureLedger ledger,
  String jobId,
) {
  var current = ledger;
  final job = current.job(jobId)!;
  if (!job.photoCommitted) {
    current = current.reduce(ManualCaptureEvent.photoCommitted(jobId));
  }
  if (!current.job(jobId)!.sfmQueued) {
    current = current.reduce(ManualCaptureEvent.sfmQueued(jobId));
  }
  if (!current.job(jobId)!.sfmIngested) {
    current = current.reduce(ManualCaptureEvent.sfmIngested(jobId));
  }
  if (!current.job(jobId)!.registered) {
    current = current.reduce(_registeredEvent(jobId));
  }
  return current;
}

ManualCaptureEvent _registeredEvent(String jobId) {
  return ManualCaptureEvent.registered(
    jobId,
    reconstructionEpochId: 'epoch-live-001',
    nativeImageId: 'native-image-$jobId',
    mappingEvidenceToken: 'mapping-proof-$jobId',
  );
}

FinalRegistrationObservation _finalObservation(
  Set<String> registeredJobIds, {
  String artifactIdentity = 'final-ply:sha256:0123456789abcdef',
  String reconstructionEpochId = 'epoch-live-001',
  Map<String, String>? jobToNativeImageId,
}) {
  return FinalRegistrationObservation(
    artifactIdentity: artifactIdentity,
    evidenceToken: 'final-observation-proof:sha256:0123456789abcdef',
    reconstructionEpochId: reconstructionEpochId,
    jobToNativeImageId:
        jobToNativeImageId ??
        <String, String>{
          for (final jobId in registeredJobIds) jobId: 'native-image-$jobId',
        },
  );
}

ManualCaptureLedger _requestQuiesceDelete(
  ManualCaptureLedger ledger,
  String jobId,
) {
  return ledger
      .reduce(ManualCaptureEvent.userDeletionRequested(jobId))
      .reduce(
        ManualCaptureEvent.writersQuiesced(
          jobId,
          evidenceToken: 'writers-quiesced-proof-$jobId',
        ),
      )
      .reduce(ManualCaptureEvent.userDeleted(jobId));
}
