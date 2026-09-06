// auto_capture_page_wiring_test.dart — T4「接线」的守门。
//
// 这里测的是**接线契约**,不是像素。分三层:
//
//  ① 纯映射(auto_capture_mode.dart):指示器状态、起跑判据、文案。可以真跑。
//  ② 行为(真 ManualCaptureQueue + 真 AutoCaptureController):把页面的两处
//     接线口径拿真对象跑一遍,并**同时跑错误口径做对照** —— 只断言"正确的那条
//     能过"证明不了什么,得证明"错的那条真的会坏"。
//  ③ 源码契约(ar_capture_page.dart 逐段 grep):页面当前**编译不过**
//     (HEAD 上就有 8 个与本功能无关的 undefined_method/undefined_class,
//     见报告),widget test 起不来,所以页面里那部分只能靠源码断言钉住。
//     这一层的每一条都对应评审点出的一个静默失效路径。

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_mode.dart';
import 'package:pocketworld_flutter/official_capture/live_sfm_publish_policy.dart'
    show kOfficialMaximumCaptureFrames;
import 'package:pocketworld_flutter/official_capture/auto_capture_telemetry.dart';
import 'package:pocketworld_flutter/official_capture/manual_capture_queue.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

const int _w = 1000;
const int _h = 1000;
const double _fx = 1000;

FrameQualityReport _quality(double t) => FrameQualityReport(
  sharpness: 300,
  roiSharpness: 300,
  multiScaleSharpness252: 300,
  multiScaleSharpness512: 300,
  edgeBlockSharpness: 300,
  backgroundSharpness: 300,
  subjectVsBackgroundSharpnessDelta: 0,
  sharpnessConsensus: 300,
  meanBrightness: 128,
  globalVariance: 100,
  signature: Uint8List.fromList(<int>[
    for (var i = 0; i < 256; i++) ((t * 1000003).round() + i * 73) & 0xff,
  ]),
  signatureWidth: 16,
  signatureHeight: 16,
);

/// 相机在 [pos],朝向由绕 Y 轴的 [yawDeg] 决定(0 = 看向 -Z)。
///
/// 这套参数下几何是可心算的:深度 1 m、fx = 画幅宽 = 1000 ⇒ 侧移 d 米时
/// 归一化中心偏移 sx == d(纵向 0),于是 §5.2 的重叠上限 0.30 就是"侧移 30 cm"。
/// 下面所有位移数字都据此挑选,不是拍脑袋。
ARPose _pose({
  required double t,
  Vector3? pos,
  double yawDeg = 0,
  double depthM = 1.0,
}) {
  final p = pos ?? Vector3.zero();
  final q = Quaternion.axisAngle(Vector3(0, 1, 0), yawDeg * math.pi / 180);
  final forward = q.rotated(Vector3(0, 0, -1));
  final target = p + forward * depthM;
  return ARPose(
    position: p,
    orientation: q,
    azimuth: 0,
    elevation: 0,
    isTracking: true,
    trackingStateName: 'normal',
    timestamp: t,
    hasOrigin: true,
    worldOrigin: Vector3.zero(),
    worldYaw: 0,
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: const <double>[_fx, _fx, _w / 2, _h / 2],
    imageWidth: _w,
    imageHeight: _h,
    quality: _quality(t),
    previewPoints: <ARPreviewPoint>[
      for (var i = 0; i < 12; i++)
        ARPreviewPoint(
          position: target + Vector3(i * 0.001, 0, 0),
          r: 0,
          g: 0,
          b: 0,
          confidence: 1,
        ),
    ],
  );
}

/// 页面接线的最小复刻:一个**真**的 ManualCaptureQueue + 一个**真**的
/// AutoCaptureController,中间那两根线(onFire 的返回值口径、已拍张数口径)
/// 由构造参数选,这样正确口径与错误口径能跑同一条输入。
class _WiredHost {
  _WiredHost({
    required this.reportRealEnqueueResult,
    required this.countsInFlight,
    this.telemetry,
  }) {
    queue = ManualCaptureQueue(
      maxTickets: kOfficialMaximumCaptureFrames,
      // 执行体永不推进:同步的测试体里 microtask 不会被抽干,所以票会一直
      // 挂在队列上 —— 这正是"在途票"的真实形态。
      execute: (ManualCaptureTicket t) async {
        heldForever.add(t);
      },
    );
  }

  /// true = 页面的口径:`enqueue(...) != null`,入队失败如实上报。
  /// false = 评审点名的那条歪路:`{ _onShutterTap(); return true; }`。
  final bool reportRealEnqueueResult;

  /// true = 页面的口径:`_projectPhotos.count + _shutterQueue.outstandingCount`。
  /// false = 少算在途票的那条歪路,只报已落库张数。
  final bool countsInFlight;

  /// 挂上就把**真实**入队结果喂给它 —— 与页面的 onFire 钩子同一个位置
  /// (全链路唯一分得开"开了一枪"与"拍成了"的地方)。null = 不记遥测。
  final AutoCaptureTelemetry? telemetry;

  late final ManualCaptureQueue queue;
  final List<ManualCaptureTicket> heldForever = <ManualCaptureTicket>[];

  /// 已落库张数(= 页面的 `_projectPhotos.count`)。执行体不推进,所以恒 0。
  int verified = 0;
  int admitted = 0;
  int fireAttempts = 0;

  late final AutoCaptureController controller = AutoCaptureController(
    onStartAnchor: () => true,
    onFire: () {
      fireAttempts++;
      final ticket = queue.enqueue(verifiedCount: verified);
      if (ticket != null) admitted++;
      telemetry?.recordFireOutcome(enqueued: ticket != null);
      return reportRealEnqueueResult ? ticket != null : true;
    },
    paceProvider: () => ShutterPace.normal,
    capturedCountProvider: () =>
        countsInFlight ? verified + queue.outstandingCount : verified,
    thermalStateProvider: () => 0, // nominal:接线口径的对照与热态无关
    // 接线口径与活体深度无关:null ⇒ 兜底位移 0.10m(governor 的常数)。
    liveDepthProvider: (_) => null,
  );

