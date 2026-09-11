// auto_capture_telemetry.dart — 自动采集的**聚合**遥测(纯 Dart,零 Flutter 依赖)。
//
// 存在的唯一理由是回答 spec §11「待标定 / 待实测清单」里那几个**文档判不了、
// 只能真机实测**的问题:
//
//   · 视差下限到底有没有用 —— RS / Polycam / KIRI / Scaniverse 四家都没有
//     「移动太少就别拍」这道门,只讲重叠上限。我们有,依据是自家 coverage
//     cloud 把低视差判成双墙成因。但同行不设下限也可能是因为手持绕物时它
//     根本很少触发 —— 若如此,这道门无害但也无用。`skipNotMoved` 的占比
//     就是它的实际拦截率(spec §9 差异1 / §11)。
//   · 一轮采集实际跑多长 vs 已签决的 5 分钟上限(spec §11)。
//   · ShutterPace 三档各停留多久 = 积压到底有多严重(spec §11)。
//   · 入队失败有没有真的发生 —— spec §7「入队失败 ⇒ 基准帧不更新 + **记遥测**」。
//
// **不写每帧一行。** pose 流是逐 ARFrame 的 20–60 Hz(spec §5.4),逐判定落盘
// 就是 60 行/秒。这里只在内存里聚合,由采集页按 [kAutoCaptureTelemetryFlushSec]
// 取一份**累计**快照写进既有的 TelemetryWriter —— 与 frame / queue_drain /
// shutter_pace 同一个 `Documents/telemetry_official_dart.jsonl`,拔线跑完
// `devicectl` 一次拉走。**不另起遥测通道**:多一条出口就多一处会漏采的地方。
//
// 每条 roll-up 行都是**自会话起点起的累计量**(不是窗口增量),所以最后一行
// 就是全部真相;App 被杀 / 用户强退时,最后一条 roll-up 仍是一份可用的
// 部分结果,`closed=false` 说明它不是终态。
//
// 时钟一律是 **ARPose.timestamp**(ARFrame 时间轴 = CACurrentMediaTime),
// 与 AutoCaptureController 同一条。本文件既不自己取时间、也没有任何 API 收
// `DateTime.now()` 那个纪元的值 —— 混纪元什么都不会抛,只会把时长静默算错。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md §7 / §9 / §11。

import 'auto_capture_governor.dart';
import 'place_recognition_bayes.dart';
import 'auto_capture_geometry.dart'
    show
        AutoCaptureMotionMetrics,
        AutoCaptureMotionRole,
        kAutoCaptureGeometryNormalDeg,
        kAutoCaptureGeometryStrongDeg,
        kAutoCaptureGeometryWeakDeg;
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 累计快照的落盘节流(秒)。与采集页既有的 5 秒诊断轮次同一个量级:
/// 一轮采集上限 5 分钟 ⇒ 至多 ~60 行,可忽略;而丢失窗口至多 5 秒。
const double kAutoCaptureTelemetryFlushSec = 5.0;

const List<AutoCaptureMotionRole> _fireRoles = <AutoCaptureMotionRole>[
  AutoCaptureMotionRole.overlapSafety,
  AutoCaptureMotionRole.geometry,
  AutoCaptureMotionRole.rotationCoverage,
  AutoCaptureMotionRole.radialBridge,
  // [2026-09-07] 生产开火 = stella_vslam new_keyframe_is_needed;几何角色只留遥测。
  AutoCaptureMotionRole.keyframeInserter,
];

class _RoleCounts {
  int evaluated = 0;
  int eligible = 0;
  int selected = 0;
  int fired = 0;
  int maskedByPriority = 0;
  int blockedBlur = 0;
  int blockedPace = 0;
  int blockedNoVisualEvidence = 0;
  int blockedRedundant = 0;
  int blockedTracking = 0;
  int blockedCap = 0;
  int blockedTimeLimit = 0;
  int blockedNotMoved = 0;
  int blockedTooDark = 0;

  void clear() {
    evaluated = 0;
    eligible = 0;
    selected = 0;
    fired = 0;
    maskedByPriority = 0;
    blockedBlur = 0;
    blockedPace = 0;
    blockedNoVisualEvidence = 0;
    blockedRedundant = 0;
    blockedTracking = 0;
    blockedCap = 0;
    blockedTimeLimit = 0;
    blockedNotMoved = 0;
    blockedTooDark = 0;
  }

  Map<String, int> snapshot() => <String, int>{
    'evaluated': evaluated,
    'eligible': eligible,
    'selected': selected,
    'fired': fired,
    'masked_by_priority': maskedByPriority,
    'blocked_blur': blockedBlur,
    'blocked_too_dark': blockedTooDark,
    'blocked_pace': blockedPace,
    'blocked_no_visual_evidence': blockedNoVisualEvidence,
    'blocked_redundant': blockedRedundant,
    'blocked_tracking': blockedTracking,
    'blocked_cap': blockedCap,
    'blocked_time_limit': blockedTimeLimit,
    'blocked_not_moved': blockedNotMoved,
  };
}

