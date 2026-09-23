// focus_self_heal.dart —— **对焦自愈环**的判定循环(纯 Dart,四端同一份)。
//
// ══ 这是生产 `[AF-SELFHEAL 2026-08-10 用户签]` 那一套的移植 ════════════════
// 生产原件两处:
//   · 判定:`lib/ui/official_capture/ar_capture_page.dart:512-563`
//           (`_afSelfHealCheck`,本文件**逐条对照**它,行号标在每个判据上)
//   · 执行:`ios/Runner/OfficialAetherARKitPlugin.swift:1418-1445`(`focusNudge`)
//
// 生产 `:1418` 注释原话,定了分工,本文件照办:
//     「判定循环全在 Dart(持续糊+静止+节流,**跨端同式**);这里只执行一脚:
//       中心单次对焦(强制扫描打破死锁)→ 1.2s 后自动回连续。」
// ⇒ 本文件**不碰任何平台 API**,执行那一脚由 [FocusNudger] 注入;iOS 的实现是
//   `lib/vio/ffi/pw_focus_ffi.dart` 的 `PwFocusFfiNudger`(FFI →
//   `pw_camera_slot_focus_nudge` → `PwFocusArms.nudge()`),Android / HarmonyOS /
//   Web 各写一个同形状的实现即可,判定这一份不再动。
//
// ══ 病灶(生产注释原话,抄在这里免得后人以为是玄学)═════════════════════════
//     「糊掉的低纹理画面无相位信号无反差梯度 → 连续 AF 收不到失焦证据不触发
//       扫描(健身房跑步机 10s+ 实测)；ARKit 又刻意压制对焦频率(对焦呼吸伤
//       VIO)。」
// 连续 AF **不是**万能的:它靠「看见自己失焦」才动,而白墙/低纹理正好让它看
// 不见。自愈环就是从外面给它一个「你该扫了」的硬信号。
//
// ══ 🔴 三个判据里两个逐字照抄,一个**必须换**(裁判换了,量纲也就换了)═══════
//   ① 持续糊 ≥1800 ms   —— 时间量,与度量无关 ⇒ **逐字照抄**
//   ② 相机基本静止       —— 位姿量,与度量无关 ⇒ **逐字照抄**(含 400/900 ms
//                           的采样刷新与 0.06 m / 0.10 rad 两个阈值)
//   ③ 「糊」怎么判        —— 🔴 **换裁判**:生产用 `sharpnessConsensus < 100.0`
//                           (128×128 缩略图上的 Laplacian 方差共识,6 Hz);
//                           我们用 `pw_af` 的 **Tenengrad**(被扫物体框内,
//                           随相机帧 30 Hz)。
//
// 为什么换裁判(三条,缺一不可):
//   (a) **更高频**:6 Hz ⇒ 1800 ms 只有 ~11 个样本;30 Hz ⇒ ~54 个。判「持续糊」
//       这种要看住一整段的事,样本密度直接决定会不会被一两帧噪声带偏。
//   (b) **能框物体**:`sharpnessConsensus` 量的是整张 128×128 缩略图;Tenengrad
//       量的是 `PwAfDefaultRoiC` 那个框(libcamera `af.cpp:313-321` 的默认 AF
//       窗口),与对焦区域(`focusRectOfInterest`/`focusPointOfInterest`)、与
//       快门前那一次对焦用的是**同一个矩形**。任务书「最上游输入必须清晰 ——
//       目标是被拍物体清晰」⇒ 判据必须落在物体上,不能被背景稀释。
//   (c) **已知盲区有互补件**:3×3 Sobel 在 1 px 条纹上恒 0(奇偶盲区,
//       `vendor/pw_af` 的单测钉住了这条),SquaredGradient 与它互补 ——
//       盲区是**已知且可换算子**的,而 `sharpnessConsensus` 那条路我们连换算子
//       的口子都没有。
//
// ══ 🔴🔴 换了裁判 ⇒ **阈值不能照搬**,这是我们的偏离,理由单独写在这里 ═════
// `sharpnessConsensus < 100.0` 里那个 100 是**那一个度量在那一个尺寸上的**经验
// 绝对值。Tenengrad 是梯度平方和的均值,量纲、尺度、对分辨率与亮度的依赖全都
// 不同 —— 把 100 抄过来是拿一把尺子的刻度读另一把尺子。
//
// 所以判据改成**无量纲**的:
//
//     糊  ⟺  measure + 1.0  <  retriggerRatio × sceneReference
//
// 这两样都**不是我编的**,是从已复刻的上游原件里取的:
//   · 式子的形状与那个 `+ 1.0` 的零保护 —— `vendor/pw_af/af_scan.cpp:227`
//     (libcamera `af.cpp` 的 `contrast + 1.0 < ratio * oldSceneContrast_`);
//   · `retriggerRatio = 0.8` —— `vendor/pw_af/af_scan.cpp:77`(libcamera
//     `af.h:97` 的 `SpeedDependentParams::retriggerRatio`,normal 档官方值)。
//     上游用它判「场景变了,该重扫了」;我们要判的「连续 AF 该被踢一脚了」是
//     同一件事的同一个方向。
//
// 参考值 `sceneReference` 是**我们的偏离**,理由:上游那个 `oldSceneContrast_`
// 是「**上一次扫描落定那一刻**的对比度」,而我们不驱动镜头、拿不到扫描事件。
// 最接近的等价物是苹果自己宣布的落定:`AVCaptureDevice.isAdjustingFocus`
// 由 true→false(头文件原文:"Clients can observe the value of this property to
// determine whether the camera's focus is stable.")。所以:
//   · `isAdjustingFocus` 真→假  ⇒  `sceneReference := 当前度量`(对应上游在扫描
//     结束时写 `oldSceneContrast_`);
//   · 任何时候 `度量 > sceneReference`  ⇒  抬高它(上游的重触发判据是**双向**的,
//     「比参考还清晰」那一侧上游也会重扫;我们不需要在更清晰时踢一脚,于是把那
//     一侧折叠成「参考过时了,抬上去」——**这是我们的第二处偏离**)。
//   · 一次落定都还没发生过时,参考值就等于开机以来的度量峰值(冷启动兜底)。
//
// 这条判据**能报警也能失败**:参考值为 0(相机没起/符号不在)时永远判不糊,
// 不会凭空踢;参考值被落定压低后也会自己停下来,不会变成 5 秒一脚的踢腿机。
// (feedback_verify_with_a_metric_that_can_fail:判据必须能对我要排除的失效
//  模式报警,也必须能在没病时保持沉默。)

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// 「踢一脚」的执行器。**四端各写一个**,判定循环那一份永远不动。
///
/// 语义与生产一致:**下发即返回,不等对焦结果**(生产 `ar_capture_page.dart:556`
/// 是 `unawaited(invokeMethod('focusNudge'))` —— 它也不等)。返回 true 表示
/// 「已下发」,不是「已对上」。
abstract class FocusNudger {
  /// 下发一次「中心/物体框一次性对焦 → 限时回连续」。
  bool nudge();

