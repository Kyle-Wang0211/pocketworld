# Draft Capture FAB Lifecycle Design

**Date:** 2026-07-23

**Scope:** PocketWorld Flutter UI; self-developed and official capture routes

**Non-goals:** No SfM/COLMAP/ARKit algorithm, quality threshold, scheduling, or performance-parameter changes

## Problem

`MeRootPage` always renders the bottom-right capture FAB, but a capture route
with a non-null reconstruction phase can replace its route body with a bare
`MePage`. That page looks like Drafts but does not contain the FAB. A terminal
reconstruction keeps `_sfmPhase` at `refined` or `error` until the completion
action runs, so a user who returned to Drafts can remain on this temporary page
even after reconstruction has finished.

## Accepted behavior contract

1. Any UI that looks like Drafts always shows the bottom-right `+` capture FAB.
2. While reconstruction is still running, the FAB remains visible. Tapping it
   shows “当前任务正在重建” and does not open the pipeline chooser or start a
   second capture.
3. When reconstruction reaches either terminal state (`refined` or `error`)
   while Drafts is visible, the capture route releases its worker/session and
   exits to the real `MeRootPage`. The normal FAB is then fully operational.
4. Apply the same behavior independently to the self-developed and official
   capture implementations.
5. Add regression coverage for the visible-but-blocked running state and the
   terminal auto-exit state.

## Architecture

### Shared Drafts shell

Extract the existing FAB presentation into a reusable public widget owned by
`me_root_page.dart`. `MeRootPage` continues to use it for normal capture.
Temporary Drafts rendered by either capture route wrap `MePage` in the same
stack and use the same visual FAB.

The temporary FAB callback is intentionally local to its owning capture route.
While `_sfmPhase == SfmPreviewPhase.generating`, it displays the in-progress
message and performs no navigation. This preserves the single-reconstruction
lease and leaves compute resources with the active reconstruction.

### Terminal transition

When a reconstruction event or colorization step changes `_sfmPhase` to
`refined` or `error`, and `_showDraftsWhileReconstructing` is true, schedule one
post-frame terminal cleanup. Reuse the existing `_onSfmPreviewDone()` cleanup
path rather than duplicating session disposal. That method clears `_sfmPhase`,
disposes the worker/subscriptions, and honors `_sfmPendingPop`, returning the
user to the real root Drafts page.

Post-frame scheduling avoids calling `Navigator.pop` from inside `setState` or
during widget build. A one-shot guard prevents duplicate completion callbacks
when multiple terminal signals arrive.

### Route independence

The self-developed capture route and official capture route each retain their
own state, callback, and terminal transition implementation. They share only
the stateless Drafts/FAB presentation widget; no capture session, ARKit channel,
SfM worker, or algorithm implementation is shared.

## State transitions

| Current state | User/event | Result |
|---|---|---|
| `generating`, reconstruction page | Back/edge swipe | Temporary Drafts with visible FAB |
| `generating`, temporary Drafts | Tap FAB | Show “当前任务正在重建”; no navigation |
| `generating`, temporary Drafts | Tap active task card | Return to reconstruction page |
| `generating`, temporary Drafts | Terminal success/failure | Run existing completion cleanup and pop to real Drafts |
| `refined`/`error`, reconstruction page | Tap Complete | Existing completion cleanup and pop to real Drafts |
| Real Drafts | Tap FAB | Existing self/official chooser |

## Testing

- A widget test for the reusable temporary Drafts shell verifies that the FAB
  is rendered and its blocked callback is invoked without opening capture.
- A pure state-transition helper test verifies that only
  `showDrafts && terminalPhase` requests automatic completion; generating and
  non-Drafts states do not.
- Existing overlay tests continue to verify that Back is available while
  generating and Complete appears only for terminal results.
- The official copy-contract test verifies that both capture routes contain
  their independent terminal-exit wiring.
- Run targeted Flutter tests, `flutter analyze` on changed files, then validate
  the exact sequence on device for both routes.

## Failure handling

- A terminal failure follows the same route-release behavior as terminal
  success; the captured draft remains persisted by the existing flow.
- If the widget is already unmounted, the scheduled completion is ignored.
- Repeated terminal events are idempotent and cannot double-pop the route.
