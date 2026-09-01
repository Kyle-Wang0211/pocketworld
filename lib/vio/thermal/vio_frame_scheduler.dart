// vio_frame_scheduler.dart — 视觉降频 + IMU 高频传播的调度器(纯 Dart)。
//
// 按 ARCore 的公开答案重设计:**视觉更新 ~10Hz,IMU 全速前向积分**。
// 我们如果按 30Hz 跑完整 VIO,就是在跟一个只做我们 1/3 工作量的对手比发热。
//
// ── 铁律:降级 = 降关键帧率,不是丢帧 ────────────────────────────────────
// 被跳过的图像帧**没有被丢弃**。本文件用类型系统把"丢帧"这个概念直接删掉:
//   * [FrameDecision] 只有 visualUpdate / imuPropagateOnly 两个取值,
//     没有 drop / discard。
//   * [FramePlan.preserved] 是 getter 且恒为 true —— 没有字段可以被设成 false。
//   * [VioFrameScheduler.framesSeen] == visualUpdates + imuPropagateOnly,
//     这条恒等式由单测钉死;任何"少算一帧"的实现都会让它对不上。
// "未参与 VIO"的帧仍然照常进采集 spool(sfm_live_recon 的磁盘队列),
// 之后离线重建照吃不误 —— 它只是**没参与实时位姿求解**,不是没了。
//
// ── 为什么不做追帧 ──────────────────────────────────────────────────────
// 求解器卡住之后,朴素实现会在恢复时连开好几次视觉更新去"补上进度"。
// 那正好是在最热的时刻突然加倍工作量。所以 deadline 落后超过一个周期时
// **直接重同步到当前帧**,永不补课。

import 'thermal_governor.dart';

/// 这一帧要不要进 VIO 做完整视觉更新。
/// **没有第三个取值** —— 帧永远不会被丢掉。
enum FrameDecision {
  /// 进 VIO:视觉观测 + 状态更新。
  visualUpdate,

  /// 不进 VIO:位姿由 IMU 前向积分给出。帧本身照常保全。
  imuPropagateOnly,
}

/// 为什么没进 VIO —— 归因用。三种原因的**处置一样,含义完全不同**:
/// 按计划降频是健康的,求解器忙是过载,视觉挂起是断流。
/// 分不开这三者,日志上就会把"被降频"和"算法发散"混成一团。
enum SkipReason {
  /// 本帧进了 VIO。
  none,

  /// 按当前档位的视觉更新率正常抽帧 —— 预期行为。
  scheduledCadence,

  /// 上一次视觉更新还没跑完 —— 过载信号,不是抽帧。
  solverBusy,

  /// 相机被打断/停止,压根没有可用视觉观测。
  visualSuspended,
}

/// 单帧调度结论。
class FramePlan {
  const FramePlan({
    required this.frameId,
    required this.timestampUs,
    required this.decision,
    required this.reason,
    required this.sinceLastVisualUs,
    required this.visualStale,
  });

  final int frameId;
  final int timestampUs;
  final FrameDecision decision;
  final SkipReason reason;

  /// 距上一次视觉更新的时长(微秒);还没有过视觉更新时为 -1。
  final int sinceLastVisualUs;

  /// IMU 已经独自推算太久,位姿不确定度必须按发散处理。
  final bool visualStale;

  /// 恒为 true:这一帧一定被保全。**没有字段可以让它变成 false。**
  bool get preserved => true;

  bool get isVisualUpdate => decision == FrameDecision.visualUpdate;
}

/// 视觉失效判定的绝对下限:无论档位多低,超过 500ms 没有视觉观测就算失效。
const int kAbsoluteVisualStaleUs = 500000;

class VioFrameScheduler {
  VioFrameScheduler();

  int _framesSeen = 0;
  int _visualUpdates = 0;
  int _imuOnly = 0;
  int _solverBusyDeferrals = 0;

  int? _nextDeadlineUs;
  int? _lastVisualUs;
  bool _solverBusy = false;

  int get framesSeen => _framesSeen;
  int get visualUpdates => _visualUpdates;
  int get imuPropagateOnly => _imuOnly;
  int get solverBusyDeferrals => _solverBusyDeferrals;
  bool get solverBusy => _solverBusy;

  /// 恒等式:看到的每一帧都被归入两类之一,一帧不少。
  bool get accountingBalanced => _framesSeen == _visualUpdates + _imuOnly;

  /// 每来一帧图像调用一次。
  ///
  /// 注意:**调用方必须无条件把这一帧送进采集 spool**,与返回值无关。
  /// 返回值只回答"要不要进 VIO",不回答"要不要留着"——后者答案永远是留着。
  FramePlan onImageFrame({
    required int frameId,
    required int timestampUs,
    required VioBudget budget,
  }) {
    _framesSeen += 1;

    final periodUs = (1000000 / budget.visualHz).round();
    final sinceLast = _lastVisualUs == null ? -1 : timestampUs - _lastVisualUs!;
    final staleLimit = (2 * periodUs) > kAbsoluteVisualStaleUs
        ? 2 * periodUs
        : kAbsoluteVisualStaleUs;
    final stale = sinceLast >= 0 && sinceLast > staleLimit;

    FramePlan skip(SkipReason reason) {
      _imuOnly += 1;
      return FramePlan(
        frameId: frameId,
        timestampUs: timestampUs,
        decision: FrameDecision.imuPropagateOnly,
        reason: reason,
        sinceLastVisualUs: sinceLast,
        visualStale: stale,
      );
    }

    if (budget.visualSuspended) {
      // 相机断流。理论上这时候不该有帧进来,但真机上打断通知与最后几帧
      // 有竞态 —— 收到就照常保全,只是不进 VIO。
      return skip(SkipReason.visualSuspended);
    }

    if (_nextDeadlineUs != null && timestampUs < _nextDeadlineUs!) {
      return skip(SkipReason.scheduledCadence);
    }

    if (_solverBusy) {
      // 求解器还没跑完上一帧。**不推进 deadline** —— 这样求解器一空出来,
      // 下一帧立刻就能进,是"推迟"而不是"跳过一个周期"。
      _solverBusyDeferrals += 1;
      return skip(SkipReason.solverBusy);
    }

    // 进 VIO。
    _visualUpdates += 1;
    _solverBusy = true;
    _lastVisualUs = timestampUs;
    final prevDeadline = _nextDeadlineUs;
    var next = (prevDeadline ?? timestampUs) + periodUs;
    if (next <= timestampUs) {
      // 落后超过一个周期:重同步,绝不补课(补课=在最热的时候加倍干活)。
      next = timestampUs + periodUs;
    }
    _nextDeadlineUs = next;

    return FramePlan(
      frameId: frameId,
      timestampUs: timestampUs,
      decision: FrameDecision.visualUpdate,
      reason: SkipReason.none,
      sinceLastVisualUs: sinceLast,
      visualStale: stale,
    );
  }

  /// VIO 跑完一次视觉更新后调用,释放求解器。
  void onVisualUpdateComplete() {
    _solverBusy = false;
  }

  /// IMU 样本:**永远全速传播**,不受热档位影响。
  /// 独立成方法是为了让"IMU 不降频"这件事在代码里是显式的,
  /// 而不是靠某处没写限流来隐式成立。
  bool shouldPropagateImu() => true;

  /// 相机重新出帧 / 重捕获后调用,清掉抽帧相位,避免用旧 deadline 追帧。
  void resyncAfterVisualGap() {
    _nextDeadlineUs = null;
    _solverBusy = false;
  }
}