  /// 写进 manifest 的一句话:这一脚是谁执行的。
  String get describe;
}

/// 永远不下发的执行器。用于 A 臂(阴性对照)、符号不在、单测的阴性对照。
class NoopFocusNudger implements FocusNudger {
  const NoopFocusNudger(this.describe);

  @override
  final String describe;

  @override
  bool nudge() => false;
}

/// 一次自愈事件(踢一脚)的完整现场。manifest 里按时间序记一串。
class FocusNudgeEvent {
  FocusNudgeEvent({
    required this.index,
    required this.atMs,
    required this.measureAtTrigger,
    required this.referenceAtTrigger,
    required this.blurHeldMs,
    required this.dispatched,
  });

  /// 第几次(从 1 起)。
  final int index;

  /// 触发时刻(与喂进来的 `nowMs` 同域)。
  final int atMs;

  /// 🔴 触发那一刻的度量(Tenengrad ROI 均值)。
  final double measureAtTrigger;

  /// 触发那一刻的参考值。`measureAtTrigger / referenceAtTrigger` 就是「糊到
  /// 什么程度」,可直接与 0.8 那条线对照。
  final double referenceAtTrigger;

  /// 触发前已经连续糊了多久(毫秒)。应 ≥ [FocusSelfHeal.kBlurHoldMs]。
  final int blurHeldMs;

  /// 执行器是否受理(A 臂 / 符号不在 ⇒ false)。
  final bool dispatched;

  /// 动作后观察窗内的度量峰值(窗口 = [FocusSelfHeal.kAfterWindowMs])。
  double? measurePeakAfter;

  /// 观察窗关闭那一刻的度量与实际经过的毫秒数。
  double? measureAfter;
  int? measureAfterMs;

  /// 观察窗是否已关闭(整场结束时仍未关的会留 null,不补)。
  bool get closed => measureAfterMs != null;

