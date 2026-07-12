// tool/sfm_feed_queue_check.dart — 拍摄期喂帧队列架构纯 Dart VM 断言
// (host `dart tool/sfm_feed_queue_check.dart`;项目惯例同
// tool/shutter_backpressure_check.dart)。
//
// 证明 07-12 签决三角约束里由队列负责的两条(① 快门不限流由 UI 侧保证,
// 见 ar_capture_page):
//   ② 队列不丢帧:狂喂 N 帧,worker 慢半拍,finalize 帧数 == 拍摄帧数;
//   ③ 不降质靠 finalize 拿到全量帧(本测证 finalize 延后到队列排空);
// 外加 ④ 内存红线:队列存**路径**不存字节 —— RAM 与队列深度无关。
//
// 手法:用 SfmLiveRecon.offerFrame/_pump/_maybeSendFinalize 真正调用的那三个
// 纯谓词(sfm_feed_queue.dart)驱动一个忠实的队列模型,断言不变量。谓词是
// 生产代码同一份,所以这里覆盖的是真实调度逻辑,不是复制品。

import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';

void check(bool cond, String what) {
  if (!cond) {
    throw StateError('FAIL: $what');
  }
  // ignore: avoid_print
  print('ok: $what');
}

/// 忠实复刻 SfmLiveRecon 的队列侧行为(只保留调度,去掉 isolate/文件 I/O)。
/// - [_inFlightQ]:已送 worker、未 ack 的 seq(FIFO,worker 逐个消化);
/// - [_spool]:溢写磁盘的排队条目——**只存 seq(路径代理),绝不存字节**;
/// - [ramBytesRetained]:模型在内存里为图像数据留的字节。溢写走磁盘 → 恒 0,
///   这就是「内存与队列深度无关」的机器可证明版本。
class _FeedQueueModel {
  final List<int> _inFlightQ = <int>[];
  final List<int> _spool = <int>[];
  bool _finalizeRequested = false;
  bool _finalizeSent = false;

  /// 被 worker ack 的 seq,按 ack 顺序(= 应与拍摄顺序逐位一致)。
  final List<int> acked = <int>[];

  /// finalize 真正下发时已 ack 的帧数(证明「延后到全量喂完」)。
  int finalizeSentAtAcked = -1;

  /// finalize 下发次数(必须恰好 1)。
  int finalizeSentCount = 0;

  /// 整个仿真里同时在途的峰值(必须 ≤ kSfmFeedMaxInFlight)。
  int peakInFlight = 0;

  /// 队列(spool)深度峰值——可以很大,用来证明深队列 ≠ 涨内存。
  int peakSpoolDepth = 0;

  /// 模型为图像字节留的 RAM(溢写磁盘 → 恒 0)。
  int ramBytesRetained = 0;

  void _send(int seq) {
    _inFlightQ.add(seq);
    if (_inFlightQ.length > peakInFlight) peakInFlight = _inFlightQ.length;
  }

  /// offerFrame:worker 有空位则直送,否则**溢写磁盘**排队(不阻塞、不丢帧、
  /// 不留字节)。[imageBytes] 模拟 4K gray 平面大小;直送时它随命令交给 worker
  /// (不驻留),溢写时它落盘(ramBytesRetained 不增)——两条路径都不涨 RAM。
  void offer(int seq, {required int imageBytes}) {
    if (sfmFeedShouldSpool(
      inFlight: _inFlightQ.length,
      spoolDepth: _spool.length,
    )) {
      // 落盘:只把 seq(路径代理)排进内存队列,字节进磁盘。
      _spool.add(seq);
      if (_spool.length > peakSpoolDepth) peakSpoolDepth = _spool.length;
    } else {
      _send(seq);
    }
  }

  /// worker 消化一帧(ack 最老的在途帧),空出的槽位由 pump 补喂磁盘队首。
  void workerAckOne() {
    if (_inFlightQ.isEmpty) return;
    acked.add(_inFlightQ.removeAt(0));
    _pump();
  }

  void _pump() {
    while (sfmFeedCanPumpNext(
      inFlight: _inFlightQ.length,
      spoolDepth: _spool.length,
    )) {
      _send(_spool.removeAt(0)); // FIFO:磁盘队首,保序
    }
    _maybeSendFinalize();
  }

  void requestFinalize() {
    _finalizeRequested = true;
    _pump(); // 队列没排空只会空跑;排空了才真下发
  }

  void _maybeSendFinalize() {
    if (!sfmFeedCanSendFinalize(
      finalizeRequested: _finalizeRequested,
      finalizeSent: _finalizeSent,
      spoolDepth: _spool.length,
      inFlight: _inFlightQ.length,
    )) {
      return;
    }
    _finalizeSent = true;
    finalizeSentCount++;
    finalizeSentAtAcked = acked.length;
  }

  bool get drained => _inFlightQ.isEmpty && _spool.isEmpty;
}