/// 一轮自动采集的判定/开火/档位聚合。**只做加法**,不做任何判定 ——
/// "要不要拍"全在 auto_capture_governor.dart。
class AutoCaptureTelemetry {
  final Map<AutoCaptureDecision, int> _counts = <AutoCaptureDecision, int>{
    for (final d in AutoCaptureDecision.values) d: 0,
  };

  /// 三档各停留多久(秒)。区间按**左端点**归属:t0→t1 这段时间记在 t0
  /// 那一刻观测到的档上 —— 那才是这段时间里 governor 实际用的 tick 间隔。
  final Map<ShutterPace, double> _paceSec = <ShutterPace, double>{
    for (final p in ShutterPace.values) p: 0.0,
  };

  final Map<AutoCaptureMotionRole, int> _fireRoleCounts =
      <AutoCaptureMotionRole, int>{for (final role in _fireRoles) role: 0};

  /// 固定 4×常数个整数；与 pose 数、会话时长、拍照张数无关。`none`
  /// 不是拍摄角色，单列在 [_noCandidate]/[_selectedNone]，绝不混入本表。
  final Map<AutoCaptureMotionRole, _RoleCounts> _roleCounts =
      <AutoCaptureMotionRole, _RoleCounts>{
        for (final role in _fireRoles) role: _RoleCounts(),
      };

  final Map<AutoCaptureMotionRole, Map<AutoCaptureDecision, int>>
  _winnerDecisionCounts =
      <AutoCaptureMotionRole, Map<AutoCaptureDecision, int>>{
        for (final role in _fireRoles)
          role: <AutoCaptureDecision, int>{
            for (final decision in AutoCaptureDecision.values) decision: 0,
          },
      };

  final Map<AutoCaptureDecision, int> _selectedNoneDecisionCounts =
      <AutoCaptureDecision, int>{
        for (final decision in AutoCaptureDecision.values) decision: 0,
      };
  int _noCandidate = 0;
  int _selectedNone = 0;

  // fire_reason:每次成功开火时,两个授权信号各自的状态。会话内部证据 ——
  // 直接读出「新旧比条件单独促成了几枪」,不需要跨会话比较。
  int _firesSegmentReadyOnly = 0;
  int _firesNewFeatureBurstOnly = 0;
  int _firesBothReady = 0;

  int _overlapKnown = 0;
  int _overlapUnknown = 0;
  int _geometryWeakThreshold = 0;
  int _geometryNormalThreshold = 0;
  int _geometryStrongThreshold = 0;
  int _geometryOtherThreshold = 0;

  /// 会话是否开着。关掉之后到达的判定一律丢弃 —— 那一行早就写出去了,
  /// 事后再改它的比例只会让两行互相矛盾。
  bool _open = false;

  /// 起跑时间戳;null = 这个对象从来没跑过一轮。
  double? _startSec;
  double? _lastDecisionSec;
  ShutterPace? _lastPace;

  /// 上一次开火的时间戳。null 时以 [_startSec] 为参照 —— controller 的
  /// `_lastTickSec` 在 `start()` 那一帧就被置成起跑时间戳,这里必须同口径,
  /// 否则第一发的归因就是错的。
  double? _lastFireSec;

  double _lastEmitSec = 0;
  int _fireEnqueued = 0;
  int _fireEnqueueFailed = 0;
  int _fireBeforeTick = 0;
  int _startAnchorAttempted = 0;
  int _startAnchorEnqueued = 0;
  int _startAnchorFailed = 0;