  /// 动作后峰值 ÷ 触发时度量。> 1 表示这一脚之后确实变清晰了。
  double? get gainPeak {
    final double? p = measurePeakAfter;
    if (p == null || measureAtTrigger <= 0) return null;
    return p / measureAtTrigger;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'index': index,
        'at_ms': atMs,
        'measure_at_trigger': measureAtTrigger,
        'reference_at_trigger': referenceAtTrigger,
        'ratio_at_trigger':
            referenceAtTrigger > 0 ? measureAtTrigger / referenceAtTrigger : null,
        'blur_held_ms': blurHeldMs,
        'dispatched': dispatched,
        'measure_peak_after': measurePeakAfter,
        'measure_after': measureAfter,
        'measure_after_ms': measureAfterMs,
        'gain_peak': gainPeak,
      };
}

/// 对焦自愈环的判定循环。**纯 Dart、无平台依赖、可单测。**
///
/// 用法:每一帧位姿喂一次 [onSample];它自己判「持续糊 + 静止 + 节流」,
/// 到条件了调 [FocusNudger.nudge] 并记一条 [FocusNudgeEvent]。
class FocusSelfHeal {
  FocusSelfHeal({
    required FocusNudger nudger,
    this.blurHoldMs = kBlurHoldMs,
    this.throttleMs = kThrottleMs,
    this.retriggerRatio = kRetriggerRatio,
    this.afterWindowMs = kAfterWindowMs,
  }) : _nudger = nudger;

  // ── ① 与 ② 的阈值:逐字抄生产 `ar_capture_page.dart` ────────────────────
  /// 持续糊多久才踢。生产 `:551` 的 `now - _afBlurSinceMs >= 1800`。
  static const int kBlurHoldMs = 1800;

  /// 两脚之间的最小间隔。生产 `:551` 的 `now - _afLastNudgeMs >= 5000`。
  static const int kThrottleMs = 5000;

  /// 位姿采样多久刷新一次。生产 `:539` 的 `now - _afPrevPoseMs > 400`。
  static const int kPoseRefreshMs = 400;

  /// 位姿采样超过多久就不能用来判静止。生产 `:527` 的 `now - _afPrevPoseMs <= 900`。
  static const int kPoseMaxAgeMs = 900;

  /// 静止判据:两次采样之间位移上限(米)。生产 `:537` 的 `moved < 0.06`。
  static const double kStationaryMoveM = 0.06;

  /// 静止判据:两次采样之间转角上限(弧度)。生产 `:537` 的 `angle < 0.10`。
  /// (0.10 rad ≈ 5.73°;生产注释写「<6°」,以代码为准。)
  static const double kStationaryAngleRad = 0.10;

  // ── ③ 的阈值:🔴 我们的偏离,来源见文件头 ────────────────────────────────
  /// `vendor/pw_af/af_scan.cpp:77`(libcamera `af.h:97` normal 档官方值)。
  static const double kRetriggerRatio = 0.8;

  /// 踢一脚之后回看多久(毫秒)。**我们自己定的观察窗**,不是判据的一部分,
  /// 只用于把「这一脚有没有用」记进 manifest。2 s > 生产 1.2 s 的回连续延时,
  /// 所以窗口一定盖得住「一次性对焦 + 回连续」的整段。
  static const int kAfterWindowMs = 2000;

  final FocusNudger _nudger;
  final int blurHoldMs;
  final int throttleMs;
  final double retriggerRatio;
  final int afterWindowMs;

  // ── 状态(字段名与生产 `_af*` 一一对应,便于逐行对照)──
  int _blurSinceMs = 0;
  int _lastNudgeMs = 0;
  Vector3? _prevPos;
  Quaternion? _prevOrient;
  int _prevPoseMs = 0;

  double _reference = 0;
  bool _sawSettle = false;
  bool _prevAdjusting = false;
  double _lastMeasure = 0;
  bool _lastStationary = false;
  bool _lastBlurred = false;
  int _samples = 0;

  final List<FocusNudgeEvent> _events = <FocusNudgeEvent>[];
  FocusNudgeEvent? _pending;

  /// 已踢的次数。
  int get nudgeCount => _events.length;

  /// 执行器真的受理了几次(A 臂 / 符号不在时会小于 [nudgeCount])。
  int get dispatchedCount =>
      _events.where((FocusNudgeEvent e) => e.dispatched).length;

  /// 上一次踢的时刻;从没踢过是 null(**不是 0** —— 生产内部用 0 当「从没踢过」
  /// 是为了让第一脚不被节流挡住,那个语义留在内部,对外别混)。
  int? get lastNudgeMs => _events.isEmpty ? null : _lastNudgeMs;

  /// 当前参考值(见文件头:落定时重置、更清晰时抬高)。
  double get sceneReference => _reference;

