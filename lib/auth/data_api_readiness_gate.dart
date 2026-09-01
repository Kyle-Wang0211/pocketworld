import 'dart:async';

enum DataApiReadiness { unknown, checking, ready, failed }

/// Keeps authentication and PostgREST readiness as two separate facts.
///
/// Supabase may restore/refresh a valid session before PostgREST's clock has
/// reached the JWT `iat`. That short PGRST303 window is retried with the exact
/// same token; this gate never mints another JWT and never changes auth state.
class DataApiReadinessGate {
  DataApiReadinessGate({
    this.retryDelay = const Duration(milliseconds: 400),
    this.maxFutureIssuedRetries = 2,
  });

  final Duration retryDelay;
  final int maxFutureIssuedRetries;
  DataApiReadiness _state = DataApiReadiness.unknown;
  Future<void>? _transientWait;

  DataApiReadiness get state => _state;

  void reset() {
    _state = DataApiReadiness.unknown;
    _transientWait = null;
  }

  static bool isFutureIssuedJwt(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('pgrst303') &&
        (text.contains('jwt issued at future') ||
            text.contains('issued in the future'));
  }

  Future<T> run<T>(
    Future<T> Function() operation, {
    Future<void> Function()? onTokenRefresh,
  }) async {
    _state = DataApiReadiness.checking;
    for (var attempt = 0; ; attempt++) {
      try {
        final result = await operation();
        _state = DataApiReadiness.ready;
        return result;
      } catch (error) {
        if (!isFutureIssuedJwt(error) || attempt >= maxFutureIssuedRetries) {
          _state = DataApiReadiness.failed;
          rethrow;
        }
        // Coalesce simultaneous feed/profile requests into the same bounded
        // clock-skew wait. Intentionally do not invoke onTokenRefresh.
        final existing = _transientWait;
        if (existing != null) {
          await existing;
        } else {
          final wait = Future<void>.delayed(retryDelay);
          _transientWait = wait;
          await wait;
          if (identical(_transientWait, wait)) _transientWait = null;
        }
      }
    }
  }
}

final DataApiReadinessGate dataApiReadinessGate = DataApiReadinessGate();
