// gRPC 连接退避协议 / kratos DefaultBackoffConfig 的逐值对拍。
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/auth/connection_backoff.dart';

void main() {
  test('defaults are gRPC / kratos values', () {
    final b = ConnectionBackoff();
    expect(b.initial, const Duration(seconds: 1));
    expect(b.multiplier, 1.6);
    expect(b.jitter, 0.2);
    expect(b.max, const Duration(seconds: 120));
  });

  test('sequence without jitter: 1, 1.6, 2.56, 4.096 … capped at 120 s', () {
    final b = ConnectionBackoff(jitter: 0);
    final ms = List.generate(14, (_) => b.next().inMilliseconds);
    expect(ms.sublist(0, 5), [1000, 1600, 2560, 4096, 6553]); // 6553.6 截断
    // 1.6^11 ≈ 175.9 > 120 ⇒ 第 12 次起封顶。
    expect(ms[10], 109951);
    expect(ms[11], 120000);
    expect(ms[13], 120000);
    expect(b.failures, 14);
    b.reset();
    expect(b.failures, 0);
    expect(b.next(), const Duration(seconds: 1));
  });

  test('jitter stays within ±20% and never applies to the first delay', () {
    final b = ConnectionBackoff(random: Random(7));
    expect(b.delayFor(0), const Duration(seconds: 1));
    for (var r = 1; r < 40; r++) {
      final nominal = min(1e6 * pow(1.6, r), 120e6);
      final d = b.delayFor(r).inMicroseconds;
      expect(d, greaterThanOrEqualTo((nominal * 0.8).floor() - 1));
      expect(d, lessThanOrEqualTo((nominal * 1.2).ceil() + 1));
    }
  });
}
