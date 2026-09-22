import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/reconstruction_draft_route_state.dart';

void main() {
  test('only terminal reconstruction shown behind Drafts auto-exits', () {
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: true,
        recordActionInProgress: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: true,
        recordActionInProgress: true,
      ),
      isFalse,
      reason: 'a rename/delete sheet must keep its owning Drafts tree mounted',
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: false,
        recordActionInProgress: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: false,
        reconstructionTerminal: true,
        recordActionInProgress: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: false,
        reconstructionTerminal: false,
        recordActionInProgress: false,
      ),
      isFalse,
    );
  });
}
