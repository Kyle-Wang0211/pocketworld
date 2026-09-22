import 'dart:math' as math;
import 'dart:typed_data';

// [pw] 2026-08-24 触发层换血:量纲 = 绝对位移 + 绝对转角(出处与验尸见
// auto_capture_governor.dart 文件头)。本文件随之整体重写:
//   · 深度记忆 / depthTrusted / 视差门 / R2(centerShift)/ 内参消费
//     全部随实现删除 —— 那些用例守的机制已不存在,留着只会守一具尸体;
//   · 新增:位移/转角双阈值、0.25s 去抖、活体 SfM 深度缩放(liveDepthProvider)
//     的接线与契约;
//   · 保留(适配后):生命周期、D8 整场预算、tracking 双信号门、入队失败
//     "下 tick 重试"、pace/热态拉伸、相邻捕获几何契约。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

const int _w = 1000;
const int _h = 1000;
const double _fx = 1000;

/// 相机在 [pos],朝向由绕 Y 轴的 [yawDeg] 决定(0 = 看向 -Z)。
/// previewPoints 仍然铺在前方 [depthM] 处 —— controller 已**不再消费**它们
/// (rawFeaturePoints 已定罪,见 governor 文件头),留着是为了钉住
/// "特征点无论怎么给都不影响判定"这条新不变量。
FrameQualityReport _quality(double s) => FrameQualityReport(
  sharpness: s,
  roiSharpness: s,
  multiScaleSharpness252: s,
  multiScaleSharpness512: s,
  edgeBlockSharpness: s,
  backgroundSharpness: s,
  subjectVsBackgroundSharpnessDelta: 0,
  sharpnessConsensus: s,
  meanBrightness: 128,
  globalVariance: 100,
  signature: Uint8List(0),
  signatureWidth: 0,
  signatureHeight: 0,
);

