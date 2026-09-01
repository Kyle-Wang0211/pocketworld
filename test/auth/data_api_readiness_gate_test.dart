import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/auth/data_api_readiness_gate.dart';

void main() {
  test(
    'future-issued JWT is retried with the same token and becomes ready',
    () async {
      final gate = DataApiReadinessGate(retryDelay: Duration.zero);
      var calls = 0;
      var refreshCalls = 0;

      final value = await gate.run<String>(() async {
        calls++;
        if (calls == 1) throw Exception('PGRST303 JWT issued at future');
        return 'ok';
      }, onTokenRefresh: () async => refreshCalls++);

      expect(value, 'ok');
      expect(calls, 2);
      expect(refreshCalls, 0, reason: 'the same JWT must be retried');
      expect(gate.state, DataApiReadiness.ready);
    },
  );

  test(
    'fatal PostgREST errors pass through and auth events reset readiness',
    () async {
      final gate = DataApiReadinessGate(retryDelay: Duration.zero);
      await expectLater(
        gate.run<void>(() async => throw Exception('permission denied')),
        throwsA(isA<Exception>()),
      );
      expect(gate.state, DataApiReadiness.failed);
      gate.reset();
      expect(gate.state, DataApiReadiness.unknown);
    },
  );
}
