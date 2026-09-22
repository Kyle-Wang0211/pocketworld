import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/sfm_resume_wait_page.dart';

void main() {
  testWidgets('normal resume preserves the non-regenerate fast path', (
    tester,
  ) async {
    final call = Completer<({String dir, bool force})>();
    final result = Completer<bool>();

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          captureDir: '/tmp/cap-normal',
          title: 'normal',
          resumeForTesting: (dir, {forceRegenerate = false}) {
            call.complete((dir: dir, force: forceRegenerate));
            return result.future;
          },
        ),
      ),
    );

    expect(await call.future, (dir: '/tmp/cap-normal', force: false));
    result.complete(false);
    await tester.pump();
  });

  testWidgets('explicit rebuild forwards forceRegenerate exactly once', (
    tester,
  ) async {
    final calls = <({String dir, bool force})>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          captureDir: '/tmp/cap-rebuild',
          title: 'rebuild',
          forceRegenerate: true,
          resumeForTesting: (dir, {forceRegenerate = false}) async {
            calls.add((dir: dir, force: forceRegenerate));
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(calls, <({String dir, bool force})>[
      (dir: '/tmp/cap-rebuild', force: true),
    ]);
    expect(find.text('重建完成'), findsOneWidget);
  });

  testWidgets('same capture re-entry attaches to forced resume future', (
    tester,
  ) async {
    final result = Completer<bool>();
    var firstStarts = 0;
    var reentryStarts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('first'),
          captureDir: '/old/container/cap-reentry',
          title: 'first',
          forceRegenerate: true,
          resumeForTesting: (dir, {forceRegenerate = false}) {
            firstStarts++;
            expect(forceRegenerate, isTrue);
            return result.future;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('reentry'),
          // Container UUID changed, capture identity did not.
          captureDir: '/new/container/cap-reentry',
          title: 'reentry',
          resumeForTesting: (dir, {forceRegenerate = false}) async {
            reentryStarts++;
            return false;
          },
        ),
      ),
    );
    await tester.pump();

    expect(firstStarts, 1);
    expect(reentryStarts, 0);
    expect(
      sfmResumeUiActivityFor('/any/container/cap-reentry'),
      SfmResumeUiActivity.sameCapture,
    );

    result.complete(true);
    await tester.pump();
    expect(find.text('重建完成'), findsOneWidget);
    expect(
      sfmResumeUiActivityFor('/any/container/cap-reentry'),
      SfmResumeUiActivity.none,
    );
  });

  testWidgets('active capture A refuses capture B without backend start', (
    tester,
  ) async {
    final resultA = Completer<bool>();
    var startsA = 0;
    var startsB = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('capture-a'),
          captureDir: '/tmp/cap-a',
          title: 'A',
          resumeForTesting: (dir, {forceRegenerate = false}) {
            startsA++;
            return resultA.future;
          },
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('capture-b'),
          captureDir: '/tmp/cap-b',
          title: 'B',
          resumeForTesting: (dir, {forceRegenerate = false}) async {
            startsB++;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(startsA, 1);
    expect(startsB, 0);
    expect(find.text('另一项重建正在进行'), findsOneWidget);
    expect(find.textContaining('未启动第二个重建任务'), findsOneWidget);

    resultA.complete(false);
    await tester.pump();
  });

  testWidgets('attach-only snapshot survives success before route build', (
    tester,
  ) async {
    final result = Completer<bool>();
    var starts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('snapshot-source-success'),
          captureDir: '/tmp/cap-snapshot-success',
          title: 'source',
          forceRegenerate: true,
          resumeForTesting: (dir, {forceRegenerate = false}) {
            starts++;
            return result.future;
          },
        ),
      ),
    );
    await tester.pump();
    final snapshot = activeSfmResumeSnapshotFor(
      '/migrated/cap-snapshot-success',
    )!;
    expect(snapshot.forceRegenerate, isTrue);

    // The backend completes and clears the global slot before Navigator's
    // route builder constructs the re-entry page.
    result.complete(true);
    await tester.pump();
    expect(
      sfmResumeUiActivityFor('/tmp/cap-snapshot-success'),
      SfmResumeUiActivity.none,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('snapshot-attach-success'),
          captureDir: snapshot.captureDir,
          title: 'attached',
          forceRegenerate: snapshot.forceRegenerate,
          attachedFuture: snapshot.future,
          attachOnly: true,
          resumeForTesting: (dir, {forceRegenerate = false}) async {
            starts++;
            return false;
          },
        ),
      ),
    );
    await tester.pump();

    expect(starts, 1);
    expect(find.text('重建完成'), findsOneWidget);
  });

  testWidgets('attach-only snapshot preserves failure without restart', (
    tester,
  ) async {
    final result = Completer<bool>();
    var starts = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('snapshot-source-failure'),
          captureDir: '/tmp/cap-snapshot-failure',
          title: 'source',
          resumeForTesting: (dir, {forceRegenerate = false}) {
            starts++;
            return result.future;
          },
        ),
      ),
    );
    await tester.pump();
    final snapshot = activeSfmResumeSnapshotFor('/tmp/cap-snapshot-failure')!;
    result.complete(false);
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: SfmResumeWaitPage(
          key: const ValueKey('snapshot-attach-failure'),
          captureDir: snapshot.captureDir,
          title: 'attached',
          attachedFuture: snapshot.future,
          attachOnly: true,
          resumeForTesting: (dir, {forceRegenerate = false}) async {
            starts++;
            return true;
          },
        ),
      ),
    );
    await tester.pump();

    expect(starts, 1);
    expect(find.textContaining('未能完成重建'), findsOneWidget);
  });
}