  /// 开一轮。[tSec] 必须是起跑那一帧的 `ARPose.timestamp`(与
  /// `AutoCaptureController.start()` 收到的是同一个 pose)。
  ///
  /// **全清**:一次采集里用户可以停了再开,第二轮带着第一轮的计数会让
  /// 两轮的比例都变成错的,而且从数据上看不出来。
  void recordSessionStart(double tSec) {
    _open = true;
    _startSec = tSec;
    _lastDecisionSec = null;
    _lastPace = null;
    _lastFireSec = null;
    // 节流从起跑时刻起算,不是从 0 —— ARFrame 时钟是开机以来的秒数,
    // 开机跑几小时后它是个几万的数,从 0 起算的话第一帧就"到点"⇒ 每帧一行。
    _lastEmitSec = tSec;
    _fireEnqueued = 0;
    _fireEnqueueFailed = 0;
    _fireBeforeTick = 0;
    _startAnchorAttempted = 0;
    _startAnchorEnqueued = 0;
    _startAnchorFailed = 0;
    _evidenceTicksTracks = 0;
    _evidenceTicksMap = 0;
    _mapTrackedLms.clear();
    _mapReliableLms.clear();
    _mapReliableLmsRef.clear();
    _fireMovedM.clear();
    _fireDistM.clear();
    _fireTurnDeg.clear();
    _fireLiveDepthM.clear();
    _fireSharpness.clear();
    _fireSegMedian.clear();
    _fireGeometryParallaxDeg.clear();
    _fireOverlapFraction.clear();
    _fireDepthScaleRatio.clear();
    _fireVisualSimilarity.clear();
    _redundantVisualSimilarity.clear();
    _fireTrackMedianNormalized.clear();
    _redundantTrackMedianNormalized.clear();
    _fireTrackMedianStepPx.clear();
    _redundantTrackMedianStepPx.clear();
    _fireSegmentMotionPx.clear();
    _redundantSegmentMotionPx.clear();
    _segmentMotionThresholdPx = null;
    _trackCommonFraction.clear();
    _trackCommonCount.clear();
    _visualSourceAgeSec.clear();
    for (final d in AutoCaptureDecision.values) {
      _counts[d] = 0;
    }
    for (final p in ShutterPace.values) {
      _paceSec[p] = 0.0;
    }
    for (final role in _fireRoles) {
      _roleCounts[role]!.clear();
      for (final decision in AutoCaptureDecision.values) {
        _winnerDecisionCounts[role]![decision] = 0;
      }
    }
    for (final role in _fireRoles) {
      _fireRoleCounts[role] = 0;
    }
    for (final decision in AutoCaptureDecision.values) {
      _selectedNoneDecisionCounts[decision] = 0;
    }
    _noCandidate = 0;
    _selectedNone = 0;
    _firesSegmentReadyOnly = 0;
    _firesNewFeatureBurstOnly = 0;
    _firesBothReady = 0;
    _overlapKnown = 0;
    _overlapUnknown = 0;
    _geometryWeakThreshold = 0;
    _geometryNormalThreshold = 0;
    _geometryStrongThreshold = 0;
    _geometryOtherThreshold = 0;
  }

