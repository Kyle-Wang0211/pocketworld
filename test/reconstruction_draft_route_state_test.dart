import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/reconstruction_draft_route_state.dart';

void main() {
  test('only terminal reconstruction shown behind Drafts auto-exits', () {
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: true,
      ),
      isTrue,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: true,
        reconstructionTerminal: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: false,
        reconstructionTerminal: true,
      ),
      isFalse,
    );
    expect(
      shouldAutoExitReconstructionDrafts(
        showingDrafts: false,
        reconstructionTerminal: false,
      ),
      isFalse,
    );
  });
}