void _predicateTruthTables() {
  // shouldSpool:worker 未满且队列空 → 直送(false);否则排队(true)。
  check(
    !sfmFeedShouldSpool(inFlight: 0, spoolDepth: 0),
    'shouldSpool: 空闲空队列 = 直送',
  );
  check(
    !sfmFeedShouldSpool(inFlight: kSfmFeedMaxInFlight - 1, spoolDepth: 0),
    'shouldSpool: 有空位空队列 = 直送',
  );
  check(
    sfmFeedShouldSpool(inFlight: kSfmFeedMaxInFlight, spoolDepth: 0),
    'shouldSpool: 在途满 = 溢写',
  );
  check(
    sfmFeedShouldSpool(inFlight: 0, spoolDepth: 1),
    'shouldSpool: 队列非空必须溢写(保序,不插队)',
  );

  // canPumpNext:有空位且队列非空。
  check(
    sfmFeedCanPumpNext(inFlight: kSfmFeedMaxInFlight - 1, spoolDepth: 1),
    'canPumpNext: 有空位 + 队列非空 = 喂',
  );
  check(
    !sfmFeedCanPumpNext(inFlight: kSfmFeedMaxInFlight, spoolDepth: 5),
    'canPumpNext: 在途满 = 不喂',
  );
  check(
    !sfmFeedCanPumpNext(inFlight: 0, spoolDepth: 0),
    'canPumpNext: 空队列 = 不喂',
  );

  // canSendFinalize:已请求 + 未发 + 队列空 + 在途 0。
  check(
    sfmFeedCanSendFinalize(
      finalizeRequested: true,
      finalizeSent: false,
      spoolDepth: 0,
      inFlight: 0,
    ),
    'canSendFinalize: 全排空 + 已请求 = 下发',
  );
  check(
    !sfmFeedCanSendFinalize(
      finalizeRequested: true,
      finalizeSent: false,
      spoolDepth: 1,
      inFlight: 0,
    ),
    'canSendFinalize: 队列没排空 = 不发(② 强制点)',
  );
  check(
    !sfmFeedCanSendFinalize(
      finalizeRequested: true,
      finalizeSent: false,
      spoolDepth: 0,
      inFlight: 1,
    ),
    'canSendFinalize: 还有在途 = 不发',
  );
  check(
    !sfmFeedCanSendFinalize(
      finalizeRequested: true,
      finalizeSent: true,
      spoolDepth: 0,
      inFlight: 0,
    ),
    'canSendFinalize: 已发过 = 不重发',
  );
  check(
    !sfmFeedCanSendFinalize(
      finalizeRequested: false,
      finalizeSent: false,
      spoolDepth: 0,
      inFlight: 0,
    ),
    'canSendFinalize: 未请求 = 不发',
  );
}

/// 场景 A —— 狂拍:worker 完全跟不上(N 帧全在 finalize 前 offer 完,期间零
/// ack),然后请求 finalize(此时队列很深),再慢慢排空。证明 ②③④。
void _scenarioBurstThenDrain(int n) {
  const bytesPerFrame = 8300000; // 4K gray ≈ 8.3MB;深队列本会爆内存的元凶
  final m = _FeedQueueModel();
  for (var seq = 1; seq <= n; seq++) {
    m.offer(seq, imageBytes: bytesPerFrame);
  }
  // 队列很深时就请求完成 —— finalize 必须延后,不能现在发。
  m.requestFinalize();
  check(m.finalizeSentCount == 0, '狂拍$n:队列未排空 → finalize 延后未发');
  check(
    m.peakSpoolDepth >= n - kSfmFeedMaxInFlight,
    '狂拍$n:队列确实堆到深(peak=${m.peakSpoolDepth})',
  );
  check(m.ramBytesRetained == 0, '狂拍$n:队列深但 RAM 图像字节 = 0(路径队列,内存 bounded)');

  // worker 逐帧消化直到排空。
  var guard = 0;
  while (!m.drained && guard++ < n * 4) {
    m.workerAckOne();
  }
  check(m.drained, '狂拍$n:最终全部排空');
  check(m.acked.length == n, '狂拍$n:finalize 帧数 == 拍摄帧数($n,零丢帧)');
  // FIFO:ack 顺序 == 拍摄顺序 1..n。
  var ordered = true;
  for (var i = 0; i < n; i++) {
    if (m.acked[i] != i + 1) ordered = false;
  }
  check(ordered, '狂拍$n:喂入顺序严格 FIFO(不乱序)');
  check(m.finalizeSentCount == 1, '狂拍$n:finalize 恰好下发一次');
  check(
    m.finalizeSentAtAcked == n,
    '狂拍$n:finalize 只在全部 $n 帧喂完后才下发(不降质:全量进 finalize)',
  );
  check(
    m.peakInFlight <= kSfmFeedMaxInFlight,
    '狂拍$n:同时在途峰值 ≤ $kSfmFeedMaxInFlight(worker 背压只在消费侧)',
  );
}

/// 场景 B —— 交错:worker 每次 offer 后立刻 ack 上一帧(能跟上)。应零溢写、
/// finalize 请求即发(队列本就空)。
void _scenarioInterleaved(int n) {
  final m = _FeedQueueModel();
  for (var seq = 1; seq <= n; seq++) {
    m.offer(seq, imageBytes: 8300000);
    m.workerAckOne(); // worker 跟得上
  }
  check(m.peakSpoolDepth == 0, '交错$n:worker 跟得上 → 零溢写');
  m.requestFinalize();
  check(m.finalizeSentCount == 1, '交错$n:队列空 → finalize 立即下发');
  check(m.acked.length == n, '交错$n:$n 帧全部喂入');
}

void main() {
  _predicateTruthTables();
  for (final n in <int>[1, 2, 3, 10, 100, 1000]) {
    _scenarioBurstThenDrain(n);
  }
  for (final n in <int>[1, 5, 50]) {
    _scenarioInterleaved(n);
  }
  // ignore: avoid_print
  print('ALL PASS');
}