  /// 记一次判定。**每个 pose 都要记**,不是只记 fire —— `skipNotMoved` 的
  /// 占比才是视差下限那道门的实际拦截率(spec §9 差异1)。
  ///
  /// [tSec] = 该帧的 `ARPose.timestamp`;[pace] = 该帧 controller 的
  /// `paceProvider` 读到的同一个档位(采集页的 `_shutterPace`);
  /// [thermalState] = 同一帧的 thermal 桶(0..3,<0 未知按冷)。
  ///
  /// ⚠️ [thermalState] 有默认值 **只是为了**让本文件的纯聚合测试不必逐条
  /// 关心热态;**生产调用点必须显式传**(采集页的 `_lastThermalState`,与
  /// controller 的 `thermalStateProvider` 同一个字段),否则 `fire_before_tick`
  /// 用的间隔会与 governor 实际用的对不上 —— 热态下 governor 的间隔更长,
  /// 而这里若按 0 算就会把本该记进 R2 的发数漏掉。这条由
  /// auto_capture_telemetry_test 的源码契约钉住。
  ///
  /// ⚠️ 占比是**按判定数**算的,而判定是按 pose 来的(20–60 Hz),不是按
  /// tick 来的。所以 `skipNotMoved / decisions` 读作"下限门把快门**按住的
  /// 时间**占比",不是"拦掉了多少张"。这正是我们想知道的那个量:
  /// 它 ≈ 0 就说明这道门在真实手持绕物里几乎不触发。
  void recordDecision(
    AutoCaptureDecision d, {
    required double tSec,
    required ShutterPace pace,
    int thermalState = 0,
    double? movedM,
    double? fireDistM,
    double? turnDeg,
    double? liveDepthM,
    double? sharpness,
    double? segMedianSharpness,
    AutoCaptureMotionMetrics? motion,
    AutoCaptureMotionRole? motionRole,
    double? geometryParallaxDeg,
    double? overlapFraction,
    double? depthScaleRatio,
    double? visualSimilarity,
    int? trackCommonCount,
    // [2026-09-11] 判据吃的三个量是哪套口径来的:'tracks' = 现役 LK 轨迹,
    // 'map' = 上游的地图路标口径。**上机之后唯一能验"真的切过去了"的东西**;
    // 三个数一并记,便于事后核 view_changed / almost_all 的比值。
    String? evidenceSource,
    int? mapNumTrackedLms,
    int? mapNumReliableLms,
    int? mapNumReliableLmsRef,
    // [2026-09-10] 地点识别(RTAB-Map 词袋)的代价与结果。用户明确要"然后去做
    // 优化提速+降本" ⇒ **优化之前先有账**,否则又变成"感觉慢"。
    int? placeSignatureCount,
    int? placeWordCount,
    int? placeDescribeMicros,
    int? placeQueryMicros,
    int? placeBestSharedWords,
    int? placeBestReferenceWords,
    // 贝叶斯后验(RTAB-Map `LoopThr=0.11` 卡的就是它)。千分数存整数,免得
    // JSON 里出现 NaN/Inf 把整条事件丢掉(静默出口那条老教训)。
    int? placePosteriorPermille,
    bool? placeLoopClosure,
    double? trackCommonFraction,
    double? trackMedianNormalizedDisplacement,
    double? trackMedianStepPixelDisplacement,
    double? segmentMotionPx,
    double? segmentMotionThresholdPx,
    double? visualSourceAgeSec,
  }) {
    if (!_open) return;
    // 生产调用总是传 [motion]。保留旧的 [motionRole] 接缝是为了兼容已有
    // 纯聚合测试；无完整 metrics 时只把显式赢家视为命中，不虚构其它候选。
    final winner = motion?.role ?? motionRole ?? AutoCaptureMotionRole.none;
    if (d == AutoCaptureDecision.fire && !_fireRoles.contains(winner)) {
      throw ArgumentError.value(
        winner,
        'motionRole',
        'fire requires exactly one of the four capture roles',
      );
    }
    if (placeDescribeMicros != null) {
      _placeDescribeMicros.add(placeDescribeMicros);
      if (placeQueryMicros != null) _placeQueryMicros.add(placeQueryMicros);
      if (evidenceSource == 'map') {
        _evidenceTicksMap++;
      } else if (evidenceSource != null) {
        _evidenceTicksTracks++;
      }
      if (mapNumTrackedLms != null) _mapTrackedLms.add(mapNumTrackedLms);
      if (mapNumReliableLms != null) _mapReliableLms.add(mapNumReliableLms);
      if (mapNumReliableLmsRef != null) {
        _mapReliableLmsRef.add(mapNumReliableLmsRef);
      }
      if (placeSignatureCount != null) _placeSigsLast = placeSignatureCount;
      if (placeWordCount != null) _placeWordsLast = placeWordCount;
      if (placePosteriorPermille != null) {
        _placePosteriorPermille.add(placePosteriorPermille);
        if (placeLoopClosure == true) _placeLoopClosures++;
      }
      if (placeBestSharedWords != null &&
          placeBestReferenceWords != null &&
          placeBestReferenceWords > 0) {
        _placeBestRatioPermille.add(
          (1000 * placeBestSharedWords / placeBestReferenceWords).round(),
        );
      }
    }
    _counts[d] = (_counts[d] ?? 0) + 1;
    for (final role in _fireRoles) {
      final row = _roleCounts[role]!;
      final eligible = motion?.isRoleEligible(role) ?? role == winner;
      row.evaluated++;
      if (eligible) {
        row.eligible++;
        if (role != winner) row.maskedByPriority++;
      }
    }

    final winnerRow = _roleCounts[winner];
    if (winnerRow == null) {
      _noCandidate++;
      _selectedNone++;
      _selectedNoneDecisionCounts[d] =
          (_selectedNoneDecisionCounts[d] ?? 0) + 1;
    } else {
      winnerRow.selected++;
      _winnerDecisionCounts[winner]![d] =
          (_winnerDecisionCounts[winner]![d] ?? 0) + 1;
      switch (d) {
        case AutoCaptureDecision.fire:
          winnerRow.fired++;
          break;
        case AutoCaptureDecision.skipBlurry:
          winnerRow.blockedBlur++;
          break;
        case AutoCaptureDecision.skipPaced:
        case AutoCaptureDecision.skipAwaitingCapture:
        case AutoCaptureDecision.skipMapperStopped:
        case AutoCaptureDecision.skipMapperBusy:
          // 等实拍基准与 250 ms 去抖同属"节奏类"阻挡;decision_counts 里仍按
          // 各自的枚举名分开计数。
          winnerRow.blockedPace++;
          break;
        case AutoCaptureDecision.skipNoVisualEvidence:
          winnerRow.blockedNoVisualEvidence++;
          break;
        case AutoCaptureDecision.skipRedundant:
          winnerRow.blockedRedundant++;
          break;
        case AutoCaptureDecision.skipTracking:
          winnerRow.blockedTracking++;
          break;
        case AutoCaptureDecision.skipCapped:
          winnerRow.blockedCap++;
          break;
        case AutoCaptureDecision.skipTimeLimit:
          winnerRow.blockedTimeLimit++;
          break;
        case AutoCaptureDecision.skipNotMoved:
        case AutoCaptureDecision.skipMinDistance:
          winnerRow.blockedNotMoved++;
          break;
        case AutoCaptureDecision.skipTooDark:
          winnerRow.blockedTooDark++;
          break;
      }
    }

    // 一旦有完整分类结果，它就是权威来源；特别是 null 表示投影未知，绝不
    // 允许遗留标量把它回填成 0（0 会被读成已知的零重叠）。
    final observedOverlap = motion == null
        ? overlapFraction
        : motion.overlapFraction;
    if (observedOverlap == null) {
      _overlapUnknown++;
    } else {
      _overlapKnown++;
    }
    final geometryThreshold = motion?.geometryThresholdDeg;
    if (geometryThreshold == kAutoCaptureGeometryWeakDeg) {
      _geometryWeakThreshold++;
    } else if (geometryThreshold == kAutoCaptureGeometryNormalDeg) {
      _geometryNormalThreshold++;
    } else if (geometryThreshold == kAutoCaptureGeometryStrongDeg) {
      _geometryStrongThreshold++;
    } else {
      _geometryOtherThreshold++;
    }
    if (trackCommonCount != null) {
      _trackCommonCount.add(trackCommonCount.toDouble());
    }
    if (trackCommonFraction != null && trackCommonFraction.isFinite) {
      _trackCommonFraction.add(trackCommonFraction);
    }
    if (visualSourceAgeSec != null && visualSourceAgeSec.isFinite) {
      _visualSourceAgeSec.add(visualSourceAgeSec);
    }
    if (segmentMotionThresholdPx != null && segmentMotionThresholdPx.isFinite) {
      _segmentMotionThresholdPx ??= segmentMotionThresholdPx;
    }

    // [pw] 2026-08-24 触发层换血后的开火快照:位移 / 生效阈值 / 转角 /
    // 活体 SfM 深度。首/中/末三点(见 _triple)——上一版靠 fire_depth_m
    // 抓到了"深度整场撒谎 8 倍"的真凶,这一版同样要能一眼看出:
    //   · moved ≥ dist 还是 turn 开的火(moved < dist 的开火 = 转角路);
    //   · dist 有没有被活体深度缩放(= fallback 0.28 还是别的值);
    //   · liveDepth 与事后 SfM 验尸值是否一致(再有撒谎的立刻现形)。
    if (d == AutoCaptureDecision.fire) {
      void keep(List<double> into, double? v) {
        if (v != null && v.isFinite) into.add(v);
      }

      keep(_fireMovedM, movedM);
      keep(_fireDistM, fireDistM);
      keep(_fireTurnDeg, turnDeg);
      keep(_fireLiveDepthM, liveDepthM);
      // 锐度缓拍门的疗效对:开火帧锐度 vs 当时的段中位。
      keep(_fireSharpness, sharpness);
      keep(_fireSegMedian, segMedianSharpness);
      keep(
        _fireGeometryParallaxDeg,
        motion?.geometryParallaxDeg ?? geometryParallaxDeg,
      );
      keep(_fireOverlapFraction, observedOverlap);
      keep(_fireDepthScaleRatio, motion?.depthScaleRatio ?? depthScaleRatio);
      keep(_fireVisualSimilarity, visualSimilarity);
      keep(_fireTrackMedianNormalized, trackMedianNormalizedDisplacement);
      keep(_fireTrackMedianStepPx, trackMedianStepPixelDisplacement);
      keep(_fireSegmentMotionPx, segmentMotionPx);
      _fireRoleCounts[winner] = _fireRoleCounts[winner]! + 1;
    } else if (d == AutoCaptureDecision.skipRedundant) {
      if (visualSimilarity != null && visualSimilarity.isFinite) {
        _redundantVisualSimilarity.add(visualSimilarity);
      }
      if (trackMedianNormalizedDisplacement != null &&
          trackMedianNormalizedDisplacement.isFinite) {
        _redundantTrackMedianNormalized.add(trackMedianNormalizedDisplacement);
      }
      if (trackMedianStepPixelDisplacement != null &&
          trackMedianStepPixelDisplacement.isFinite) {
        _redundantTrackMedianStepPx.add(trackMedianStepPixelDisplacement);
      }
      if (segmentMotionPx != null && segmentMotionPx.isFinite) {
        _redundantSegmentMotionPx.add(segmentMotionPx);
      }
    }

    final prevSec = _lastDecisionSec;
    final prevPace = _lastPace;
    if (prevSec != null && prevPace != null && tSec > prevSec) {
      // 时间只许往前加。ARFrame 时钟本来就是单调的,倒退只可能是接线
      // 出了错 —— 那时把负数加进直方图会**同时**弄脏两档。
      _paceSec[prevPace] = (_paceSec[prevPace] ?? 0) + (tSec - prevSec);
    }
    _lastDecisionSec = tSec;
    _lastPace = pace;

    if (d == AutoCaptureDecision.fire) {
      // 距上一次开火**严格短于**当前档的 tick 间隔 ⇒ 这一发只可能是 R2
      // (重叠上限)打的:governor 里的 tick 闸就是
      // `sinceLastTickSec < tickIntervalSec -> skipPaced`,而 controller
      // 只在开火时重置那个时钟。等于间隔时 tick 闸已放行,归因不唯一,
      // 那一发不算 ⇒ 本计数是 R2 占比的**下界**,不是精确值(见报告)。
      final since = tSec - (_lastFireSec ?? _startSec ?? tSec);
      // 间隔取自 governor 同一个函数,不新造常数,也不写死 1.0 ——
      // 连热态下限也是同一个函数算的,否则热机时这里会用一个比 governor
      // 实际用的更短的间隔,把本该记进 R2 的发数算漏。
      final intervalSec = autoCaptureTickIntervalSec(
        pace: pace,
        thermalState: thermalState,
      );
      if (since < intervalSec) _fireBeforeTick++;
      _lastFireSec = tSec;
    }
  }

