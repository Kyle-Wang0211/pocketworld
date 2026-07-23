import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/live_sfm_publish_policy.dart';
import 'package:pocketworld_flutter/official_capture/sfm_feed_queue.dart';

void main() {
  test('official capture cannot finish before 20 accepted SfM frames', () {
    expect(officialCaptureCanFinish(acceptedFrameCount: 0), isFalse);
    expect(officialCaptureCanFinish(acceptedFrameCount: 19), isFalse);
    expect(officialCaptureCanFinish(acceptedFrameCount: 20), isTrue);
  });

  test('first stable cloud is published only after frame 20 global BA', () {
    final policy = OfficialLiveSfmPublishPolicy();

    expect(
      policy.shouldRunGlobalBa(registeredFrames: 19, pointCount: 9000),
      isFalse,
    );
    expect(
      policy.shouldRunGlobalBa(registeredFrames: 20, pointCount: 9000),
      isTrue,
    );

    policy.markGlobalBaPublished(registeredFrames: 20, pointCount: 9000);
    expect(policy.version, 1);
  });

  test(
    'official video cadence keeps V20 through frame 27 and advances at 28',
    () {
      final policy = OfficialLiveSfmPublishPolicy()
        ..markGlobalBaPublished(registeredFrames: 20, pointCount: 10000);

      for (var frames = 21; frames < 28; frames++) {
        expect(
          policy.shouldRunGlobalBa(registeredFrames: frames, pointCount: 13999),
          isFalse,
          reason: 'frame $frames must keep V20',
        );
      }
      expect(
        policy.shouldRunGlobalBa(registeredFrames: 28, pointCount: 13999),
        isTrue,
      );

      policy.markGlobalBaPublished(registeredFrames: 28, pointCount: 13999);
      expect(policy.version, 2);
    },
  );

  test(
    'later publish is triggered by frames or points growing forty percent',
    () {
      final byFrames = OfficialLiveSfmPublishPolicy()
        ..markGlobalBaPublished(registeredFrames: 28, pointCount: 10000);
      expect(
        byFrames.shouldRunGlobalBa(registeredFrames: 39, pointCount: 13999),
        isFalse,
      );
      expect(
        byFrames.shouldRunGlobalBa(registeredFrames: 40, pointCount: 13999),
        isTrue,
      );

      final byPoints = OfficialLiveSfmPublishPolicy()
        ..markGlobalBaPublished(registeredFrames: 28, pointCount: 10000);
      expect(
        byPoints.shouldRunGlobalBa(registeredFrames: 39, pointCount: 13999),
        isFalse,
      );
      expect(
        byPoints.shouldRunGlobalBa(registeredFrames: 39, pointCount: 14000),
        isTrue,
      );
    },
  );

  test('without an earlier point trigger, 1.40 camera growth lands at '
      '20, 28, 40, 56, and 79', () {
    final policy = OfficialLiveSfmPublishPolicy();
    const checkpoints = <int>[20, 28, 40, 56, 79];

    for (final checkpoint in checkpoints) {
      expect(
        policy.shouldRunGlobalBa(
          registeredFrames: checkpoint - 1,
          pointCount: 10000,
        ),
        isFalse,
        reason: 'must not publish before frame $checkpoint',
      );
      expect(
        policy.shouldRunGlobalBa(
          registeredFrames: checkpoint,
          pointCount: 10000,
        ),
        isTrue,
        reason: 'frame $checkpoint crosses the current 1.40 camera baseline',
      );
      policy.markGlobalBaPublished(
        registeredFrames: checkpoint,
        pointCount: 10000,
      );
    }
    expect(policy.version, checkpoints.length);
  });

  test('an early point-growth publish resets both 1.40 baselines', () {
    final policy = OfficialLiveSfmPublishPolicy()
      ..markGlobalBaPublished(registeredFrames: 20, pointCount: 10000);

    expect(
      policy.shouldRunGlobalBa(registeredFrames: 25, pointCount: 14000),
      isTrue,
    );
    policy.markGlobalBaPublished(registeredFrames: 25, pointCount: 14000);

    // There is no second frame-28 clock. The new camera threshold is 25*1.4=35
    // and the new point threshold is 14000*1.4=19600.
    expect(
      policy.shouldRunGlobalBa(registeredFrames: 28, pointCount: 15000),
      isFalse,
    );
    expect(
      policy.shouldRunGlobalBa(registeredFrames: 35, pointCount: 15000),
      isTrue,
    );
  });

  test('failed global BA is not committed and retries on the next update', () {
    final policy = OfficialLiveSfmPublishPolicy();

    expect(
      policy.shouldRunGlobalBa(registeredFrames: 20, pointCount: 8000),
      isTrue,
    );
    expect(
      policy.shouldRunGlobalBa(registeredFrames: 21, pointCount: 8200),
      isTrue,
    );
    expect(policy.version, 0);
  });

  test('finish waits for every queued and in-flight photo', () {
    expect(
      sfmFeedCanSendFinalize(
        finalizeRequested: true,
        finalizeSent: false,
        spoolDepth: 0,
        inFlight: 0,
      ),
      isTrue,
    );
    for (final busy in <({int spool, int inFlight})>[
      (spool: 1, inFlight: 0),
      (spool: 0, inFlight: 1),
    ]) {
      expect(
        sfmFeedCanSendFinalize(
          finalizeRequested: true,
          finalizeSent: false,
          spoolDepth: busy.spool,
          inFlight: busy.inFlight,
        ),
        isFalse,
      );
    }
  });
}
