// connection_backoff.dart — 抄 gRPC 连接退避协议,不自研。
//
// 来源(2026-09-07 用户令"不要自研,看大厂做法直接抄"):
//   * gRPC `doc/connection-backoff.md`:INITIAL_BACKOFF = 1 s、MULTIPLIER = 1.6、
//     JITTER = 0.2、MAX_BACKOFF = 120 s;连接被服务器接受后复位到 INITIAL_BACKOFF。
//   * B 站 kratos v1 `pkg/net/netutil/backoff.go` DefaultBackoffConfig 与之逐字相同
//     (MaxDelay 120 s / BaseDelay 1 s / Factor 1.6 / Jitter 0.2),计算式照抄它的
//     `Backoff(retries)`:retries==0 → BaseDelay;否则 base×factor^retries 封顶 max,
//     再乘 (1 + jitter×U(−1,1))。
//   * AWS 架构博客《Exponential Backoff And Jitter》:带抖动的退避应为远端客户端标配。
//
// 用途:登录后端初始化整体失败(不可用态)后的自动再试节奏。网络级重试由
// gotrue 自己做(200 ms×2^n,10 s 窗口),这里不重复。
import 'dart:math';

class ConnectionBackoff {
  ConnectionBackoff({
    this.initial = const Duration(seconds: 1),
    this.multiplier = 1.6,
    this.jitter = 0.2,
    this.max = const Duration(seconds: 120),
    Random? random,
  }) : _random = random ?? Random();

  final Duration initial;
  final double multiplier;
  final double jitter;
  final Duration max;
  final Random _random;

  int _failures = 0;

  /// 连续失败次数(成功后复位为 0)。
  int get failures => _failures;

  /// 第 [retries] 次连续失败后的等待(kratos `Backoff(retries)`),不改状态。
  Duration delayFor(int retries) {
    if (retries == 0) return initial;
    var backoff = initial.inMicroseconds.toDouble();
    final cap = max.inMicroseconds.toDouble();
    var n = retries;
    while (backoff < cap && n > 0) {
      backoff *= multiplier;
      n--;
    }
    if (backoff > cap) backoff = cap;
    // "Randomize backoff delays so that if a cluster of requests start at
    // the same time, they won't operate in lockstep."(kratos 原注释)
    backoff *= 1 + jitter * (_random.nextDouble() * 2 - 1);
    if (backoff < 0) return Duration.zero;
    return Duration(microseconds: backoff.round());
  }

  /// 记一次失败并返回下一次重试前的等待。
  Duration next() => delayFor(_failures++);

  /// 连接成功:复位(gRPC:"reset to INITIAL_BACKOFF" once the server accepted)。
  void reset() => _failures = 0;
}