  /// 记一次开火的**真实**入队结果(spec §7:入队失败要记遥测)。
  /// 由采集页的 onFire 钩子在拿到 `_enqueueShutterCapture()` 返回值处调用,
  /// 那是全链路唯一能把"拍成了"与"没拍成"分开的地方。
  /// 成功开火时两个授权信号的状态。`newFeatureBurst && !segmentReady` 的那
  /// 一档,就是 VINS-Fusion 新旧比条件**单独**促成的开火。
  void recordFireReason({
    required bool segmentReady,
    required bool newFeatureBurst,
  }) {
    if (segmentReady && newFeatureBurst) {
      _firesBothReady++;
    } else if (newFeatureBurst) {
      _firesNewFeatureBurstOnly++;
    } else {
      _firesSegmentReadyOnly++;
    }
  }

  void recordFireOutcome({required bool enqueued}) {
    if (!_open) return;
    if (enqueued) {
      _fireEnqueued++;
    } else {
      _fireEnqueueFailed++;
    }
  }

  /// 自动模式起跑锚点不是运动分类结果，单列记账，避免污染固定四角色守恒式。
  void recordStartAnchorOutcome({required bool enqueued}) {
    if (!_open) return;
    _startAnchorAttempted++;
    if (enqueued) {
      _startAnchorEnqueued++;
    } else {
      _startAnchorFailed++;
    }
  }

