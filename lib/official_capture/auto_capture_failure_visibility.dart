import 'official_highres_reconstruction_input.dart';

/// Every automatic transaction is an internal candidate until its 12 MP still
/// receives its ordered project/session commit receipt. A failed candidate is
/// telemetry, never a failed
/// user task or a reason to interrupt the viewfinder. Manual shutter failures
/// remain user-visible at the call site.
///
/// The rule holds for every case, and 2026-08-31 tested it rather than bending
/// it. A user-facing retraction — a distinct haptic for a shutter that was felt
/// but produced no photo — was written that day and removed the same day. It
/// would have been an exception to this rule wearing a different name, and it
/// failed on its own merits too: the user is not counting shutters, has no
/// action to take, and auto-capture already recovers unaided.
///
/// What survives is a telemetry line, `photo_feedback_retracted`, in
/// `OfficialAetherARKitPlugin.failPhotoFeedbackTransaction`. That is the
/// correct reading of ROS REP-117 — an erroneous measurement is propagated as
/// an explicit invalid marker so the CONSUMER can tell absence from
/// non-attempt, and the consumer here is our own log, not a person.
///
/// Frequency is why the question stopped being interesting: this rule was
/// written when the dominant automatic failure was a duplicate verdict, 22 of
/// 120 captures on 2026-08-30, so ~18% of shutters could show a card that
/// appeared and vanished. Since 2026-08-31 a duplicate verdict no longer
/// discards its photo at all, and what remains is a malformed camera, twice in
/// 1,230 captures.
bool automaticShutterFailureIsUserVisible(
  OfficialHighResInputFailure failure,
) => false;