  /// 最近一次喂进来的度量。
  double get lastMeasure => _lastMeasure;

  /// 最近一次判定:是否判糊 / 是否判静止。
  bool get lastBlurred => _lastBlurred;
  bool get lastStationary => _lastStationary;

  /// 当前已连续糊了多久(毫秒);没在糊是 0。
  int blurHeldMs(int nowMs) => _blurSinceMs == 0 ? 0 : nowMs - _blurSinceMs;

  /// 距上次踢多久(毫秒);从没踢过是 null。
  int? msSinceLastNudge(int nowMs) =>
      _events.isEmpty ? null : nowMs - _lastNudgeMs;

  List<FocusNudgeEvent> get events => List<FocusNudgeEvent>.unmodifiable(_events);

  /// 喂一帧。**逐条对照生产 `_afSelfHealCheck`(`ar_capture_page.dart:519-563`)**。
  ///
  /// - [nowMs] 单调毫秒(生产用 `DateTime.now().millisecondsSinceEpoch`)。
  /// - [focusMeasure] Tenengrad ROI 均值(生产那一格是 `q.sharpnessConsensus`)。
  /// - [isAdjustingFocus] 苹果自报的「镜头正在动」。生产没有这一格 —— 我们用它
  ///   的真→假当「扫描落定」,替上游的 `oldSceneContrast_` 更新时机。
  /// - [position] / [orientation] 相机位姿;任一为 null ⇒ 这一帧判不了静止
  ///   (与生产「没有前一帧就 stationary=false」同向:宁可不踢)。
  ///
  /// 返回本帧是否踢了一脚。
  bool onSample({
    required int nowMs,
    required double focusMeasure,
    required bool isAdjustingFocus,
    Vector3? position,
    Quaternion? orientation,
  }) {
    _samples++;
    _lastMeasure = focusMeasure;

    // ── 参考值的维护(🔴 我们的偏离,理由见文件头)────────────────────────
    // 苹果宣布落定(true→false)⇒ 参考值重置到落定值,对应上游在扫描结束时
    // 写 `oldSceneContrast_`(`af_scan.cpp:253-262`)。
    if (_prevAdjusting && !isAdjustingFocus) {
      _reference = focusMeasure;
      _sawSettle = true;
    } else if (focusMeasure > _reference) {
      // 比参考还清晰 ⇒ 参考过时了,抬上去(上游那一侧是「双向重触发」)。
      _reference = focusMeasure;
    }
    _prevAdjusting = isAdjustingFocus;

    // ── 动作后的观察窗(只为 manifest,不参与判定)────────────────────────
    final FocusNudgeEvent? pending = _pending;
    if (pending != null) {
      final double? peak = pending.measurePeakAfter;
      if (peak == null || focusMeasure > peak) {
        pending.measurePeakAfter = focusMeasure;
      }
      if (nowMs - pending.atMs >= afterWindowMs) {
        pending.measureAfter = focusMeasure;
        pending.measureAfterMs = nowMs - pending.atMs;
        _pending = null;
      }
    }

    // ── ② 静止:逐字抄生产 `:521-544` ───────────────────────────────────────
    bool stationary = false;
    final Vector3? prevPos = _prevPos;
    final Quaternion? prevOri = _prevOrient;
    if (prevPos != null &&
        prevOri != null &&
        position != null &&
        orientation != null &&
        nowMs - _prevPoseMs <= kPoseMaxAgeMs) {
      final double moved = (position - prevPos).length;
      final double dot = (orientation.w * prevOri.w +
              orientation.x * prevOri.x +
              orientation.y * prevOri.y +
              orientation.z * prevOri.z)
          .abs()
          .clamp(0.0, 1.0);
      final double angle = 2 * math.acos(dot);
      stationary = moved < kStationaryMoveM && angle < kStationaryAngleRad;
    }
    if (position != null &&
        orientation != null &&
        nowMs - _prevPoseMs > kPoseRefreshMs) {
      _prevPos = position.clone();
      _prevOrient = Quaternion.copy(orientation);
      _prevPoseMs = nowMs;
    }
    _lastStationary = stationary;

    // ── ③ 糊:🔴 换了裁判,判据无量纲(理由与出处见文件头)───────────────
    //    形状抄 `vendor/pw_af/af_scan.cpp:227`:`contrast + 1.0 < ratio * ref`。
    final bool blurred =
        _reference > 0 && focusMeasure + 1.0 < retriggerRatio * _reference;
    _lastBlurred = blurred;
    if (!blurred) {
      _blurSinceMs = 0; // 生产 `:548`
      return false;
    }
    if (!stationary) return false; // 生产 `:549`:移动中的糊是运动模糊,不踢

    // ── ① 持续 + 节流:逐字抄生产 `:550-551` ────────────────────────────────
    _blurSinceMs = _blurSinceMs == 0 ? nowMs : _blurSinceMs;
    final int held = nowMs - _blurSinceMs;
    if (held < blurHoldMs) return false;
    if (nowMs - _lastNudgeMs < throttleMs) return false;

    _lastNudgeMs = nowMs;
    _blurSinceMs = 0; // 生产 `:553`
    final bool dispatched = _nudger.nudge();
    final FocusNudgeEvent ev = FocusNudgeEvent(
      index: _events.length + 1,
      atMs: nowMs,
      measureAtTrigger: focusMeasure,
      referenceAtTrigger: _reference,
      blurHeldMs: held,
      dispatched: dispatched,
    );
    _events.add(ev);
    _pending = ev;
    return true;
  }