ARPose _pose({
  required double t,
  Vector3? pos,
  double yawDeg = 0,
  String? tracking = 'normal',
  bool? isTracking,
  double depthM = 1.0,
  int pointCount = 12,
  double fx = _fx,
  bool withIntrinsics = true,
  int width = _w,
  int height = _h,
  double? sharpness,
  Vector3? worldOrigin,
  bool hasOrigin = true,
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
    isTracking: isTracking ?? (tracking == 'normal'),
    trackingStateName: tracking,
    timestamp: t,
    hasOrigin: hasOrigin,
    worldOrigin: worldOrigin ?? Vector3(0, 0, -1),
    worldYaw: 0,
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: withIntrinsics
        ? <double>[fx, fx, width / 2, height / 2]
        : const <double>[],
    imageWidth: width,
    imageHeight: height,
    quality: sharpness == null ? null : _quality(sharpness),
    previewPoints: <ARPreviewPoint>[
      for (var i = 0; i < pointCount; i++)
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

class _Harness {
  int fires = 0;
  int fireAttempts = 0;
  bool enqueueSucceeds = true;
  ShutterPace pace = ShutterPace.normal;

  /// thermal 桶(0 nominal · 1 fair · 2 serious · 3 critical;-1 未知按冷)。
  int thermal = 0;
  int captured = 0;

  /// 活体 SfM 场景中位深度(米);null = 快照未到 ⇒ controller 用兜底位移。
  double? liveDepth;

  /// liveDepthProvider 收到的每一个 pose —— 钉"每帧现问、传的是当前帧"。
  final List<double> depthProbeTimestamps = <double>[];

  /// 每次**成功**入队的那一帧 —— 相邻捕获几何契约只能沿轨迹回算。
  final List<ARPose> firedPoses = <ARPose>[];
  final List<AutoCaptureMotionRole?> firedRoles = <AutoCaptureMotionRole?>[];
  final List<double?> firedParallaxDeg = <double?>[];
  ARPose? _nextFirePose;

  late final AutoCaptureController controller = AutoCaptureController(
    onStartAnchor: () => true,
    onFire: () {
      fireAttempts++;
      if (!enqueueSucceeds) return false;
      fires++;
      captured++;
      final p = _nextFirePose;
      if (p != null) firedPoses.add(p);
      return true;
    },
    paceProvider: () => pace,
    capturedCountProvider: () => captured,
    thermalStateProvider: () => thermal,
    liveDepthProvider: (pose) {
      depthProbeTimestamps.add(pose.timestamp);
      return liveDepth;
    },
  );

  AutoCaptureDecision feed(ARPose pose) {
    _nextFirePose = pose;
    final decision = controller.onPose(pose);
    if (decision == AutoCaptureDecision.fire && enqueueSucceeds) {
      firedRoles.add(controller.lastMotionRole);
      firedParallaxDeg.add(controller.lastGeometryParallaxDeg);
    }
    return decision;
  }
}

void main() {
  test('a stopped controller never fires', () {
    final h = _Harness();
    for (var i = 0; i < 60; i++) {
      h.controller.onPose(_pose(t: i.toDouble(), pos: Vector3(i * 1.0, 0, 0)));
    }
    expect(h.fires, 0);
  });

  test('standing still for 60s fires nothing', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    for (var i = 1; i <= 360; i++) {
      h.controller.onPose(_pose(t: i / 6.0)); // 6 Hz, 60 s
    }
    expect(h.fires, 0);
  });

  test('displacement past the fire distance fires; the debounce holds it '
      'before 0.25 s', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 位移够(0.30 ≥ 0.28)但离起跑只有 0.1s < 0.25s 去抖 ⇒ skipPaced。
    expect(
      h.feed(_pose(t: 0.1, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    expect(h.fires, 0);
    // 过了去抖 ⇒ 开火。
    expect(
      h.feed(_pose(t: 0.3, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test(
    'transverse motion just below the 12 degree geometry angle does not fire',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0));
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.20, 0, 0))),
        AutoCaptureDecision.skipNotMoved,
      );
      expect(h.fires, 0);
    },
  );

  test('walking straight keeps sparse 1.2x radial bridge frames', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    for (final step in <(double, double)>[
      (0.25, -0.20),
      (0.50, -0.36),
      (0.75, -0.488),
      (1.00, -0.5904),
    ]) {
      expect(
        h.feed(_pose(t: step.$1, pos: Vector3(0, 0, step.$2))),
        AutoCaptureDecision.fire,
      );
      expect(h.controller.lastMotionRole, AutoCaptureMotionRole.radialBridge);
    }
    expect(h.fires, 4);
  });

  test('pure rotation fires via the turn threshold — rotation pans new '
      'content into frame', () {
    // 开源 6/10 家都是 位移 OR 转角;RS 官方「相邻视点差 ≤30°」的硬上限
    // 要求转出新视角时必须及时补一张,否则链条断裂。
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(_pose(t: 1.0, yawDeg: 9.9)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.feed(_pose(t: 2.0, yawDeg: 12.1)), AutoCaptureDecision.fire);
    expect(h.fires, 1);
    // 开火后基准更新到 10.5°:再转 4.9° 不够,再转 10.2° 够
    // (刻意留余量 —— 四元数往返的浮点误差会把恰好压线的角磨到线下)。
    expect(
      h.feed(_pose(t: 3.0, yawDeg: 18.0)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.feed(_pose(t: 4.0, yawDeg: 24.3)), AutoCaptureDecision.fire);
  });

  // ── 无锁定目标时，SfM 深度只播种稳定目标，不参与逐帧阈值缩放 ──

  test(
    'fallback SfM target depth makes close scenes need smaller baselines',
    () {
      final h = _Harness();
      h.liveDepth = 0.08;
      h.controller.start(_pose(t: 0, hasOrigin: false));
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.02, 0, 0), hasOrigin: false)),
        AutoCaptureDecision.fire,
      );
    },
  );

  test('fallback SfM target depth makes far scenes need larger baselines', () {
    final h = _Harness();
    h.liveDepth = 3.0;
    h.controller.start(_pose(t: 0, hasOrigin: false));
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(0.60, 0, 0), hasOrigin: false)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(
      h.feed(_pose(t: 2.0, pos: Vector3(0.70, 0, 0), hasOrigin: false)),
      AutoCaptureDecision.fire,
    );
  });

  test(
    'without SfM depth the one-metre fallback target ignores raw feature points',
    () {
      final h = _Harness();
      h.liveDepth = null;
      h.controller.start(
        _pose(t: 0, depthM: 0.08, pointCount: 40, hasOrigin: false),
      );
      expect(
        h.feed(
          _pose(
            t: 1.0,
            pos: Vector3(0.20, 0, 0),
            depthM: 0.08,
            hasOrigin: false,
          ),
        ),
        AutoCaptureDecision.skipNotMoved,
      );
      expect(
        h.feed(
          _pose(
            t: 2.0,
            pos: Vector3(0.22, 0, 0),
            depthM: 0.08,
            hasOrigin: false,
          ),
        ),
        AutoCaptureDecision.fire,
      );
    },
  );

  test('the fallback target depth is frozen at the start of a run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, hasOrigin: false));
    h.feed(_pose(t: 0.5, hasOrigin: false));
    h.feed(_pose(t: 1.0, hasOrigin: false));
    expect(h.depthProbeTimestamps, <double>[0.0]);
  });

  test('a mid-run depth fluctuation cannot move the active target', () {
    final h = _Harness();
    h.liveDepth = 3.0; // 阈值夹到上限 0.70
    h.controller.start(_pose(t: 0, hasOrigin: false));
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(0.60, 0, 0), hasOrigin: false)),
      AutoCaptureDecision.skipNotMoved,
    );
    h.liveDepth = 1.0;
    expect(
      h.feed(_pose(t: 2.0, pos: Vector3(0.60, 0, 0), hasOrigin: false)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.depthProbeTimestamps, <double>[0.0]);
  });

  // ── previewPoints 彻底失明(防倒退回 rawFeaturePoints)──

  test('feature points — many, few, or none — never change the verdict', () {
    for (final n in <int>[0, 3, 12, 200]) {
      final h = _Harness();
      h.controller.start(_pose(t: 0, pointCount: n));
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.28, 0, 0), pointCount: n)),
        AutoCaptureDecision.fire,
        reason: 'pointCount=$n',
      );
      expect(
        h.feed(_pose(t: 2.0, pos: Vector3(0.40, 0, 0), pointCount: n)),
        AutoCaptureDecision.skipNotMoved,
        reason: 'pointCount=$n',
      );
    }
  });

  test(
    'missing intrinsics still allows geometry while overlap safety is unavailable',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0, withIntrinsics: false));
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.28, 0, 0), withIntrinsics: false)),
        AutoCaptureDecision.fire,
      );
    },
  );

  // ── tracking 门(双信号,语义未变)──

  test('non-normal tracking fires nothing and freezes the baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(
        _pose(
          t: 1.0,
          pos: Vector3(1, 0, 0),
          tracking: 'limited_excessive_motion',
        ),
      ),
      AutoCaptureDecision.skipTracking,
    );
    expect(h.fires, 0);
    // 恢复后相对**原基准**判定:1m 位移 ⇒ 立刻开火。
    expect(
      h.feed(_pose(t: 2.0, pos: Vector3(1, 0, 0))),
      AutoCaptureDecision.fire,
    );
  });

  test('a pose with no tracking-state string still counts as tracking when '
      'isTracking is true', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, tracking: null, isTracking: true));
    expect(
      h.feed(
        _pose(
          t: 1.0,
          pos: Vector3(0.30, 0, 0),
          tracking: null,
          isTracking: true,
        ),
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('a pose with isTracking false is skipped even when no tracking-state '
      'string says why', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(
        _pose(
          t: 1.0,
          pos: Vector3(0.16, 0, 0),
          tracking: null,
          isTracking: false,
        ),
      ),
      AutoCaptureDecision.skipTracking,
    );
  });

  test('a platform-private limited string cannot veto normalized tracking', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(
        _pose(
          t: 1.0,
          pos: Vector3(0.22, 0, 0),
          tracking: 'limited_relocalizing',
          isTracking: true,
        ),
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('start() on a bad-tracking pose seeds nothing, and the first normal '
      'frame becomes the baseline', () {
    final h = _Harness();
    final target = Vector3(5, 0, -1);
    h.controller.start(
      _pose(t: 0, tracking: 'limited_initializing', worldOrigin: target),
    );
    expect(h.controller.baselinePosition, isNull);
    // 第一帧正常位姿只播种、不判定。
    expect(
      h.feed(_pose(t: 0.5, pos: Vector3(5, 0, 0), worldOrigin: target)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.controller.baselinePosition, Vector3(5, 0, 0));
    // 相对新基准形成约 12.4° 视差 ⇒ 开火。
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(5.22, 0, 0), worldOrigin: target)),
      AutoCaptureDecision.fire,
    );
  });

  test('a tracking-loss frame does not consume the debounce clock', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.feed(_pose(t: 0.30, pos: Vector3(0.30, 0, 0))); // fire,时钟=0.30
    expect(h.fires, 1);
    h.feed(
      _pose(
        t: 0.40,
        pos: Vector3(0.60, 0, 0),
        tracking: 'limited_excessive_motion',
      ),
    );
    // 0.56 距上次开火 0.26s ≥ 0.25 ⇒ 丢跟踪帧没偷走节奏预算。
    expect(
      h.feed(_pose(t: 0.56, pos: Vector3(0.60, 0, 0))),
      AutoCaptureDecision.fire,
    );
  });

  // ── 入队失败:下 tick 重试(单机制版)──

  test('a failed enqueue leaves the baseline untouched and retries after a '
      'full interval, not next frame', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.enqueueSucceeds = false;
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fireAttempts, 1);
    expect(h.controller.baselinePosition, Vector3.zero());
    // 30 Hz 连喂 0.2s:全部 skipPaced,不许每帧重试。
    for (var i = 1; i <= 6; i++) {
      expect(
        h.feed(_pose(t: 0.30 + i / 30.0, pos: Vector3(0.30, 0, 0))),
        AutoCaptureDecision.skipPaced,
      );
    }
    expect(h.fireAttempts, 1);
    // 一个完整间隔后重试;成功即更新基准。
    h.enqueueSucceeds = true;
    expect(
      h.feed(_pose(t: 0.56, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
    expect(h.controller.baselinePosition, Vector3(0.30, 0, 0));
  });

  test(
    'a successful enqueue moves the baseline to the frame that was shot',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0));
      h.feed(_pose(t: 0.30, pos: Vector3(0.30, 0, 0)));
      expect(h.controller.baselinePosition, Vector3(0.30, 0, 0));
      // 相对新基准 0.05m ⇒ 不开火。
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.35, 0, 0))),
        AutoCaptureDecision.skipNotMoved,
      );
    },
  );

  // ── pace / 热态拉伸 ──

  test('shutter pace stretches the debounce interval', () {
    final h = _Harness();
    h.pace = ShutterPace.soft; // 2.0 s
    h.controller.start(_pose(t: 0));
    // 空间达到 0.28 后会按热态无损保底放行；用转角路径隔离节奏语义。
    expect(h.feed(_pose(t: 1.5, yawDeg: 12.1)), AutoCaptureDecision.skipPaced);
    expect(h.feed(_pose(t: 2.0, yawDeg: 12.1)), AutoCaptureDecision.fire);
  });

  test('the shutter pace is read on every pose, so slowing down mid-run '
      'takes effect immediately', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.feed(_pose(t: 0.30, pos: Vector3(0.30, 0, 0)));
    expect(h.fires, 1);
    h.pace = ShutterPace.hard; // 3.0 s
    // 基准已推进；用转角隔离 hard pace，避免空间保底提前放行。
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(0.30, 0, 0), yawDeg: 12.1)),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.feed(_pose(t: 3.30, pos: Vector3(0.30, 0, 0), yawDeg: 12.1)),
      AutoCaptureDecision.fire,
    );
  });

  test('serious thermal stretches the interval at normal pace', () {
    final h = _Harness();
    h.thermal = kAutoCaptureThermalSerious; // ≥ soft 档 = 2.0 s
    h.controller.start(_pose(t: 0));
    expect(h.feed(_pose(t: 1.0, yawDeg: 12.1)), AutoCaptureDecision.skipPaced);
    expect(h.feed(_pose(t: 2.0, yawDeg: 12.1)), AutoCaptureDecision.fire);
  });

  // ── 上限与生命周期 ──

  test('the 300-frame cap stops the run', () {
    final h = _Harness();
    h.captured = 299;
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(
      h.feed(_pose(t: 2.0, pos: Vector3(0.60, 0, 0))),
      AutoCaptureDecision.skipCapped,
    );
    expect(h.controller.isRunning, isFalse);
    // 停机后连判定都不再进行。
    expect(
      h.feed(_pose(t: 3.0, pos: Vector3(9, 0, 0))),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 1);
  });

  test('the five-minute limit stops the run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 100.0));
    expect(
      h.feed(_pose(t: 100.0 + 299.9, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(
      h.feed(_pose(t: 100.0 + 300.0, pos: Vector3(0.60, 0, 0))),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(h.controller.isRunning, isFalse);
  });

  test('stop() clears the baseline and halts firing mid-run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.stop();
    expect(h.controller.isRunning, isFalse);
    expect(h.controller.baselinePosition, isNull);
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(1, 0, 0))),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 0);
  });

  test('start() seeds both clocks from the pose timestamp, not from zero', () {
    final h = _Harness();
    // ARFrame 时钟是开机以来的秒数 —— 起跑在 t=5000 时,第一帧绝不能因为
    // "距 0 已经很久"而立即开火/立即撞时间上限。
    h.controller.start(_pose(t: 5000.0));
    expect(
      h.feed(_pose(t: 5000.1, pos: Vector3(1, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.feed(_pose(t: 5000.4, pos: Vector3(1, 0, 0))),
      AutoCaptureDecision.fire,
    );
  });

  // ── D8:时间上限按整场累积 ──

  group('the time limit is per SCAN, not per auto-run (D8)', () {
    test('stopping and restarting does not refund the elapsed budget', () {
      final h = _Harness();
      h.controller.start(_pose(t: 0));
      h.feed(_pose(t: 200.0)); // 本轮已跑 200s
      h.controller.stop();
      expect(h.controller.sessionElapsedSec, closeTo(200.0, 1e-9));
      h.controller.start(_pose(t: 1000.0));
      // 第二轮只剩 100s 预算:1000+99.9 还能拍,1000+100 撞顶。
      expect(
        h.feed(_pose(t: 1099.9, pos: Vector3(0.30, 0, 0))),
        AutoCaptureDecision.fire,
      );
      expect(
        h.feed(_pose(t: 1100.0, pos: Vector3(0.60, 0, 0))),
        AutoCaptureDecision.skipTimeLimit,
      );
    });

    test(
      'time spent stopped is free — it is auto-capture time that counts',
      () {
        final h = _Harness();
        h.controller.start(_pose(t: 0));
        h.feed(_pose(t: 10.0));
        h.controller.stop(); // 只花掉 10s
        h.controller.start(_pose(t: 9000.0)); // 停了俩小时,不进预算
        expect(
          h.feed(_pose(t: 9000.0 + 289.9, pos: Vector3(0.30, 0, 0))),
          AutoCaptureDecision.fire,
        );
        expect(
          h.feed(_pose(t: 9000.0 + 290.0, pos: Vector3(0.60, 0, 0))),
          AutoCaptureDecision.skipTimeLimit,
        );
      },
    );

    test('a self-stop at the limit settles the budget exactly once', () {
      final h = _Harness();
      h.controller.start(_pose(t: 0));
      h.feed(_pose(t: 300.0)); // skipTimeLimit ⇒ 自停并结算
      expect(h.controller.isRunning, isFalse);
      expect(h.controller.sessionElapsedSec, closeTo(300.0, 1e-9));
      h.controller.stop(); // 幂等:再结算一次加的是 0
      expect(h.controller.sessionElapsedSec, closeTo(300.0, 1e-9));
    });
  });

  // ── 节奏契约:换血后的新常态 ──

  test('continuous fast motion fires at the 0.25 s debounce ceiling, '
      'not at the old 1 s tick', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 1 m/s 横移、30 fps、跑 3 s:位移 0.28m 约需 0.28s，仍显著快于旧 1 Hz。
    // 封顶 ⇒ 约 3.7 发/秒(帧量化到 0.27s),必须显著多于旧 1 Hz。
    for (var i = 1; i <= 90; i++) {
      final t = i / 30.0;
      h.feed(_pose(t: t, pos: Vector3(t * 1.0, 0, 0)));
    }
    expect(h.fires, greaterThan(8)); // 旧 1s tick 下只有 ~3
    expect(h.fires, lessThanOrEqualTo(10));
    // 相邻开火间隔全部 ≥ 0.25s(允许一帧量化误差)。
    for (var i = 1; i < h.firedPoses.length; i++) {
      expect(
        h.firedPoses[i].timestamp - h.firedPoses[i - 1].timestamp,
        greaterThanOrEqualTo(0.25 - 1e-9),
      );
    }
  });

  // ── 画质缓拍(抄单第2项,跨端版):段内锐度中位当尺,纯 Dart 信号 ──

  test('a blur dip at fire time defers, and the next sharp frame fires', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 100));
    // 建立段内锐度分布(≥3 个样本才有中位可比)。
    h.feed(_pose(t: 0.05, sharpness: 100));
    h.feed(_pose(t: 0.10, sharpness: 100));
    // 运动够了,但这一帧明显比段内中位糊 ⇒ 缓拍,基准与去抖时钟都不动。
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 10)),
      AutoCaptureDecision.skipBlurry,
    );
    expect(h.fires, 0);
    // 画面回锐 ⇒ 立刻开火,不用再等一整拍。
    expect(
      h.feed(_pose(t: 0.35, pos: Vector3(0.22, 0, 0), sharpness: 100)),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('the blur defer is bounded — persistent blur still fires', () {
    // 覆盖(无损铁律)压过锐度:一直糊(比如光线就这样)就照拍。
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 100));
    h.feed(_pose(t: 0.05, sharpness: 100));
    h.feed(_pose(t: 0.10, sharpness: 100));
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 10)),
      AutoCaptureDecision.skipBlurry,
    );
    expect(
      h.feed(
        _pose(
          t: 0.30 + kAutoCaptureBlurDeferMaxSec,
          pos: Vector3(0.22, 0, 0),
          sharpness: 10,
        ),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('with too few sharpness samples the gate fails open — never defers', () {
    // 样本不足判不了"相对糊",宁可拍:锐度是锦上添花,覆盖是铁律。
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 1)),
      AutoCaptureDecision.fire,
    );
  });

  test('firing resets the sharpness segment — subsequence semantics', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 100));
    h.feed(_pose(t: 0.05, sharpness: 100));
    h.feed(_pose(t: 0.10, sharpness: 100));
    h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 100));
    expect(h.fires, 1);
    // 新段只有 1 个样本(开火帧之后的),低锐度也判不出"相对糊" ⇒ 直接拍。
    h.feed(_pose(t: 0.40, pos: Vector3(0.46, 0, 0), sharpness: 5));
    expect(
      h.feed(_pose(t: 0.60, pos: Vector3(0.46, 0, 0), sharpness: 5)),
      AutoCaptureDecision.fire,
    );
  });

  test('the fire frame still reports its sharpness snapshot AFTER the '
      'segment is cleared — the b29 telemetry-None bug', () {
    // 开火清段(subsequence)发生在页面读遥测之前;快照字段必须在清段前
    // 落下,否则 fire_sharpness 恒 None(b29 真机实证)。
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 100));
    h.feed(_pose(t: 0.05, sharpness: 100));
    h.feed(_pose(t: 0.10, sharpness: 100));
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 100)),
      AutoCaptureDecision.fire,
    );
    // onPose 已返回、段已清空 —— 快照仍在。
    expect(h.controller.lastSharpness, closeTo(100, 1e-9));
    expect(h.controller.lastSegmentMedianSharpness, isNotNull);
  });

  test('adjacent formal captures keep the promised angle — a steady orbit', () {
    final h = _Harness();
    const radius = 2.0;
    const omega = 0.15; // rad/s ⇒ 切向 0.3 m/s
    final center = Vector3(0, 0, -radius);
    ARPose at(double t) {
      final th = omega * t;
      return _pose(
        t: t,
        pos: center + Vector3(math.sin(th), 0, math.cos(th)) * radius,
        yawDeg: th * 180 / math.pi,
        worldOrigin: center,
      );
    }

    h.controller.start(at(0));
    for (var i = 1; i <= 900; i++) {
      h.feed(at(i / 30.0)); // 30 fps,30 s
    }
    final formal = <ARPose>[
      for (var i = 0; i < h.firedPoses.length; i++)
        if ((h.firedParallaxDeg[i] ?? 0) >=
            kAutoCaptureGeometryNormalDeg - 1e-6)
          h.firedPoses[i],
    ];
    expect(
      formal.length,
      greaterThan(18),
      reason: '30 s of orbiting must produce a real sequence',
    );
    for (var i = 1; i < formal.length; i++) {
      final angle = parallaxAngleDeg(
        baseCamera: formal[i - 1].position,
        currentCamera: formal[i].position,
        target: center,
      );
      expect(angle, greaterThanOrEqualTo(kAutoCaptureGeometryNormalDeg - 1e-9));
      expect(
        angle,
        lessThan(
          kAutoCaptureGeometryNormalDeg +
              omega * kAutoCaptureSafetyDebounceSec * 180 / math.pi +
              omega / 30 * 180 / math.pi +
              1e-9,
        ),
      );
    }
  });
}
