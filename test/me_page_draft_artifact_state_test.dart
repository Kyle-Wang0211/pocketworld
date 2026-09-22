import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_resume.dart';
import 'package:pocketworld_flutter/capture/sparse_ply.dart';
import 'package:pocketworld_flutter/me/draft_card_action.dart';
import 'package:pocketworld_flutter/ui/capture/sfm_resume_wait_page.dart';
import 'package:pocketworld_flutter/ui/me_page.dart';

const _dir = '/tmp/captures/cap_test';
const _refinedReceipt = SparsePersistReceipt(
  artifactId: 'artifact-refined',
  pointCount: 42,
  refined: true,
  plyBytes: 100,
  plySha256: 'ply',
  metaBytes: 50,
  metaSha256: 'meta',
);
const _localReceipt = SparsePersistReceipt(
  artifactId: 'artifact-local',
  pointCount: 42,
  refined: false,
  plyBytes: 100,
  plySha256: 'ply-local',
  metaBytes: 50,
  metaSha256: 'meta-local',
);

DraftCardAction _action({
  required SfmFinalArtifactRecoveryState finalState,
  required SparsePublicationViewInspection sparseView,
  required bool hasDb,
  bool hasReplayState = false,
  bool canExplicitlyResume = false,
}) => draftCardActionForVerifiedArtifact(
  recordCaptureDir: _dir,
  hasArtifact: false,
  finalArtifact: SfmFinalArtifactInspection(state: finalState),
  sparseView: sparseView,
  sfmDbExists: hasDb,
  hasReplayState: hasReplayState,
  canExplicitlyResume: canExplicitlyResume,
  activeReconstructionCaptureDir: null,
  hasActiveReconstructionCallback: false,
);

void main() {
  test(
    'per-card action guard rejects concurrent tap and long-press work',
    () async {
      final guard = DraftCardActionGuard();
      final entered = Completer<void>();
      final release = Completer<void>();
      var starts = 0;

      final tap = guard.run('cap-a', () async {
        starts++;
        entered.complete();
        await release.future;
      });
      await entered.future;
      expect(guard.isBusy('cap-a'), isTrue);

      final longPressAccepted = await guard.run('cap-a', () async {
        starts++;
      });
      expect(longPressAccepted, isFalse);
      expect(starts, 1);

      release.complete();
      expect(await tap, isTrue);
      expect(guard.isBusy('cap-a'), isFalse);
      expect(await guard.run('cap-a', () async {}), isTrue);
    },
  );

  test('active A blocks only B resume/rebuild, not completed safe actions', () {
    for (final safeAction in const <DraftCardAction>[
      DraftCardAction.openWorkDetail,
      DraftCardAction.openSparseCloud,
      DraftCardAction.none,
    ]) {
      expect(
        activeResumeBlocksDraftAction(
          activity: SfmResumeUiActivity.otherCapture,
          action: safeAction,
        ),
        isFalse,
        reason: safeAction.name,
      );
    }
    expect(
      activeResumeBlocksDraftAction(
        activity: SfmResumeUiActivity.otherCapture,
        action: DraftCardAction.offerResume,
      ),
      isTrue,
    );
    for (final safeAction in <String?>[
      'view_sparse',
      'rename',
      'delete',
      null,
    ]) {
      expect(
        activeResumeBlocksLongPressAction(
          activity: SfmResumeUiActivity.otherCapture,
          action: safeAction,
        ),
        isFalse,
        reason: '$safeAction',
      );
    }
    expect(
      activeResumeBlocksLongPressAction(
        activity: SfmResumeUiActivity.otherCapture,
        action: 'rebuild_sparse',
      ),
      isTrue,
    );
  });

  test('draft resume route preserves explicit regenerate intent', () {
    expect(
      sfmResumeWaitPageForDraft(
        captureDir: _dir,
        title: 'capture',
        regenerate: true,
      ).forceRegenerate,
      isTrue,
    );
    expect(
      sfmResumeWaitPageForDraft(
        captureDir: _dir,
        title: 'capture',
        regenerate: false,
      ).forceRegenerate,
      isFalse,
    );
  });

  test('complete refined receipt opens even while retained DB exists', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.complete,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.committed,
          receipt: _refinedReceipt,
          pointCount: 42,
        ),
        hasDb: true,
      ),
      DraftCardAction.openSparseCloud,
    );
  });

  test('partial or unverified PLY with DB enters rebuild, never viewer', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.invalid,
        ),
        hasDb: true,
      ),
      DraftCardAction.offerResume,
    );
  });

  test('prepared cleanup with DB enters commit resume, never viewer', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsDurableCommit,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.committed,
          receipt: _refinedReceipt,
          pointCount: 42,
        ),
        hasDb: true,
      ),
      DraftCardAction.offerResume,
    );
  });

  test('verified historical PLY-only with no DB remains viewable', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.legacyPlyOnly,
          pointCount: 42,
        ),
        hasDb: false,
      ),
      DraftCardAction.openSparseCloud,
    );
  });

  test('legacy PLY-only with retained replay state never opens', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.legacyPlyOnly,
          pointCount: 42,
        ),
        hasDb: false,
        hasReplayState: true,
      ),
      DraftCardAction.none,
    );
  });

  test('missing DB cannot make a partial or local-only artifact viewable', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.invalid,
        ),
        hasDb: false,
      ),
      DraftCardAction.none,
    );
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.committed,
          receipt: _localReceipt,
          pointCount: 42,
        ),
        hasDb: false,
      ),
      DraftCardAction.none,
    );
  });

  test('modern refined pair without exact final marker stays hidden', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsDurableCommit,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.committed,
          receipt: _refinedReceipt,
          pointCount: 42,
        ),
        hasDb: false,
      ),
      DraftCardAction.none,
    );
  });

  test('verified durable replay authorizes resume without a live DB', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.none,
        ),
        hasDb: false,
        hasReplayState: true,
        canExplicitlyResume: true,
      ),
      DraftCardAction.offerResume,
    );
  });

  test('bare gray or invalid replay evidence never authorizes resume', () {
    expect(
      _action(
        finalState: SfmFinalArtifactRecoveryState.needsRebuild,
        sparseView: const SparsePublicationViewInspection(
          state: SparsePublicationViewState.none,
        ),
        hasDb: false,
        // Durable state exists, so legacy viewing is also fail-closed, but its
        // evidence was not strong enough to reconstruct a frame.
        hasReplayState: true,
        canExplicitlyResume: false,
      ),
      DraftCardAction.none,
    );
  });
}