  /// 驱动一帧并模拟"照片瞬间拍成"(页面在快门事务完成时回调
  /// onCaptureCompleted;台架里没有原生事务,等价于立即完成)。
  AutoCaptureDecision tick(ARPose pose) {
    final before = admitted;
    final d = controller.onPose(pose);
    // 只有真的入了队(拍了)才有"拍成"回调;入队失败的那一枪没有照片。
    if (d == AutoCaptureDecision.fire && admitted > before) {
      controller.onCaptureCompleted(captureTimestampSec: pose.timestamp);
    }
    return d;
  }
}

String _pageSource() =>
    File('lib/ui/official_capture/ar_capture_page.dart').readAsStringSync();

/// 取 [open] 之后、[close] 之前的那一段源码。两个锚点都必须存在且有序,
/// 否则断言的是空串 —— 那是最经典的假守门。
String _section(String source, String open, String close) {
  final start = source.indexOf(open);
  expect(start, greaterThanOrEqualTo(0), reason: 'anchor not found: $open');
  final end = source.indexOf(close, start + open.length);
  expect(
    end,
    greaterThan(start),
    reason: 'anchor not found after $open: $close',
  );
  return source.substring(start, end);
}

/// 回读 [anchor] 在 build 里**自己**那条 `only(top: N)` 的 N。
///
/// 不数字面量出现次数:那种断言换个位置就骗过去了。
int _bandOf(String source, String anchor) {
  final at = source.indexOf(anchor);
  expect(at, greaterThanOrEqualTo(0), reason: 'anchor not found: $anchor');
  final before = RegExp(
    r'only\(top: (\d+)\)',
  ).allMatches(source.substring(0, at));
  expect(before, isNotEmpty, reason: 'no band above $anchor');
  return int.parse(before.last.group(1)!);
}