  /// manifest 里 `focus.self_heal` 那一块。
  Map<String, Object?> toJson() => <String, Object?>{
        'what': '对焦自愈环(生产 [AF-SELFHEAL 2026-08-10 用户签] 的移植)',
        'ported_from': <String, Object?>{
          'judge': 'lib/ui/official_capture/ar_capture_page.dart:512-563'
              '(_afSelfHealCheck;持续糊 + 静止 + 节流,跨端同式)',
          'executor': 'ios/Runner/OfficialAetherARKitPlugin.swift:1418-1445'
              '(focusNudge;一次性对焦 → 1.2 s 回连续)',
        },
        'executor': _nudger.describe,
        'verbatim_thresholds': <String, Object?>{
          'blur_hold_ms': blurHoldMs,
          'throttle_ms': throttleMs,
          'pose_refresh_ms': kPoseRefreshMs,
          'pose_max_age_ms': kPoseMaxAgeMs,
          'stationary_move_m': kStationaryMoveM,
          'stationary_angle_rad': kStationaryAngleRad,
          'note': '这五个是时间量/位姿量,与度量无关 ⇒ 逐字抄生产,一个数没改。',
        },
        'deviation_blur_criterion': <String, Object?>{
          'production': 'sharpnessConsensus < 100.0(128×128 Laplacian 方差共识,6 Hz)',
          'ours': 'measure + 1.0 < $retriggerRatio × sceneReference'
              '(pw_af Tenengrad,被扫物体 ROI,随相机帧 30 Hz)',
          'why_changed': '更高频(6→30 Hz)、能框住被扫物体(不被背景稀释)、'
              '已知盲区有互补算子(3×3 Sobel 在 1 px 条纹上恒 0,SquaredGradient 互补)',
          'why_threshold_cannot_be_copied':
              '🔴 两个度量量纲不同 —— 100 是 sharpnessConsensus 在 128×128 上的经验'
              '绝对值,Tenengrad 是梯度平方和均值,抄过来等于拿一把尺子的刻度读另一把。',
          'ratio_source': 'retriggerRatio = $kRetriggerRatio —— '
              'vendor/pw_af/af_scan.cpp:77(libcamera af.h:97,normal 档官方值)',
          'form_source': 'measure + 1.0 < ratio × reference —— '
              'vendor/pw_af/af_scan.cpp:227(libcamera 的零保护写法,逐字)',
          'reference_source':
              '🔴 我们的偏离:上游参考值是「上次扫描落定那一刻的对比度」,我们不驱动'
              '镜头拿不到扫描事件 ⇒ 改用 isAdjustingFocus 真→假(苹果自报落定,'
              'AVCaptureDevice.h 原文 "determine whether the camera\'s focus is stable")'
              '那一刻的度量;另外「度量 > 参考」时抬高参考(上游重触发是双向的,'
              '更清晰那一侧我们折叠成抬参考,不踢)。一次落定都没发生过时用开机以来的峰值兜底。',
        },
        'after_window_ms': afterWindowMs,
        'after_window_note':
            '踢一脚之后回看多久。**不是判据**,只为把「这一脚有没有用」记下来;'
            '2 s > 执行器 1.2 s 的回连续延时 ⇒ 一定盖得住整段动作。',
        'samples_fed': _samples,
        'saw_focus_settle': _sawSettle,
        'scene_reference_at_finish': _reference,
        'nudges': _events.length,
        'nudges_dispatched': dispatchedCount,
        'events': _events.map((FocusNudgeEvent e) => e.toJson()).toList(),
      };
}