  /// 关一轮,返回**终态**快照(`closed=true`)供调用方落盘。
  ///
  /// **幂等**:没有开着的会话(从没开过、或已经关过)时返回 null。
  /// 页面有三条会互相重叠的收场路径 —— 用户点停、controller 撞上限自停、
  /// dispose —— 幂等是它们能各自无脑调用一次的前提。
  Map<String, Object>? recordSessionEnd() {
    if (!_open) return null;
    _open = false;
    return snapshot();
  }

  /// 到点就返回一份累计快照并记账,没到点(或没有开着的会话)返回 null。
  ///
  /// **节流收在这一个调用里**:拆成 `isDue()` + `markFlushed()` 两步的话,
  /// 调用方漏掉第二步就是 60 行/秒 —— 而那种漏法不会报错,只会在事后
  /// 发现日志涨到几百 MB。
  Map<String, Object>? snapshotIfDue(double tSec) {
    if (!_open) return null;
    if (tSec - _lastEmitSec < kAutoCaptureTelemetryFlushSec) return null;
    _lastEmitSec = tSec;
    return snapshot();
  }

  /// 自会话起点起的累计量。字段少而准 —— 拉回来的人不用再自己推导。
  final List<int> _placeDescribeMicros = <int>[];
  final List<int> _placeQueryMicros = <int>[];
  final List<int> _placeBestRatioPermille = <int>[];
  int _evidenceTicksTracks = 0;
  int _evidenceTicksMap = 0;
  final List<int> _mapTrackedLms = <int>[];
  final List<int> _mapReliableLms = <int>[];
  final List<int> _mapReliableLmsRef = <int>[];
  int _placeSigsLast = 0;
  int _placeWordsLast = 0;
  final List<int> _placePosteriorPermille = <int>[];
  int _placeLoopClosures = 0;

  static int _maxOf(List<int> xs) =>
      xs.isEmpty ? 0 : xs.reduce((a, b) => a > b ? a : b);

  static int _percentile(List<int> xs, double q) {
    if (xs.isEmpty) return 0;
    final sorted = List<int>.from(xs)..sort();
    return sorted[((sorted.length - 1) * q).round()];
  }

