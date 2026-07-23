import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/reconstruction_lease.dart';

void main() {
  group('ReconstructionLease lifecycle', () {
    test('rejects a cross-route owner while self reconstruction is active', () {
      final lease = ReconstructionLease();
      final selfOwner = Object();
      final officialOwner = Object();

      lease.acquire(
        owner: selfOwner,
        pipeline: ReconstructionPipeline.selfDeveloped,
      );

      expect(
        () => lease.acquire(
          owner: officialOwner,
          pipeline: ReconstructionPipeline.official,
        ),
        throwsA(
          isA<ReconstructionLeaseBusyException>()
              .having(
                (error) => error.activePipeline,
                'activePipeline',
                ReconstructionPipeline.selfDeveloped,
              )
              .having(
                (error) => error.requestedPipeline,
                'requestedPipeline',
                ReconstructionPipeline.official,
              ),
        ),
      );
    });

    test('rejects a second instance even when it uses the same route', () {
      final lease = ReconstructionLease();
      final first = Object();
      final second = Object();

      lease.acquire(
        owner: first,
        pipeline: ReconstructionPipeline.selfDeveloped,
      );

      expect(
        () => lease.acquire(
          owner: second,
          pipeline: ReconstructionPipeline.selfDeveloped,
        ),
        throwsA(isA<ReconstructionLeaseBusyException>()),
      );
    });

    test('same-owner acquire is idempotent and stale release is ignored', () {
      final lease = ReconstructionLease();
      final owner = Object();
      final staleOwner = Object();

      lease.acquire(owner: owner, pipeline: ReconstructionPipeline.official);
      lease.acquire(owner: owner, pipeline: ReconstructionPipeline.official);

      expect(lease.release(staleOwner), isFalse);
      expect(lease.activePipeline, ReconstructionPipeline.official);
      expect(lease.release(owner), isTrue);
      expect(lease.activePipeline, isNull);
    });

    test('failed-start release is safe and makes the lease reusable', () {
      final lease = ReconstructionLease();
      final failedOwner = Object();
      final nextOwner = Object();

      lease.acquire(
        owner: failedOwner,
        pipeline: ReconstructionPipeline.selfDeveloped,
      );
      expect(lease.release(failedOwner), isTrue);
      expect(lease.release(failedOwner), isFalse);

      lease.acquire(
        owner: nextOwner,
        pipeline: ReconstructionPipeline.official,
      );
      expect(lease.activePipeline, ReconstructionPipeline.official);
    });

    test('an owner cannot change route through idempotent acquisition', () {
      final lease = ReconstructionLease();
      final owner = Object();

      lease.acquire(
        owner: owner,
        pipeline: ReconstructionPipeline.selfDeveloped,
      );

      expect(
        () => lease.acquire(
          owner: owner,
          pipeline: ReconstructionPipeline.official,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
