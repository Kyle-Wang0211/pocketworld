// thermal_governor.dart — 跨端唯一的热调度决策器(纯 Dart)。
//
// 输入:平台上报的 [ThermalSignal](两端同一 schema)。
// 输出:[VioBudget] —— 当前允许的视觉更新率 + 相机断流/需重捕获标志。
//
// 只有这一份实现。iOS/Android 平台代码**不做任何档位判断**,只上报原始值,
// 否则又会得到"两端跑结构性不同算法"的老问题。
//
// 迟滞规则(必须,否则档位会在阈值附近抖):
//   * 升温:**立即生效**。热是安全问题,不允许拖延。
//   * 降温:必须在更凉的档位上**持续 [cooldownDwell]** 才生效;窗口期内
//     取观测到的**最热**一档作为候选(保守),计时不因抖动重置,否则
//     nominal/fair 来回跳会导致永远降不下来。
import 'thermal_signal.dart';
import 'thermal_tier.dart';

/// 降档驻留时间。热惯性以十秒计,15s 是"够久到不是噪声、又不至于把用户
/// 卡在低档"的折中。**策略值,非实测**。
const Duration kCooldownDwell = Duration(seconds: 15);

/// 相机被系统压力断流超过这个时长后,纯 IMU 推算的位姿已不可信,
/// 恢复时必须走视觉重捕获(而不是假装状态还有效)。
const Duration kReacquireAfterVisualLoss = Duration(seconds: 2);

/// 一次决策结果。
class VioBudget {
  const VioBudget({
    required this.tier,
    required this.visualHz,
    required this.visualSuspended,
    required this.cameraShutdownAdvised,
    required this.requiresVisualReacquire,
    required this.statusReadable,
  });

  /// 迟滞后的生效档位(不等于本次信号的瞬时档位)。
  final ThermalTier tier;

  /// 目标视觉更新率(Hz)。IMU 传播**不受它约束,永远全速**。
  final double visualHz;

  /// 相机流当前拿不到帧(被打断/停止)。此时调度器只出 IMU 传播。
  final bool visualSuspended;

  /// Apple 对 thermalState == critical 的官方建议是
  /// "Consider stopping use of camera and other peripherals"。
  /// 我们不擅自停采集(会丢数据),而是把这个建议原样上抛,由采集层
  /// **先把 spool 落盘、再收尾**。
  final bool cameraShutdownAdvised;

  /// 视觉丢失过久 ⇒ 必须重捕获,不能沿用旧状态。
  /// **这是个锁存位**:一旦触发就保持 true,直到 VIO 侧调用
  /// [ThermalGovernor.noteVisualReacquired] 明确宣布已重新捕获。
  /// (最初的实现在相机恢复的那一刻就把它清了,消费者永远看不到 —— 那是 bug。)
  final bool requiresVisualReacquire;

  /// 平台是否真读到了热等级。false ⇒ 遥测里必须标 unknown,不能当健康。
  final bool statusReadable;

  /// 两次视觉更新之间的 IMU 前向积分窗口(ARCore 在 10Hz 下是 100ms)。
  Duration get deadReckonWindow =>
      Duration(microseconds: (1000000 / visualHz).round());
}

class ThermalGovernor {
  ThermalGovernor({
    this.cooldownDwell = kCooldownDwell,
    this.reacquireAfterVisualLoss = kReacquireAfterVisualLoss,
  });

  final Duration cooldownDwell;
  final Duration reacquireAfterVisualLoss;

  ThermalTier _effective = ThermalTier.nominal;

  /// 降档候选(窗口期内观测到的最热一档)与其起始时刻。
  ThermalTier? _pendingCooler;
  int? _pendingSinceUs;

  /// 视觉流中断起始时刻(微秒);null = 未中断。
  int? _visualLostSinceUs;

  /// 重捕获锁存位。中断时长越过阈值即置位,只能由 [noteVisualReacquired] 清。
  bool _reacquireLatched = false;

  ThermalTier get effectiveTier => _effective;

  /// VIO 估计器在**真的**用视觉观测重新定住状态之后调用,清掉锁存位。
  /// 相机恢复出帧 != 重捕获完成,所以这一步必须由估计器显式确认。
  void noteVisualReacquired() {
    _reacquireLatched = false;
  }

  /// 喂一条信号,得到当前预算。`initialized` 由 VIO 估计器提供
  /// (未初始化时允许 bootstrap 抬速率,见 thermal_tier.dart)。
  VioBudget update(ThermalSignal signal, {required bool initialized}) {
    final observed = signal.tier;
    final nowUs = signal.timestampUs;

    if (observed.index > _effective.index) {
      // 升温:立即生效,清掉降档候选。
      _effective = observed;
      _pendingCooler = null;
      _pendingSinceUs = null;
    } else if (observed.index < _effective.index) {
      if (_pendingSinceUs == null) {
        _pendingCooler = observed;
        _pendingSinceUs = nowUs;
      } else {
        // 保守:窗口期内取最热的候选,但**不重置计时**。
        final prev = _pendingCooler ?? observed;
        _pendingCooler = hotterTier(prev, observed);
      }
      final elapsedUs = nowUs - (_pendingSinceUs ?? nowUs);
      if (elapsedUs >= cooldownDwell.inMicroseconds) {
        final target = _pendingCooler ?? observed;
        // 候选只可能 <= 当前档;等于时也直接落定并清状态。
        _effective = target.index < _effective.index ? target : _effective;
        _pendingCooler = null;
        _pendingSinceUs = null;
      }
    } else {
      // 与生效档相同 ⇒ 不再降,清候选。
      _pendingCooler = null;
      _pendingSinceUs = null;
    }

    final suspended =
        signal.cameraStream == CameraStreamState.interrupted ||
        signal.cameraStream == CameraStreamState.stopped;
    if (suspended) {
      _visualLostSinceUs ??= nowUs;
    } else if (signal.cameraStream == CameraStreamState.running) {
      _visualLostSinceUs = null;
    }

    final lostUs = _visualLostSinceUs == null ? 0 : nowUs - _visualLostSinceUs!;
    if (lostUs >= reacquireAfterVisualLoss.inMicroseconds) {
      _reacquireLatched = true;
    }

    return VioBudget(
      tier: _effective,
      visualHz: visualHzFor(tier: _effective, initialized: initialized),
      visualSuspended: suspended,
      cameraShutdownAdvised: _effective == ThermalTier.critical,
      requiresVisualReacquire: _reacquireLatched,
      statusReadable: signal.statusReadable,
    );
  }
}