  Map<String, Object> snapshot() {
    final start = _startSec;
    // 时长以**最近一次判定**为终点,而不是"关会话时才有数":中途 roll-up
    // 行必须带当时的已跑时长,否则 App 被杀 / 用户强退时,唯一能拿回来的
    // 那一行恰好为 0。判定与 pose 同频,误差 ≤ 一帧(17–50 ms)。
    final end = _lastDecisionSec ?? start;
    final duration = (start == null || end == null) ? 0.0 : end - start;
    return <String, Object>{
      // 这一行是不是终态。中途拉日志 / 崩溃时靠它区分"没跑完"与"跑完了"。
      'closed': start != null && !_open,
      // spec §11:采集时长 vs 5 分钟上限。
      'session_duration_sec': _round3(duration),
      // 所有 decision 档之和,占比的分母(读者不用自己逐项相加)。
      'decisions': _counts.values.fold<int>(0, (a, b) => a + b),
      // [2026-09-09] 判决顺序的**口径标签**。build 132 起,取图事务闸从第 5 位
      // (所有几何之前)后移到唯一 fire 出口的前一行 ⇒ 同一个
      // `decision_counts.skipAwaitingCapture` 的含义变了:
      //   ≤131 = "上一张还在飞"(几何根本没算,混着该拍与不该拍两种帧);
      //   ≥132 = "几何已经说开火、被在飞的上一张挡住"(优化取图事务的真上界)。
      // 不打标签就会把两种口径的同名计数混进一次分析里 —— 那是静默换口径。
      // 值随排序走,由 auto_capture_recon_decoupling_contract_test 与 governor
      // 的实际排版对拍。
      'decision_gate_order': 'geometry_before_awaiting_capture',
      // [2026-09-11] 地图口径接线的自证。tick 计数按口径分箱;三个量取各自
      // 的中位数(每 tick 都在变,聚合期只留分布的中点)。
      'evidence': <String, Object>{
        'ticks_tracks': _evidenceTicksTracks,
        'ticks_map': _evidenceTicksMap,
        'map_tracked_lms_p50': _percentile(_mapTrackedLms, 0.5),
        'map_reliable_lms_p50': _percentile(_mapReliableLms, 0.5),
        'map_reliable_lms_ref_p50': _percentile(_mapReliableLmsRef, 0.5),
      },
      // 地点识别:词典规模、每 tick 代价、命中的共享词比例(千分数)。
      // describe_us 是固定成本(GFTT+ORB),query_us 随词典规模涨 ——
      // 提速时先看哪一半更大。
      'place_recognition': <String, Object>{
        'sigs': _placeSigsLast,
        'words': _placeWordsLast,
        'scans': _placeDescribeMicros.length,
        'describe_us_p50': _percentile(_placeDescribeMicros, 0.5),
        'query_us_p50': _percentile(_placeQueryMicros, 0.5),
        'query_us_max': _maxOf(_placeQueryMicros),
        'best_ratio_permille_p50': _percentile(_placeBestRatioPermille, 0.5),
        'best_ratio_permille_max': _maxOf(_placeBestRatioPermille),
        // 后验与判决门:0.9 那道旧门够不到的那一格,靠这一层接住。
        'posterior_permille_p50': _percentile(_placePosteriorPermille, 0.5),
        'posterior_permille_max': _maxOf(_placePosteriorPermille),
        'loop_thr_permille': (kRtabmapLoopThreshold * 1000).round(),
        'loop_closures': _placeLoopClosures,
      },
      // spec §11:视差下限触发率 = decision_counts.skipNotMoved / decisions。
      'decision_counts': <String, int>{
        for (final e in _counts.entries) e.key.name: e.value,
      },
      'start_anchor_attempted': _startAnchorAttempted,
      'start_anchor_enqueued': _startAnchorEnqueued,
      'start_anchor_failed': _startAnchorFailed,
      // spec §7:开火 ≠ 拍成。两者分开记。
      'fire_enqueued': _fireEnqueued,
      'fire_enqueue_failed': _fireEnqueueFailed,
      // R2(重叠上限)提前触发的**下界**,见 recordDecision 里的推导。
      'fire_before_tick': _fireBeforeTick,
      'fire_role_counts': <String, int>{
        for (final e in _fireRoleCounts.entries) e.key.name: e.value,
      },
      'role_counts': <String, Object>{
        for (final e in _roleCounts.entries) e.key.name: e.value.snapshot(),
      },
      'predicate_counts': <String, Object>{
        for (final e in _roleCounts.entries)
          e.key.name: <String, int>{
            'true': e.value.eligible,
            'false': e.value.evaluated - e.value.eligible,
          },
      },
      'winner_decision_counts': <String, Object>{
        for (final e in _winnerDecisionCounts.entries)
          e.key.name: <String, int>{
            for (final decision in AutoCaptureDecision.values)
              decision.name: e.value[decision] ?? 0,
          },
      },
      'no_candidate': _noCandidate,
      'selected_none': _selectedNone,
      'fire_reason_counts': <String, int>{
        'segment_ready_only': _firesSegmentReadyOnly,
        'new_feature_burst_only': _firesNewFeatureBurstOnly,
        'both': _firesBothReady,
      },
      'selected_none_decision_counts': <String, int>{
        for (final decision in AutoCaptureDecision.values)
          decision.name: _selectedNoneDecisionCounts[decision] ?? 0,
      },
      'overlap_counts': <String, int>{
        'known': _overlapKnown,
        'unknown': _overlapUnknown,
      },
      'threshold_counts': <String, int>{
        'geometry_weak_10_deg': _geometryWeakThreshold,
        'geometry_normal_12_deg': _geometryNormalThreshold,
        'geometry_strong_15_deg': _geometryStrongThreshold,
        'geometry_other': _geometryOtherThreshold,
      },
      // 开火时刻的位移/阈值/转角/活体深度。**首/中/末三点**而不是均值 ——
      // 要抓的是趋势(上一版就是靠这个形状抓到深度整场撒谎的)。
      //
      // 一条也没采到时**整个键不出现**,而不是给 null 或 0:
      // 0 会被读成一句没人测过的断言,null 又进不了 Map<String, Object>。
      // 键的有无本身就是"这一轮有没有开过火"的信号。
      if (_triple(_fireMovedM) case final List<double> v) 'fire_moved_m': v,
      if (_triple(_fireDistM) case final List<double> v) 'fire_dist_m': v,
      if (_triple(_fireTurnDeg) case final List<double> v) 'fire_turn_deg': v,
      if (_triple(_fireLiveDepthM) case final List<double> v)
        'fire_live_depth_m': v,
      if (_triple(_fireSharpness) case final List<double> v)
        'fire_sharpness': v,
      if (_triple(_fireSegMedian) case final List<double> v)
        'fire_seg_median_sharpness': v,
      if (_triple(_fireGeometryParallaxDeg) case final List<double> v)
        'fire_geometry_parallax_deg': v,
      if (_triple(_fireOverlapFraction) case final List<double> v)
        'fire_overlap_fraction': v,
      if (_triple(_fireDepthScaleRatio) case final List<double> v)
        'fire_depth_scale_ratio': v,
      if (_triple(_fireVisualSimilarity) case final List<double> v)
        'fire_visual_similarity': v,
      if (_triple(_redundantVisualSimilarity) case final List<double> v)
        'redundant_visual_similarity': v,
      if (_triple(_fireTrackMedianNormalized) case final List<double> v)
        'fire_track_median_normalized_displacement': v,
      if (_triple(_redundantTrackMedianNormalized) case final List<double> v)
        'redundant_track_median_normalized_displacement': v,
      if (_triple(_fireTrackMedianStepPx) case final List<double> v)
        'fire_track_median_step_px': v,
      if (_triple(_redundantTrackMedianStepPx) case final List<double> v)
        'redundant_track_median_step_px': v,
      if (_triple(_fireSegmentMotionPx) case final List<double> v)
        'fire_segment_motion_px': v,
      if (_triple(_redundantSegmentMotionPx) case final List<double> v)
        'redundant_segment_motion_px': v,
      if (_segmentMotionThresholdPx case final double v)
        'segment_motion_threshold_px': _round3(v),
      if (_triple(_trackCommonFraction) case final List<double> v)
        'track_common_fraction': v,
      if (_triple(_trackCommonCount) case final List<double> v)
        'track_common_count': v,
      if (_triple(_visualSourceAgeSec) case final List<double> v)
        'visual_source_age_sec': v,
      // spec §11:ShutterPace 三档各停留多久(秒)= 积压严重程度。
      'pace_sec': <String, double>{
        for (final e in _paceSec.entries) e.key.name: _round3(e.value),
      },
    };
  }