void main() {
  // ─── ① 纯映射 ────────────────────────────────────────────────────────

  group('autoCaptureIndicatorFor', () {
    test('not running maps skipNotMoved to idle, never to waiting', () {
      // 这是本功能最容易静默错的一处:停机后 onPose 的返回值就是
      // skipNotMoved,与"你还没动够"逐字相同。照着返回值画指示器,一次
      // 已经结束的采集会永远显示"在等你动"。
      expect(
        autoCaptureIndicatorFor(
          running: false,
          decision: AutoCaptureDecision.skipNotMoved,
        ),
        AutoCaptureIndicator.idle,
      );
    });

    test('running maps skipNotMoved to waiting', () {
      // 上一条的对称孪生:同一个 decision,只有 running 变了,结论必须变。
      expect(
        autoCaptureIndicatorFor(
          running: true,
          decision: AutoCaptureDecision.skipNotMoved,
        ),
        AutoCaptureIndicator.waiting,
      );
    });

    test('running maps fire to pulse', () {
      expect(
        autoCaptureIndicatorFor(
          running: true,
          decision: AutoCaptureDecision.fire,
        ),
        AutoCaptureIndicator.pulse,
      );
    });

    test('not running maps fire to idle, never to pulse', () {
      // 对称孪生:fire 也不许在停机态被画成脉冲。
      expect(
        autoCaptureIndicatorFor(
          running: false,
          decision: AutoCaptureDecision.fire,
        ),
        AutoCaptureIndicator.idle,
      );
    });

    test('running maps paced and tracking and both caps to steady', () {
      // spec §8:节奏被拉长不额外表达;丢跟踪与到顶也不借指示器说话。
      for (final d in <AutoCaptureDecision>[
        AutoCaptureDecision.skipPaced,
        AutoCaptureDecision.skipTracking,
        AutoCaptureDecision.skipCapped,
        AutoCaptureDecision.skipTimeLimit,
      ]) {
        expect(
          autoCaptureIndicatorFor(running: true, decision: d),
          AutoCaptureIndicator.steady,
          reason: '$d',
        );
      }
    });

    test(
      'every decision value is mapped, and none maps to idle while running',
      () {
        // 将来给 AutoCaptureDecision 加枚举值时,switch 不穷尽会**编译失败**;
        // 这条再守一层运行期语义:跑着的时候永远不该退回 idle。
        for (final d in AutoCaptureDecision.values) {
          expect(
            autoCaptureIndicatorFor(running: false, decision: d),
            AutoCaptureIndicator.idle,
            reason: 'stopped: $d',
          );
          expect(
            autoCaptureIndicatorFor(running: true, decision: d),
            isNot(AutoCaptureIndicator.idle),
            reason: 'running: $d',
          );
        }
      },
    );
  });

  group('autoCaptureCanStart', () {
    test('all four preconditions true starts', () {
      expect(
        autoCaptureCanStart(
          captureReady: true,
          queueAccepting: true,
          withinFrameBudget: true,
          posesFlowing: true,
        ),
        isTrue,
      );
    });

    test('capture not ready blocks start', () {
      expect(
        autoCaptureCanStart(
          captureReady: false,
          queueAccepting: true,
          withinFrameBudget: true,
          posesFlowing: true,
        ),
        isFalse,
      );
    });

    test('queue no longer accepting blocks start', () {
      // 收尾流程 freezeAndDrain / cancelPending 之后必须起不来。
      expect(
        autoCaptureCanStart(
          captureReady: true,
          queueAccepting: false,
          withinFrameBudget: true,
          posesFlowing: true,
        ),
        isFalse,
      );
    });

    test('frame budget exhausted blocks start', () {
      expect(
        autoCaptureCanStart(
          captureReady: true,
          queueAccepting: true,
          withinFrameBudget: false,
          posesFlowing: true,
        ),
        isFalse,
      );
    });

    test('no pose yet blocks start', () {
      expect(
        autoCaptureCanStart(
          captureReady: true,
          queueAccepting: true,
          withinFrameBudget: true,
          posesFlowing: false,
        ),
        isFalse,
      );
    });
  });

  group('autoCaptureRecordButtonEnabled', () {
    test(
      'running stays tappable even when every start precondition is gone',
      () {
        // 用户必须永远能按停。用同一条判据给停止键置灰 = 把用户关在自动模式里。
        expect(
          autoCaptureRecordButtonEnabled(running: true, canStart: false),
          isTrue,
        );
      },
    );

    test('not running follows canStart — false', () {
      expect(
        autoCaptureRecordButtonEnabled(running: false, canStart: false),
        isFalse,
      );
    });

    test('not running follows canStart — true', () {
      expect(
        autoCaptureRecordButtonEnabled(running: false, canStart: true),
        isTrue,
      );
    });
  });

  group('copy (spec §8.1)', () {
    test('top hint differs per mode and neither is empty', () {
      final manual = autoCaptureTopHintText(OfficialCaptureMode.manual);
      final auto = autoCaptureTopHintText(OfficialCaptureMode.auto);
      expect(manual, isNotEmpty);
      expect(auto, isNotEmpty);
      expect(manual, isNot(auto));
    });

    test('auto shutter hint switches to stop semantics once running', () {
      final idle = autoCaptureShutterHintText(
        mode: OfficialCaptureMode.auto,
        running: false,
      );
      final running = autoCaptureShutterHintText(
        mode: OfficialCaptureMode.auto,
        running: true,
      );
      expect(idle, isNot(running));
      expect(idle, contains('开始'));
      expect(running, contains('停止'));
    });

    test('low-overlap warning asks the user to slow down', () {
      final warning = autoCaptureShutterHintText(
        mode: OfficialCaptureMode.auto,
        running: true,
        shouldPromptSlowDown: true,
      );
      expect(warning, contains('减速'));
    });

    test(
      'manual shutter hint ignores running — there is no auto run in manual',
      () {
        expect(
          autoCaptureShutterHintText(
            mode: OfficialCaptureMode.manual,
            running: false,
          ),
          autoCaptureShutterHintText(
            mode: OfficialCaptureMode.manual,
            running: true,
          ),
        );
      },
    );

    test('mode toast text is the RealityScan "Auto Capture On" equivalent', () {
      expect(kAutoCaptureOnToastText, '自动拍摄已开启');
    });
  });

  test('autoCaptureTickIntervalSec covers every ShutterPace value', () {
    // 若将来给 ShutterPace 加档,governor 里的 switch 未覆盖会编译失败。
    for (final p in ShutterPace.values) {
      expect(
        autoCaptureTickIntervalSec(pace: p, thermalState: 0),
        greaterThan(0),
      );
    }
  });

  group('pressure and thermal are telemetry-only', () {
    test('every pressure/thermal combination keeps the 250ms floor', () {
      for (final pace in ShutterPace.values) {
        for (final thermal in <int>[-1, 0, 1, 2, 3]) {
          expect(
            autoCaptureTickIntervalSec(pace: pace, thermalState: thermal),
            kAutoCaptureSafetyDebounceSec,
          );
        }
      }
    });

    test(
      'manual capture is untouched: shutterPaceNext keeps its own answer',
      () {
        // 手动/自动快门都不因队列或热态改变准入；这个函数只产生
        // 遥测标签，队列浅时任何热档都仍是 normal。
        for (final thermal in <int>[0, 1, 2, 3]) {
          expect(
            shutterPaceNext(
              previous: ShutterPace.normal,
              queueDepth: 0,
              thermalState: thermal,
            ),
            ShutterPace.normal,
          );
        }
      },
    );
  });

  // ─── ② 行为:两根接线,各带一条错误口径对照 ──────────────────────────

  group('onFire must report the real enqueue result', () {
    // 场景:队列停收(收尾 freezeAndDrain / cancelPending 的真实形态)期间
    // 用户一路横移 32 cm,然后队列恢复,用户再动 5 cm。
    //
    // 真口径:入队全失败 ⇒ 基准帧不动 ⇒ 恢复后那 5 cm 相对**原始**基准已是
    //         37 cm ≥ 0.10 m 兜底开火位移 ⇒ 立刻补上一张。
    // 歪口径(恒 true):基准帧被推到一张根本不存在的照片的位置上 ⇒ 恢复后
    //         只剩 5 cm 位移(< 0.10 m)⇒ 什么都不拍,用户白走了那 32 cm。
    List<double> track() => <double>[0.10, 0.20, 0.32];

    test('real result: the frozen stretch is still captured after resume', () {
      final h = _WiredHost(reportRealEnqueueResult: true, countsInFlight: true);
      h.queue.cancelPending(); // accepting = false
      h.controller.start(_pose(t: 0));
      var t = 0.0;
      for (final x in track()) {
        t += 0.1;
        h.tick(_pose(t: t, pos: Vector3(x, 0, 0)));
      }
      expect(h.admitted, 0, reason: 'the queue was closed the whole time');
      h.queue.resume();
      // spec §7「入队失败 ⇒ **下 tick 重试**」:失败那一发照样吃掉一次去抖
      // 预算,所以恢复后 0.1s 内的下一帧还轮不到。
      h.tick(_pose(t: t + 0.1, pos: Vector3(0.37, 0, 0)));
      expect(h.admitted, 0, reason: 'the retry waits for the next tick');
      // 一个间隔之后补上,而且是相对**原始**基准判的(0.37 ≥ 0.10)——
      // 基准帧从头到尾没动过,那 32 cm 没有白走。
      h.tick(_pose(t: t + 1.1, pos: Vector3(0.37, 0, 0)));
      expect(h.admitted, 1);
    });

    test('always-true result: the frozen stretch is silently lost', () {
      // 与上一条**唯一**的差别是 reportRealEnqueueResult。
      final h = _WiredHost(
        reportRealEnqueueResult: false,
        countsInFlight: true,
      );
      h.queue.cancelPending();
      h.controller.start(_pose(t: 0));
      var t = 0.0;
      for (final x in track()) {
        t += 0.1;
        h.tick(_pose(t: t, pos: Vector3(x, 0, 0)));
      }
      expect(h.admitted, 0);
      h.queue.resume();
      h.tick(_pose(t: t + 0.1, pos: Vector3(0.37, 0, 0)));
      // 与上一条同样的两拍,证明差别不是"等得不够久"而是基准帧被推走了。
      h.tick(_pose(t: t + 1.1, pos: Vector3(0.37, 0, 0)));
      expect(
        h.admitted,
        0,
        reason: 'baseline was advanced to a position where no photo exists',
      );
    });
  });

  group('the telemetry aggregator driven by the REAL controller', () {
    // telemetry 单元的 42 条全部喂**手写**序列,于是两层之间的口径一致
    // ——(a)controller 的 _lastTickSec 与 telemetry 的 _lastFireSec 同口径,
    //(b)页面的真实调用序是"onPose 内部先 recordFireOutcome、返回后再
    //     recordDecision"—— 此前完全靠人肉对齐,没有任何测试会在它们分叉
    //     时变红。这一条把真 controller、真队列、真聚合器串起来跑一遍。
    test('the self-check invariant survives a real trajectory', () {
      final tel = AutoCaptureTelemetry();
      final h = _WiredHost(
        reportRealEnqueueResult: true,
        countsInFlight: true,
        telemetry: tel,
      );
      final fireTimes = <double>[];
      void drive(ARPose p) {
        final d = h.tick(p);
        tel.recordDecision(
          d,
          tSec: p.timestamp,
          pace: ShutterPace.normal,
          thermalState: 0,
          motion: h.controller.lastMotionMetrics,
        );
        if (d == AutoCaptureDecision.fire) fireTimes.add(p.timestamp);
      }

      tel.recordSessionStart(0);
      h.controller.start(_pose(t: 0));
      // 3 秒匀速横移 @30 Hz(每帧 2 cm,深度 1 m ⇒ 每 0.5 s 跨一次 0.30)。
      for (var i = 1; i <= 90; i++) {
        drive(_pose(t: i / 30.0, pos: Vector3(i * 0.02, 0, 0)));
      }
      // 队列停收 1 秒 —— 收尾 freezeAndDrain / cancelPending 的真实形态。
      h.queue.cancelPending();
      for (var i = 91; i <= 120; i++) {
        drive(_pose(t: i / 30.0, pos: Vector3(i * 0.02, 0, 0)));
      }
      h.queue.resume();
      for (var i = 121; i <= 180; i++) {
        drive(_pose(t: i / 30.0, pos: Vector3(i * 0.02, 0, 0)));
      }
      final snap = tel.recordSessionEnd()!;

      final counts = snap['decision_counts']! as Map<String, int>;
      expect(counts['fire'], greaterThan(0));
      expect(
        snap['fire_enqueue_failed'],
        greaterThan(0),
        reason: 'the frozen stretch must really have failed to enqueue',
      );
      // 自检不变式:开火数 = 拍成的 + 没拍成的。真序列上也必须成立。
      expect(
        (snap['fire_enqueued']! as int) + (snap['fire_enqueue_failed']! as int),
        counts['fire'],
      );
      // fire_before_tick = 相邻两发间隔 < 当档间隔(normal=0.25s)的发数,
      // 第一发以起跑时刻为参照(telemetry 的 _lastFireSec 与 controller 的
      // _lastTickSec 就是这个口径 —— 两边一旦分叉,这条断言立刻红)。
      var expected = 0;
      var prev = 0.0;
      for (final t in fireTimes) {
        if (t - prev < 0.25) expected++;
        prev = t;
      }
      expect(snap['fire_before_tick'], expected);
      // 〔2026-08-24〕触发层换血后没有任何路径能绕过去抖闸 —— 真轨迹上
      // 这个数必须为 0;>0 = controller 与 telemetry 的时钟口径分叉了。
      expect(expected, 0, reason: 'nothing bypasses the debounce any more');
    });
  });

  group('capturedCountProvider must include in-flight tickets', () {
    // 队列收人的条件是 `verified + outstanding < 300`;governor 停在
    // `capturedCount >= 300`。少算在途票,两者就永远对不上。
    //
    // 输入:每帧转 12°、帧距 0.05s ⇒ 每 5 帧(0.25s 去抖)开一火。
    // 这是明确的 rotationCoverage，不依赖“低重叠警告本身是否值得花照片”
    // 的产品策略。执行体永不推进 ⇒ verified 恒 0,票全挂在
    // 队列上 = 满编的在途。admit 满 300 需要 300×5 帧。
    void drive(_WiredHost h, int poses) {
      h.controller.start(_pose(t: 0));
      for (var i = 1; i <= poses; i++) {
        h.tick(_pose(t: i * 0.05, yawDeg: i * 12.0));
      }
    }

    const framesToCap = kOfficialMaximumCaptureFrames * 5;

    test('with in-flight counted, the controller stops itself at the cap', () {
      final h = _WiredHost(reportRealEnqueueResult: true, countsInFlight: true);
      drive(h, framesToCap + 50);
      expect(h.admitted, kOfficialMaximumCaptureFrames);
      expect(h.controller.isRunning, isFalse);
    });

    test('counting only verified photos, the controller never stops', () {
      // 与上一条**唯一**的差别是 countsInFlight。
      final h = _WiredHost(
        reportRealEnqueueResult: true,
        countsInFlight: false,
      );
      drive(h, framesToCap + 50);
      expect(h.admitted, kOfficialMaximumCaptureFrames);
      expect(
        h.controller.isRunning,
        isTrue,
        reason: 'the governor never saw the cap it was supposed to stop at',
      );
      expect(
        h.fireAttempts,
        greaterThan(kOfficialMaximumCaptureFrames),
        reason: 'it keeps banging on a door that is already closed',
      );
      // …但只按去抖的节奏撞,不是每帧撞一次:失败的开火照样吃掉一次预算
      // (spec §7)。50 帧 × 0.05 s = 2.5 s ⇒ 至多 ⌈2.5/0.25⌉+1 = 11 次重试
      // (每帧撞的话是 50 次)。
      expect(
        h.fireAttempts - kOfficialMaximumCaptureFrames,
        lessThanOrEqualTo(11),
        reason: 'a failed fire consumes the debounce budget',
      );
    });

    test('the queue admits exactly the cap, in-flight included', () {
      // 把上面两条依赖的队列语义单独钉住:在途票**算进**预算。
      final h = _WiredHost(reportRealEnqueueResult: true, countsInFlight: true);
      drive(h, framesToCap + 50);
      expect(h.queue.outstandingCount, kOfficialMaximumCaptureFrames);
      expect(h.verified, 0);
    });
  });

  test(
    'a stopped controller returns skipNotMoved — the same value as "you have '
    'not moved", which is why the UI must read isRunning',
    () {
      final h = _WiredHost(reportRealEnqueueResult: true, countsInFlight: true);
      expect(h.controller.isRunning, isFalse);
      expect(
        h.tick(_pose(t: 1, pos: Vector3(9, 0, 0))),
        AutoCaptureDecision.skipNotMoved,
      );
      expect(h.admitted, 0);
    },
  );

  // ─── ③ 源码契约:页面里那部分 ────────────────────────────────────────

  group('ar_capture_page wiring', () {
    test('there is exactly one enqueue call site and one guard triple', () {
      // 自动拍复用同一条快门路径,300 张上限 / in-flight 守卫 / 12MP 静照 /
      // 落盘 / SfM 喂帧因此全部自动继承。抄第二份守卫迟早漏一条。
      final page = _pageSource();
      expect(RegExp(r'_shutterQueue\.enqueue\(').allMatches(page).length, 1);
      expect(
        RegExp(
          r'_session == null \|\| !_sfmCaptureReady \|\| !_shutterQueue\.accepting',
        ).allMatches(page).length,
        1,
      );
      expect(
        page,
        contains(
          'bool _enqueueShutterCapture({bool automaticSelection = false})',
        ),
      );
    });

    test('the auto fire hook returns the enqueue result, not a constant', () {
      final page = _pageSource();
      final fire = _section(
        page,
        'bool _onAutoCaptureFire()',
        'void _onShutterTap()',
      );
      expect(
        fire,
        contains('_enqueueShutterCapture(automaticSelection: true)'),
      );
      expect(fire, isNot(contains('return true;')));
      // 到 300 张时自动模式**不弹对话框** —— 每秒撞一次会刷屏。
      expect(fire, isNot(contains('_showMaximumPhotosDialog')));
      // onFire 绝不能抛:异常会打断 pose 回调。一律按"没入队"处理。
      expect(fire, contains('catch'));
    });

    test('the manual shutter still owns the maximum-photos dialog', () {
      final page = _pageSource();
      final tap = _section(
        page,
        'void _onShutterTap()',
        'Future<void> _showMaximumPhotosDialog()',
      );
      expect(tap, contains('_showMaximumPhotosDialog()'));
    });

    test('captured count reuses the bar\'s in-flight-inclusive expression', () {
      final page = _pageSource();
      expect(page, contains('int _autoCaptureAcceptedFrameCount()'));
      expect(
        page,
        contains('_projectPhotos.count + _shutterQueue.outstandingCount'),
      );
      expect(
        page,
        contains('capturedCountProvider: _autoCaptureAcceptedFrameCount'),
      );
      // _ManualCaptureBar 里的 officialCaptureCanShoot 用的是同一个表达式。
      expect(
        RegExp(
          r'projectPhotos\.count \+ shutterQueue\.outstandingCount',
        ).allMatches(page).isNotEmpty,
        isTrue,
      );
    });

    test('the pose stream is the only clock — no timer, no DateTime.now', () {
      final page = _pageSource();
      final drive = _section(
        page,
        'void _driveAutoCapture(ARPose pose)',
        'void _startAutoCapture(ARPose seed)',
      );
      expect(drive, contains('_autoCapture.onPose(pose)'));
      expect(drive, isNot(contains('Timer')));
      expect(drive, isNot(contains('DateTime.now()')));
      // onPose 只此一处调用,且就挂在已有的 pose 订阅上。
      expect(RegExp(r'_autoCapture\.onPose\(').allMatches(page).length, 1);
      expect(RegExp(r'_driveAutoCapture\(p\);').allMatches(page).length, 1);
      // start() 只在 pose 回调里、用那一帧起跑(_autoStartPending 的作用)。
      expect(RegExp(r'_autoCapture\.start\(').allMatches(page).length, 1);
      expect(page, contains('_startAutoCapture(pose)'));
      expect(page, contains('bool _autoStartPending = false;'));
    });

    test('the STREAMING preview branch feeds the live-depth input — the '
        'colorize switch alone is unreachable during capture', () {
      // 〔2026-08-24 真机教训,未命名(7)〕拍摄期流式快照在 AR overlay 分支
      // **提前 return**,永远到不了下方的 colorize switch;钩子只挂在
      // switch 里 ⇒ 整场 fire_live_depth_m 为空、阈值恒为兜底 0.10m。
      // 两处都必须有同款存储,少一处这条就红。
      final page = _pageSource();
      final streamingBranch = _section(
        page,
        'if (event is SfmLivePreview &&',
        'if (event is SfmLiveConnectivity)',
      );
      expect(streamingBranch, contains('_liveCloudXyz = snapshot.xyz'));
      expect(
        streamingBranch,
        contains('snapshot.gravityAlignQuatWxyz == null'),
        reason: '带重力旋转的快照与 ARKit 不同世界系,不许喂进深度',
      );
      // 下方 switch 的同款钩子(finalize/resume 路径)也在。
      final colorizeSwitch = _section(
        page,
        'case SfmLivePreview(:final snapshot):',
        'Future<void> _colorizeSnapshot(',
      );
      expect(colorizeSwitch, contains('_liveCloudXyz = snapshot.xyz'));
    });

    test(
      'the fallback target uses cross-platform SfM, never Apple raycast',
      () {
        final page = _pageSource();
        final wiring = _section(
          page,
          'late final AutoCaptureController _autoCapture',
          'final AutoCaptureTelemetry _autoTelemetry',
        );
        final code = wiring
            .split('\n')
            .map((line) => line.split('//').first)
            .join('\n');
        expect(code, contains('liveDepthProvider: _liveCloudMedianDepthFor'));
        expect(code, isNot(contains('centerRayDepthM')));
        expect(code, isNot(contains('_raySmoother')));
        expect(code, isNot(contains('previewPoints')));
        expect(code, isNot(contains('medianSceneDepthM')));
      },
    );

    test('no image dimensions are ever handed to the auto-capture path', () {
      // 内参与画幅必须成对取自同一个 ARPose(spec §5.2)。这里堵的是两个
      // 同名易混量:pose.quality 的 16×16 签名网格、12MP 静照的 imageWidth。
      final page = _pageSource();
      final block = _section(
        page,
        'int _autoCaptureAcceptedFrameCount()',
        'void _onShutterTap()',
      );
      expect(block, isNot(contains('signatureWidth')));
      expect(block, isNot(contains('signatureHeight')));
      expect(block, isNot(contains('imageWidth')));
      expect(block, isNot(contains('imageHeight')));
    });

    test('background stops auto capture and resume does not restart it', () {
      final page = _pageSource();
      final lifecycle = _section(
        page,
        'void didChangeAppLifecycleState(',
        'Future<void> _pauseArForBackground()',
      );
      expect(lifecycle, contains('_stopAutoCapture()'));
      // 回前台**不**自动重开:startSession{resume:true} 可能重定位世界原点。
      expect(lifecycle, isNot(contains('_startAutoCapture')));
      expect(lifecycle, isNot(contains('_autoStartPending = true')));
      // 停止而非暂停:controller 没有 pause,这里也不该出现别的写法。
      expect(page, isNot(contains('_autoCapture.pause')));
    });

    test('teardown paths stop auto capture', () {
      final page = _pageSource();
      final dispose = _section(page, 'void dispose() {', 'Widget build(');
      expect(dispose, contains('_autoCapture.stop()'));
      final finish = _section(
        page,
        'Future<void> _onFinishTap()',
        'Future<void> _finalizeRecording(',
      );
      expect(finish, contains('_stopAutoCapture()'));
      final finalize = _section(
        page,
        'Future<void> _finalizeRecording(',
        'await _shutterQueue.freezeAndDrain()',
      );
      expect(finalize, contains('_stopAutoCapture()'));
    });

    test('the UI reads isRunning, never the last decision', () {
      final page = _pageSource();
      expect(page, contains('autoRunning: _autoCapture.isRunning'));
      expect(page, contains('autoCaptureIndicatorFor('));
      // 指示器映射不许在页面里被就地重写。
      expect(page, isNot(contains('_lastAutoDecision == AutoCaptureDecision')));
    });

    test('the waiting indicator is actually CONSUMED, not just computed', () {
      // 〔2026-08-19 评审改正〕此前页面侧只断言 `autoCaptureIndicatorFor(` 出现
      // 过 —— 把 _AutoRecordButton 里唯一真正读它的那一句连同它控制的视觉
      // 一起删掉,映射照样被计算、照样被当参数传下去,全套测试无一变红。
      // 而 spec §8 明写 waiting 是**必需**态:「站着不动一张都不拍,不给
      // 反馈用户一定以为坏了」。
      final page = _pageSource();
      final record = _section(
        page,
        'class _AutoRecordButton',
        'class _CaptureModeTopHint',
      );
      expect(record, contains('AutoCaptureIndicator.waiting'));
      // 暗环是这一态唯一的表达 —— 断言它真的改了透明度,而不是算完就扔。
      expect(record, contains('ringAlpha'));
      // 脉冲走的是另一条通道(令牌),不是 indicator。
      expect(record, contains('widget.pulseToken != oldWidget.pulseToken'));
    });

    test(
      'the record-button pulse fires on a real enqueue, not on a decision',
      () {
        // spec §8「**落帧**时 → 指示器脉冲一次」,而 spec §7 把"开火"与"拍成"
        // 分得很清楚(遥测层就是为此拆成 fire_enqueued / fire_enqueue_failed)。
        // 〔2026-08-19 评审改正〕此前 `if (fired) _autoFirePulseToken++;` 读的是
        // governor 的判定 —— 入队失败时红键照样脉冲、N/300 一动不动,而自动
        // 模式下那颗红键的脉冲是"到底拍上没有"的**唯一**反馈。
        final page = _pageSource();
        final fire = _section(
          page,
          'bool _onAutoCaptureFire()',
          'void _onShutterTap()',
        );
        // 四角色开火与起跑锚点各有一处真实入队脉冲；两者都只在 admitted
        // 后自增，不能回到 decision 驱动。
        expect(fire, contains('if (enqueued) _autoFirePulseToken++;'));
        final anchor = _section(
          page,
          'bool _onAutoCaptureStartAnchor()',
          'bool _onAutoCaptureFire()',
        );
        expect(anchor, contains('if (enqueued) _autoFirePulseToken++;'));
        expect(RegExp(r'_autoFirePulseToken\+\+').allMatches(page).length, 2);
        final drive = _section(
          page,
          'void _driveAutoCapture(ARPose pose)',
          'void _emitAutoTelemetry(',
        );
        // 判定层不许再自增,也不许拿 `decision == fire` 当"落帧"用。
        expect(drive, isNot(contains('_autoFirePulseToken++')));
        // 短路早退也得跟着改口径:`fired == true` 会跳过它,而入队持续失败时
        // 判定会连着好几帧是 fire ⇒ 4800 行的页面被每帧重建一次。
        expect(drive, contains('final pulseBefore = _autoFirePulseToken;'));
        expect(drive, contains('_autoFirePulseToken != pulseBefore'));
      },
    );

    test('everything that invalidates enqueue also stops auto capture', () {
      // 〔2026-08-19 评审改正〕_noteSfmInternalFailure 连续 3 次 native
      // errInternal 就把 _sfmStartFailureText 置非空 ⇒ _sfmCaptureReady 翻
      // false ⇒ _admitShutterCapture 恒 blocked。这条路此前**没有**停自动拍,
      // 而其余四条(退后台 / 退出弹窗 / 完成 / finalize)都停了 —— 于是自动拍
      // 会对着一扇永远关着的门一路空转到 5 分钟上限。
      final page = _pageSource();
      final note = _section(
        page,
        'void _noteSfmInternalFailure(String reason)',
        'void _markPhotoDisconnected(',
      );
      expect(note, contains('_stopAutoCapture()'));
      // 停在**真的置了标志**的那条路上,不是在早退之前(早退时标志没变,
      // 停了反而是无谓的副作用)。
      expect(
        note.indexOf('_stopAutoCapture()'),
        greaterThan(note.indexOf('if (_sfmStartFailureText == text')),
      );
      final mark = _section(
        page,
        'void _markSfmStartFailure(String detail)',
        'Future<void> _startSfmLiveRecon(',
      );
      expect(mark, contains('_stopAutoCapture()'));
      // 全页只有这一处 getter 定义 —— 上面两段之外没有第三条会翻它的路。
      expect(
        RegExp(r'_sfmStartFailureText = ').allMatches(page).length,
        3,
        reason: '两处置错 + 一处清空;新增第四处就必须一并接上 _stopAutoCapture',
      );
    });
  });

  group('ar_capture_page UI (spec §8.1)', () {
    test(
      'default mode is auto, and switching to auto does not start capture',
      () {
        final page = _pageSource();
        expect(
          page,
          contains(
            'OfficialCaptureMode _captureMode = OfficialCaptureMode.auto;',
          ),
        );
        final setMode = _section(
          page,
          'void _setCaptureMode(OfficialCaptureMode mode)',
          'void _toggleAutoRun()',
        );
        expect(setMode, isNot(contains('_startAutoCapture')));
        expect(setMode, isNot(contains('_autoStartPending = true')));
        // 切走自动 ⇒ 立即停;已拍帧全保留(不碰 _projectPhotos)。
        expect(setMode, contains('_stopAutoCapture()'));
        expect(setMode, isNot(contains('_projectPhotos')));
        // 切到自动 ⇒ 浮出「自动拍摄已开启」。
        expect(setMode, contains('_autoModeToastToken'));
      },
    );

    test('the mode toggle sits between the album thumb and the shutter', () {
      final page = _pageSource();
      final bar = _section(
        page,
        'class _ManualCaptureBar',
        'class _AlbumThumbButton',
      );
      final album = bar.indexOf('_AlbumThumbButton(');
      final toggle = bar.indexOf('_CaptureModeToggle(');
      final shutter = bar.indexOf('_ShutterButton(');
      expect(album, greaterThanOrEqualTo(0));
      expect(toggle, greaterThan(album));
      expect(shutter, greaterThan(toggle));
      // 只有一颗 —— 顺序断言用的是 indexOf,再挂一颗到快门右边它发现不了。
      expect(RegExp(r'_CaptureModeToggle\(').allMatches(bar).length, 1);
    });

    test('auto mode swaps the white shutter for a red record button', () {
      final page = _pageSource();
      final bar = _section(
        page,
        'class _ManualCaptureBar',
        'class _AlbumThumbButton',
      );
      expect(bar, contains('if (mode == OfficialCaptureMode.auto)'));
      expect(bar, contains('_AutoRecordButton('));
      // 手动那颗白快门一个字节没改(既有契约测试也盯着这两串)。
      expect(
        bar,
        contains('enabled: ready && shutterQueue.accepting && canShoot'),
      );
      expect(
        bar,
        contains('onTap: ready && shutterQueue.accepting && canShoot'),
      );
      final record = _section(
        page,
        'class _AutoRecordButton',
        'class _AutoCaptureOnToast',
      );
      expect(record, contains('0xFFFF3B30'));
      // 自动模式下没有第二颗手动快门:红键就是开始/停止键。
      // (盯的是**用法**;文档注释里提一句 _ShutterButton 作参照无妨。)
      expect(record, isNot(contains('_ShutterButton(')));
    });

    test('the mode toggle is grey in manual and blue in auto', () {
      final page = _pageSource();
      final toggle = _section(
        page,
        'class _CaptureModeToggle',
        'class _AutoRecordButton',
      );
      expect(toggle, contains('Icons.videocam'));
      expect(toggle, contains('0xFF0A84FF'));
      expect(toggle, contains('mode == OfficialCaptureMode.auto'));
    });

    test(
      'both hint lines and the toast are wired to the shared copy source',
      () {
        final page = _pageSource();
        expect(page, contains('autoCaptureTopHintText('));
        expect(page, contains('autoCaptureShutterHintText('));
        expect(page, contains('kAutoCaptureOnToastText'));
        // 文案只有一个出处:页面里不许再写一份中文常量。
        expect(page, isNot(contains('自动拍摄已开启')));
        expect(page, isNot(contains('绕物成圈拍摄')));
      },
    );

    test('slow-down guidance participates in the throttled UI state', () {
      final page = _pageSource();
      expect(page, contains('final promptSlowDown ='));
      expect(page, contains('promptSlowDown == _autoPromptSlowDown'));
      expect(page, contains('_autoPromptSlowDown = promptSlowDown'));
      expect(page, contains('shouldPromptSlowDown: _autoPromptSlowDown'));
    });

    test('the four transient banners are back at their signed bands', () {
      // [2026-07-27 UI 签决] 删掉常驻入场提示时,同一条签决要求"下面几档顶部
      // 横幅回到各自的固定档位,不再有让位入场提示的偏移"。这里逐条回读每个
      // 横幅**自己**那条 padding,而不是数字面量出现次数 —— 后者换个位置就
      // 骗过去了。
      final page = _pageSource();
      expect(_bandOf(page, "'sfm-start-failure-banner-official'"), 66);
      expect(_bandOf(page, '_HardRejectToast(stream:'), 60);
      expect(_bandOf(page, '_MotionSpeedToast(stream:'), 104);
      expect(_bandOf(page, '_ParallaxStarvedBanner('), 148);
      expect(_bandOf(page, '_DisconnectedPhotoBanner('), 192);
      // 说明条与硬拒 toast 共用第 60 档。真撞上时由**警告赢** —— 靠 Stack
      // 顺序:说明条排在前面,警告画在它上面。
      expect(_bandOf(page, '_CaptureModeTopHint(mode:'), 60);
      expect(
        page.indexOf('_CaptureModeTopHint(mode:'),
        lessThan(page.indexOf('_HardRejectToast(stream:')),
      );
    });

    test(
      'the top hint is transient: shown on mount and on mode change only',
      () {
        final page = _pageSource();
        final hint = _section(
          page,
          'class _CaptureModeTopHintState',
          'class _AutoCaptureOnToast',
        );
        // 挂上时露一次 = 进采集页(这个组件只在 AR 会话建起来之后才存在)。
        expect(hint, contains('void initState()'));
        expect(hint, contains('_visible = true;'));
        // 之后只有模式真的变了才再露。父级每帧都可能重建(pose 流 20–60 Hz),
        // 没有这条早退,"瞬态"会退化成常驻,只是绕了个圈。
        expect(hint, contains('if (widget.mode == oldWidget.mode) return;'));
        // 自动淡出,且沿用 _HardRejectToast 那条 3 秒,不新造常数。
        expect(hint, contains('Timer(const Duration(seconds: 3)'));
        // ⚠️ 断言的是**淡出那一句**,不是字段初值 `bool _visible = false;`
        // —— 后者在"永不淡出"的改法下依然在,数它等于没数。
        expect(hint, contains('setState(() => _visible = false)'));
        expect(hint, contains('_fadeTimer?.cancel()'));
        // ⚠️〔2026-08-19 评审改正〕上面六条全部落在 _armDismiss 的**定义体**
        // 与字段赋值上,没有一条钉住它被**调用**:把 initState 与
        // didUpdateWidget 里那两句 `_armDismiss();` 一起删掉,说明条就永不
        // 淡出、退化成常驻(= 52ceff1 + b1d6f63 两次提交和 07-27 UI 签决
        // 专门推翻的那个状态),而这条测试此前仍然逐字全绿。
        expect(RegExp(r'_armDismiss\(\);').allMatches(hint).length, 2);
        final initStateAt = hint.indexOf('void initState()');
        final didUpdateAt = hint.indexOf('void didUpdateWidget(');
        final earlyReturnAt = hint.indexOf(
          'if (widget.mode == oldWidget.mode) return;',
        );
        final firstArm = hint.indexOf('_armDismiss();');
        final secondArm = hint.indexOf('_armDismiss();', firstArm + 1);
        expect(initStateAt, greaterThanOrEqualTo(0));
        expect(didUpdateAt, greaterThan(initStateAt));
        // ⚠️ earlyReturnAt 必须先钉住"找得到"。这一句被改写(哪怕只是把
        // `oldWidget.mode` 换个写法)时 indexOf 返回 -1，下面那条
        // `secondArm > earlyReturnAt` 就退化成 `secondArm > -1` —— 恒真，
        // 等于把"第二处 _armDismiss 在早退之后"这个断言整条静默丢掉。
        expect(earlyReturnAt, greaterThanOrEqualTo(0));
        // 第一处在 initState 里(挂上就露一次,3 秒后自消)。
        expect(firstArm, greaterThan(initStateAt));
        expect(firstArm, lessThan(didUpdateAt));
        // 第二处在 didUpdateWidget 的早退**之后**(模式真的变了才重新计时)。
        expect(secondArm, greaterThan(earlyReturnAt));
        final rejectToast = _section(
          page,
          'class _HardRejectToastState',
          'class _ParallaxStarvedBanner',
        );
        expect(rejectToast, contains('Duration(seconds: 3)'));
        // 页面里没有第二处常驻的顶部说明条了。
        expect(RegExp(r'_IdleHintPill\(').allMatches(page).length, 3);
      },
    );

    test('the N/300 fraction is untouched and shared by both modes', () {
      final page = _pageSource();
      expect(RegExp(r'_AlbumCountFraction\(').allMatches(page).length, 2);
      final bar = _section(
        page,
        'class _ManualCaptureBar',
        'class _AlbumThumbButton',
      );
      expect(bar, isNot(contains('_AlbumCountFraction')));
    });
  });

  // [pw] 2026-08-24:原来这里有一条守「收尾遮罩」的测试,随遮罩一起撤掉。
  // 撤的依据是同行调研:黑底 spinner 零家在做,Apple 示例在 .finishing 期间
  // 保持相机视图。理由写在 ar_capture_page.dart 对应位置。

  // [pw] 2026-08-24 真因:点完成后**还在拍**,而且手动模式完全没有。
  //
  // enqueue() 只排一张票,真正的 12MP 拍照在 _pump() 里 ⇒ pending 的票是
  // **还没拍的照片**,而 freezeAndDrain() 会把它们全拍完才返回。
  // 手动点一下拍一张,点完成时 outstandingCount==0 ⇒ 直接返回 ⇒ 秒结束;
  // 自动 1 秒 1 张压着,pump 串行,队列一直涨 ⇒ 结束后还要补拍一摞。
  test('点完成先丢掉未拍的排队票,而不是把它们全拍完', () {
    final src = _pageSource();
    final finish = _section(
      src,
      'Future<void> _onFinishTap() async {',
      'setState(() => _finishTapInProgress = true);',
    );

    expect(finish.contains('_stopAutoCapture();'), isTrue);
    expect(
      finish.contains('_shutterQueue.cancelPending();'),
      isTrue,
      reason: '不 cancel 就等于按了结束还要把排队的票全部拍完',
    );

    // 顺序:必须先 cancel 再 drain。反过来 drain 会先把票拍光,cancel 就成了
    // 一句空操作 —— 这是最容易在后续重构里被悄悄改坏的一处。
    final iCancel = finish.indexOf('_shutterQueue.cancelPending();');
    final iDrainAll = src.indexOf(
      'await _shutterQueue.freezeAndDrain();',
      src.indexOf('Future<void> _onFinishTap() async {'),
    );
    expect(iCancel, greaterThanOrEqualTo(0));
    expect(
      src.indexOf(
        '_shutterQueue.cancelPending();',
        src.indexOf('Future<void> _onFinishTap() async {'),
      ),
      lessThan(iDrainAll),
      reason: 'cancel 必须排在 drain 之前,否则票已经被拍光了',
    );

    // 丢了多少必须可见 —— 静默丢弃是本仓库反复踩过的那类失效。
    expect(
      finish.contains('finish_cancel_pending'),
      isTrue,
      reason: '丢弃张数必须进遥测',
    );

    // 负向:别把"丢未拍的票"扩大成"丢已拍的数据"。
    for (final banned in <String>[
      'deleteAll',
      'clearPhotos',
      '_projectPhotos.clear',
    ]) {
      expect(
        finish.contains(banned),
        isFalse,
        reason: '完成键出现 $banned = 从"取消未拍"越界成"删已拍"',
      );
    }
  });

  // 对照:放弃拍摄本来就是 cancel + drain;保存并退出刻意**不** cancel。
  // 三条路的语义必须各自不同,任何一条被抄成另一条都是行为回归。
  test('三条收尾路径的语义各自不同,不许互相抄', () {
    final src = _pageSource();
    // ⚠️ _section **包含**起始锚点本身,所以锚点里不能出现要断言"不存在"的
    //    那个词 —— 否则断言的是自己的锚点(这条上一版就踩了)。
    final saveExit = _section(
      src,
      '_discardingCapture = true;\n        final session = _session;',
      'await _persistDraft(showSnackBar: false);',
    );
    expect(
      saveExit.contains('cancelPending'),
      isFalse,
      reason: '保存并退出是无损路径:在途快门要全部落地',
    );
    expect(
      saveExit.contains('freezeAndDrain'),
      isTrue,
      reason: '负向对照:这段确实是收尾路径,不是抓了个空串',
    );
  });
}
