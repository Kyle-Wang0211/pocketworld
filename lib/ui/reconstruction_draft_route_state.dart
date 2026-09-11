/// True only when a terminal reconstruction is still presenting the temporary
/// Drafts surface. That route must be released so the real Drafts root—and its
/// fully enabled capture action—becomes visible.
bool shouldAutoExitReconstructionDrafts({
  required bool showingDrafts,
  required bool reconstructionTerminal,
  required bool recordActionInProgress,
}) {
  return showingDrafts && reconstructionTerminal && !recordActionInProgress;
}
