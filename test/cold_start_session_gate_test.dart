import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/auth/cold_start_session_gate.dart';

void main() {
  test('a valid restored session never mints a fresh JWT on cold start', () async {
    var fallbackRefreshCalls = 0;

    final result = await waitForColdStartSession(
      hasSession: true,
      isExpired: false,
      authEvents: const Stream<ColdStartAuthEvent>.empty(),
      timeout: const Duration(milliseconds: 1),
      fallbackRefresh: () async {
        fallbackRefreshCalls++;
      },
    );

    expect(result, ColdStartSessionResult.validCachedSession);
    expect(fallbackRefreshCalls, 0);
  });

  test('an expired session waits for the official token-refreshed event', () async {
    final events = StreamController<ColdStartAuthEvent>();
    var completed = false;
    var fallbackRefreshCalls = 0;

    final pending = waitForColdStartSession(
      hasSession: true,
      isExpired: true,
      authEvents: events.stream,
      timeout: const Duration(seconds: 1),
      fallbackRefresh: () async {
        fallbackRefreshCalls++;
      },
    ).then((value) {
      completed = true;
      return value;
    });

    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    events.add(ColdStartAuthEvent.tokenRefreshed);

    expect(await pending, ColdStartSessionResult.refreshedByRecovery);
    expect(fallbackRefreshCalls, 0);
    await events.close();
  });

  test('an expired-session recovery timeout uses one bounded official refresh',
      () async {
    var fallbackRefreshCalls = 0;

    final result = await waitForColdStartSession(
      hasSession: true,
      isExpired: true,
      authEvents: const Stream<ColdStartAuthEvent>.empty(),
      timeout: const Duration(milliseconds: 1),
      fallbackRefresh: () async {
        fallbackRefreshCalls++;
      },
    );

    expect(result, ColdStartSessionResult.refreshedByFallback);
    expect(fallbackRefreshCalls, 1);
  });
}