  /// 秒取到毫秒。JSONL 是给人读的,`65.50000000000001` 只会碍事。
  static double _round3(double v) => (v * 1000).roundToDouble() / 1000;

  final List<double> _fireMovedM = <double>[];
  final List<double> _fireDistM = <double>[];
  final List<double> _fireTurnDeg = <double>[];
  final List<double> _fireLiveDepthM = <double>[];
  final List<double> _fireSharpness = <double>[];
  final List<double> _fireSegMedian = <double>[];
  final List<double> _fireGeometryParallaxDeg = <double>[];
  final List<double> _fireOverlapFraction = <double>[];
  final List<double> _fireDepthScaleRatio = <double>[];
  final List<double> _fireVisualSimilarity = <double>[];
  final List<double> _redundantVisualSimilarity = <double>[];
  final List<double> _fireTrackMedianNormalized = <double>[];
  final List<double> _redundantTrackMedianNormalized = <double>[];
  final List<double> _fireTrackMedianStepPx = <double>[];
  final List<double> _redundantTrackMedianStepPx = <double>[];
  final List<double> _fireSegmentMotionPx = <double>[];
  final List<double> _redundantSegmentMotionPx = <double>[];
  double? _segmentMotionThresholdPx;
  final List<double> _trackCommonFraction = <double>[];
  final List<double> _trackCommonCount = <double>[];
  final List<double> _visualSourceAgeSec = <double>[];

  /// 序列的**首 / 中 / 末**三个值(按发生顺序,不排序)。
  ///
  /// 刻意不给均值或分位:要抓的是「轮内单调走低」,那是一个**趋势**,
  /// 任何把顺序抹掉的统计量都看不见它。空序列给 null,不给 0 ——
  /// 0 会被读成"深度是 0",那是一句没人测过的断言。
  static List<double>? _triple(List<double> xs) {
    if (xs.isEmpty) return null;
    return <double>[
      _round3(xs.first),
      _round3(xs[xs.length ~/ 2]),
      _round3(xs.last),
    ];
  }
}
