import 'dart:async';

enum ColdStartAuthEvent { tokenRefreshed, signedOut, other }

enum ColdStartSessionResult {
  noSession,
  validCachedSession,
  refreshedByRecovery,
  refreshedByFallback,
  signedOut,
}

/// Mirrors Supabase Flutter v2's documented startup contract.
///
/// `Supabase.initialize()` restores a cached session but deliberately does
/// not wait for a network refresh. A cached session that is still valid must
/// be used as-is; minting a fresh JWT on every cold start creates a race with
/// PostgREST's `iat` clock check. Only an actually expired session waits for
/// the SDK's recovery event, with one bounded official refresh as fallback.
Future<ColdStartSessionResult> waitForColdStartSession({
  required bool hasSession,
  required bool isExpired,
  required Stream<ColdStartAuthEvent> authEvents,
  required Future<void> Function() fallbackRefresh,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (!hasSession) return ColdStartSessionResult.noSession;
  if (!isExpired) return ColdStartSessionResult.validCachedSession;

  try {
    final event = await authEvents
        .firstWhere(
          (event) =>
              event == ColdStartAuthEvent.tokenRefreshed ||
              event == ColdStartAuthEvent.signedOut,
        )
        .timeout(timeout);
    return event == ColdStartAuthEvent.signedOut
        ? ColdStartSessionResult.signedOut
        : ColdStartSessionResult.refreshedByRecovery;
  } on TimeoutException {
    await fallbackRefresh();
    return ColdStartSessionResult.refreshedByFallback;
  } on StateError {
    // A closed event stream is equivalent to recovery producing no terminal
    // event. Production's auth stream stays open; this branch keeps the gate
    // deterministic for shutdown and tests.
    await fallbackRefresh();
    return ColdStartSessionResult.refreshedByFallback;
  }
}
