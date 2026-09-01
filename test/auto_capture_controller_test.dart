import 'dart:math' as math;
import 'dart:typed_data';

// [pw] 2026-08-24 触发层换血:量纲 = 绝对位移 + 绝对转角(出处与验尸见
// auto_capture_governor.dart 文件头)。本文件随之整体重写:
//   · 深度记忆 / depthTrusted / 视差门 / R2(centerShift)/ 内参消费
//     全部随实现删除 —— 那些用例守的机制已不存在,留着只会守一具尸体;
//   · 新增:位移/转角双阈值、0.25s 去抖、活体 SfM 深度缩放(liveDepthProvider)
//     的接线与契约;
//   · 保留(适配后):生命周期、D8 整场预算、tracking 双信号门、入队失败
//     "下 tick 重试"、pace/热态只记账、相邻捕获几何契约。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';
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
Uint8List _signatureFor(double timestamp) {
  var x = ((timestamp * 1000000).round() ^ 0x6d2b79f5) & 0x7fffffff;
  return Uint8List.fromList(<int>[
    for (var i = 0; i < 256; i++)
      ((x = (1103515245 * x + 12345) & 0x7fffffff) >> 16) & 0xff,
  ]);
}

Uint8List _trackGray(int shiftX) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sx = x - shiftX;
      if (sx < 0 || sx >= side) continue;
      final checker = (((sx ~/ 8) + (y ~/ 8)) & 1) == 0 ? 35 : 220;
      final detail = ((sx * 17 + y * 29 + (sx * y) % 31) & 31) - 15;
      out[y * side + x] = (checker + detail).clamp(0, 255);
    }
  }
  return out;
}

FrameQualityReport _quality(
  double s,
  double timestamp, {
  int? signatureByte,
  int? grayShiftX,
  Uint8List? rawGray,
  double? graySourceTimestamp,
  double meanBrightness = 128,
}) => FrameQualityReport(
  sharpness: s,
  roiSharpness: s,
  multiScaleSharpness252: s,
  multiScaleSharpness512: s,
  edgeBlockSharpness: s,
  backgroundSharpness: s,
  subjectVsBackgroundSharpnessDelta: 0,
  sharpnessConsensus: s,
  meanBrightness: meanBrightness,
  globalVariance: 100,
  signature: signatureByte == null
      ? _signatureFor(timestamp)
      : (Uint8List(256)..fillRange(0, 256, signatureByte)),
  signatureWidth: 16,
  signatureHeight: 16,
  rawGray128: rawGray ?? (grayShiftX == null ? null : _trackGray(grayShiftX)),
  sourceTimestamp: grayShiftX == null && rawGray == null
      ? null
      : (graySourceTimestamp ?? timestamp),
  sourceFocalX: grayShiftX == null && rawGray == null ? null : 128,
  sourceFocalY: grayShiftX == null && rawGray == null ? null : 128,
  sourcePrincipalX: grayShiftX == null && rawGray == null ? null : 64,
  sourcePrincipalY: grayShiftX == null && rawGray == null ? null : 64,
);

/// 开火时刻:必须跨过节奏地板,否则测试构造的场景根本开不出火。写死的
/// t: 0.30 会在地板变动时静默失效 —— 相对常数表达,以后调地板不必重改时间轴。
final _fireT = kAutoCaptureSafetyDebounceSec + 0.05;
final _fireT2 = _fireT + kAutoCaptureSafetyDebounceSec + 0.01;

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
  double? sharpness = 1000,
  int? signatureByte,
  int? grayShiftX,
  Uint8List? rawGray,
  double? graySourceTimestamp,
  double meanBrightness = 128,
  Vector3? worldOrigin,
  bool hasOrigin = true,
}) {
  final p = pos ?? Vector3.zero();
  final effectiveGrayShiftX = grayShiftX;
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
    quality: sharpness == null
        ? null
        : _quality(
            sharpness,
            t,
            signatureByte: signatureByte,
            grayShiftX: effectiveGrayShiftX,
            rawGray: rawGray,
            graySourceTimestamp: graySourceTimestamp,
            meanBrightness: meanBrightness,
          ),
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
    onStartAnchor: (_) => true,
    onFire: (_) {
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
    synchronousReceiptProvider: () => true,
    testOnlyAllowLegacySignatureEvidence: true,
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
  test(
    'production never lets a 16x16 signature replace exact track evidence',
    () {
      var fires = 0;
      final controller = AutoCaptureController(
        onStartAnchor: (_) => true,
        onFire: (_) {
          fires++;
          return true;
        },
        paceProvider: () => ShutterPace.normal,
        capturedCountProvider: () => 0,
        thermalStateProvider: () => 0,
        liveDepthProvider: (_) => null,
        synchronousReceiptProvider: () => true,
      );
      controller.start(_pose(t: 0, signatureByte: 0));

      expect(
        controller.onPose(
          _pose(t: 1, pos: Vector3(0.30, 0, 0), signatureByte: 255),
        ),
        AutoCaptureDecision.skipNoVisualEvidence,
      );
      expect(fires, 0);
    },
  );

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
      reason:
          'motion=${h.controller.lastTrackEvidence?.medianPixelDisplacement} '
          'common=${h.controller.lastTrackEvidence?.commonTrackCount} '
          'fraction=${h.controller.lastTrackEvidence?.commonTrackFraction} '
          'inliers=${h.controller.lastTrackEvidence?.vinsGeometricInlierFraction}',
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

  test('portable VINS evidence selects the weak 10 degree geometry tier', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, grayShiftX: 0));
    final partlyOccluded = _trackGray(13);
    for (var y = 72; y < 128; y++) {
      partlyOccluded.fillRange(y * 128, (y + 1) * 128, 128);
    }

    final decision = h.feed(
      _pose(
        t: 1,
        pos: Vector3(math.tan(11 * math.pi / 180), 0, 0),
        rawGray: partlyOccluded,
      ),
    );

    expect(decision, AutoCaptureDecision.skipRedundant);
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
    expect(
      h.controller.lastMotionMetrics?.geometryThresholdDeg,
      kAutoCaptureGeometryWeakDeg,
    );
  });

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

  test(
    'radial bridge cannot let a stale geometry baseline authorize an adjacent photo',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0, signatureByte: 0, grayShiftX: 0));

      // Accumulate the official smart-selection motion subsequence on preview
      // samples without spending a photo.
      for (final sample in <(double, int)>[(0.25, 4), (0.50, 8), (0.75, 12)]) {
        expect(
          h.feed(_pose(t: sample.$1, signatureByte: 0, grayShiftX: sample.$2)),
          AutoCaptureDecision.skipNotMoved,
        );
      }

      // Relative to the original geometry baseline this first candidate stays
      // below the formal parallax threshold, while the 1.25x depth change makes
      // it a radial bridge. It becomes the most recent *actual* photo.
      expect(
        h.feed(
          _pose(
            t: 1,
            pos: Vector3(0.12, 0, -0.20),
            signatureByte: 100,
            grayShiftX: 16,
          ),
        ),
        AutoCaptureDecision.fire,
        reason: 'the 12MP request must be backed by verified track novelty',
      );
      expect(h.controller.lastMotionRole, AutoCaptureMotionRole.radialBridge);

      // 666 ms later the old geometry baseline has accumulated >10 degrees,
      // but the camera moved only 4.4 cm from the photo just taken. Healthy
      // VINS evidence selects the 15-degree tier, so this stale baseline no
      // longer authorizes a candidate at all.
      expect(
        h.feed(
          _pose(
            t: 1.666,
            pos: Vector3(0.164, 0, -0.20),
            signatureByte: 121,
            grayShiftX: 17,
          ),
        ),
        AutoCaptureDecision.skipNotMoved,
      );
      expect(h.controller.lastMotionRole, AutoCaptureMotionRole.none);
      expect(h.fires, 1);
      expect(h.controller.geometryBaselinePosition, Vector3.zero());
    },
  );

  test('a stale asynchronous gray source cannot authorize a shutter', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, grayShiftX: 0));
    expect(
      h.feed(
        _pose(
          t: 1,
          pos: Vector3(0.30, 0, 0),
          grayShiftX: 4,
          graySourceTimestamp: 0.7,
        ),
      ),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
    expect(h.fires, 0);
    expect(h.controller.lastVisualSourceAgeSec, closeTo(0.3, 1e-12));
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
    h.feed(_pose(t: _fireT, pos: Vector3(0.30, 0, 0))); // fire,时钟=_fireT
    expect(h.fires, 1);
    h.feed(
      _pose(
        t: _fireT + 0.1,
        pos: Vector3(0.60, 0, 0),
        tracking: 'limited_excessive_motion',
      ),
    );
    // 距上次开火刚过一个地板 ⇒ 丢跟踪帧没偷走节奏预算。若它偷走了,这一帧
    // 会被判成 skipPaced。
    expect(
      h.feed(_pose(t: _fireT2, pos: Vector3(0.60, 0, 0))),
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
      h.feed(_pose(t: _fireT, pos: Vector3(0.30, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fireAttempts, 1);
    expect(h.controller.baselinePosition, Vector3.zero());
    // 30 Hz 连喂 0.2s:全部 skipPaced,不许每帧重试。
    for (var i = 1; i <= 6; i++) {
      expect(
        h.feed(_pose(t: _fireT + i / 30.0, pos: Vector3(0.30, 0, 0))),
        AutoCaptureDecision.skipPaced,
      );
    }
    expect(h.fireAttempts, 1);
    // 一个完整间隔后重试;成功即更新基准。
    h.enqueueSucceeds = true;
    expect(
      h.feed(_pose(t: _fireT2, pos: Vector3(0.30, 0, 0))),
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
      h.feed(_pose(t: _fireT, pos: Vector3(0.30, 0, 0)));
      expect(h.controller.baselinePosition, Vector3(0.30, 0, 0));
      // 相对新基准 0.05m ⇒ 不开火。
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.35, 0, 0))),
        AutoCaptureDecision.skipNotMoved,
      );
    },
  );

  test('a spatial candidate with the same actual still is redundant', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, grayShiftX: 0));

    expect(
      h.feed(_pose(t: 1, pos: Vector3(0.28, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.skipRedundant,
    );
    expect(h.fires, 0);
    expect(h.controller.lastTrackEvidence, isNotNull);
    expect(
      h.controller.lastTrackEvidence!.medianPixelDisplacement,
      lessThan(kOfficialCaptureMotionStepFraction * 128),
    );
    expect(h.controller.baselinePosition, Vector3.zero());
  });

  test('a successful photo advances the visual baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, grayShiftX: 0));

    // 这三拍验的是**内容递进**(grayShiftX 4→8→12 仍判重复)。每一拍都必须
    // 落在地板之外,否则拿到的是 skipPaced —— 节奏闸排在内容判据之前,时刻
    // 留在地板内就验不到这条测试真正要验的东西。
    var t = 0.0;
    for (final shift in <int>[4, 8, 12]) {
      t += kAutoCaptureSafetyDebounceSec + 0.05;
      expect(
        h.feed(_pose(t: t, pos: Vector3(0.28, 0, 0), grayShiftX: shift)),
        AutoCaptureDecision.skipRedundant,
      );
    }
    t += kAutoCaptureSafetyDebounceSec + 0.05;
    expect(
      h.feed(_pose(t: t, pos: Vector3(0.28, 0, 0), grayShiftX: 16)),
      AutoCaptureDecision.fire,
    );
    t += kAutoCaptureSafetyDebounceSec + 0.05;
    expect(
      h.feed(_pose(t: t, pos: Vector3(0.60, 0, 0), grayShiftX: 16)),
      AutoCaptureDecision.skipRedundant,
    );
    expect(h.fires, 1);
  });

  test(
    'a rejected actual 12MP frame blocks retries until that same feature gate sees new content',
    () {
      final tickets = <AutomaticStillTicket>[];
      var fires = 0;
      final controller = AutoCaptureController(
        onStartAnchor: (ticket) {
          tickets.add(ticket);
          return true;
        },
        onFire: (ticket) {
          tickets.add(ticket);
          fires++;
          return true;
        },
        paceProvider: () => ShutterPace.normal,
        capturedCountProvider: () => fires,
        thermalStateProvider: () => 0,
        liveDepthProvider: (_) => null,
      );
      final start = _pose(t: 0, grayShiftX: 0);
      controller.start(start);
      expect(tickets, hasLength(1));
      expect(
        controller.resolveAutomaticStill(
          ticket: tickets.single,
          accepted: true,
          acceptedStill: AcceptedAutomaticStill(
            frame: AutoCaptureGeometryFrame(
              camera: start.position,
              orientation: start.orientation,
              intrinsics: const AutoCaptureIntrinsics(
                fx: _fx,
                fy: _fx,
                cx: _w / 2,
                cy: _h / 2,
                imageWidth: _w,
                imageHeight: _h,
              ),
            ),
            captureTimestamp: 0,
            gray128: _trackGray(0),
          ),
        ),
        isTrue,
      );

      for (final sample in <(double, int)>[(0.25, 4), (0.50, 8), (0.75, 12)]) {
        expect(
          controller.onPose(
            _pose(
              t: sample.$1,
              pos: Vector3(0.28, 0, 0),
              grayShiftX: sample.$2,
            ),
          ),
          AutoCaptureDecision.skipRedundant,
        );
      }
      expect(
        controller.onPose(
          _pose(t: 1, pos: Vector3(0.28, 0, 0), grayShiftX: 16),
        ),
        AutoCaptureDecision.fire,
      );
      final rejectedTicket = tickets.last;
      expect(
        controller.resolveAutomaticStill(
          ticket: rejectedTicket,
          accepted: false,
          rejectedStill: RejectedAutomaticStillEvidence(
            gray128: _trackGray(8),
            intrinsics: const AutoCaptureIntrinsics(
              fx: _fx,
              fy: _fx,
              cx: _w / 2,
              cy: _h / 2,
              imageWidth: _w,
              imageHeight: _h,
            ),
          ),
        ),
        isTrue,
      );

      expect(
        controller.onPose(
          _pose(
            t: 1.30,
            pos: Vector3(0.28, 0, 0),
            grayShiftX: 20,
            signatureByte: 255,
          ),
        ),
        AutoCaptureDecision.skipRedundant,
        reason:
            'a changed 16x16 brightness signature cannot bypass the rejected actual-still feature evidence',
      );
      expect(fires, 1);
      final sufficientlyNovelShift = List<int>.generate(112, (i) => i + 9)
          .firstWhere((shift) {
            final evidence = trackFrameNovelty(
              previousGray: _trackGray(8),
              currentGray: _trackGray(shift),
              width: 128,
              height: 128,
              focalXPixels: 128,
              focalYPixels: 128,
              principalXPixels: 64,
              principalYPixels: 64,
            );
            return evidence.isCaptureNoveltyVerified ||
                evidence.lostTrackedOverlap;
          });
      expect(
        controller.onPose(
          _pose(
            t: 1.60,
            pos: Vector3(0.28, 0, 0),
            grayShiftX: sufficientlyNovelShift,
            signatureByte: 255,
          ),
        ),
        AutoCaptureDecision.fire,
        reason:
            'the retry re-arms only after the same actual-photo novelty gate sees enough motion; '
            'shift=$sufficientlyNovelShift '
            'main=${controller.lastTrackEvidence?.medianPixelDisplacement}/'
            '${controller.lastTrackEvidence?.commonTrackCount} '
            'rejected=${controller.lastRejectedActualTrackEvidence?.medianPixelDisplacement}/'
            '${controller.lastRejectedActualTrackEvidence?.commonTrackCount}',
      );
      expect(fires, 2);
    },
  );

  test('post-anchor photos wait for the official accumulated-flow subsequence', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, grayShiftX: 0));

    for (final sample in <(double, int)>[(0.25, 4), (0.50, 8), (0.75, 12)]) {
      expect(
        h.feed(
          _pose(t: sample.$1, pos: Vector3(0.22, 0, 0), grayShiftX: sample.$2),
        ),
        AutoCaptureDecision.skipRedundant,
        reason:
            'shift=${sample.$2} common=${h.controller.lastTrackEvidence?.commonTrackCount} '
            'motion=${h.controller.lastTrackEvidence?.medianPixelDisplacement} '
            'active=${h.controller.lastTrackEvidence?.vinsActiveTrackCount}',
      );
    }
    expect(h.fires, 0);
    expect(h.controller.lastTrackEvidence?.isCaptureNoveltyVerified, isFalse);
    expect(
      h.feed(_pose(t: 1.0, pos: Vector3(0.22, 0, 0), grayShiftX: 16)),
      AutoCaptureDecision.fire,
      reason: 'the capture-anchor displacement crossed 10% of short edge',
    );
    expect(h.fires, 1);
    expect(h.controller.lastTrackEvidence?.isCaptureNoveltyVerified, isTrue);
  });

  test('a failed enqueue does not advance the visual baseline', () {
    final h = _Harness()..enqueueSucceeds = false;
    h.controller.start(_pose(t: 0, signatureByte: 0));

    expect(
      h.feed(_pose(t: 1, pos: Vector3(0.22, 0, 0), signatureByte: 255)),
      AutoCaptureDecision.fire,
      reason:
          'track=${h.controller.lastTrackEvidence?.medianPixelDisplacement} '
          'common=${h.controller.lastTrackEvidence?.commonTrackCount} '
          'f=${h.controller.lastTrackEvidence?.vinsGeometricInlierFraction}',
    );
    h.enqueueSucceeds = true;
    expect(
      h.feed(_pose(t: 2, pos: Vector3(0.22, 0, 0), signatureByte: 255)),
      AutoCaptureDecision.fire,
      reason: '255 must still be compared with the last real photo at 0',
    );
    expect(h.fires, 1);
  });

  test('pose-only candidates wait for the next grayscale sample', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, signatureByte: 0));
    expect(
      h.feed(_pose(t: 1, pos: Vector3(0.22, 0, 0), sharpness: null)),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
    expect(h.fires, 0);
  });

  // ── pace / 热态只记账，不影响快门 ──

  test('shutter pressure does not stretch the spatial capture interval', () {
    final h = _Harness();
    h.pace = ShutterPace.soft;
    h.controller.start(_pose(t: 0));
    expect(h.feed(_pose(t: 0.25, yawDeg: 12.1)), AutoCaptureDecision.fire);
  });

  test('changing the telemetry pace mid-run never changes admission', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.feed(_pose(t: _fireT, pos: Vector3(0.30, 0, 0)));
    expect(h.fires, 1);
    h.pace = ShutterPace.hard;
    expect(
      h.feed(_pose(t: 0.55, pos: Vector3(0.30, 0, 0), yawDeg: 12.1)),
      AutoCaptureDecision.fire,
    );
  });

  test('serious thermal does not stretch the spatial capture interval', () {
    final h = _Harness();
    h.thermal = kAutoCaptureThermalSerious;
    h.controller.start(_pose(t: 0));
    expect(h.feed(_pose(t: 0.25, yawDeg: 12.1)), AutoCaptureDecision.fire);
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

  test('continuous fast motion stays spatially driven, not on a 1s clock', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 1 m/s 横移、30 fps、跑 3 s:位移 0.28m 约需 0.28s，仍显著快于旧 1 Hz。
    // 开火仍由空间角色决定；纯低重叠警告只提示，不额外花照片。
    for (var i = 1; i <= 90; i++) {
      final t = i / 30.0;
      h.feed(_pose(t: t, pos: Vector3(t * 1.0, 0, 0)));
    }
    expect(h.fires, greaterThan(3)); // 仍不是旧 1s 定时拍
    expect(h.fires, lessThanOrEqualTo(10));
    // 相邻开火间隔全部 ≥ 0.25s(允许一帧量化误差)。
    for (var i = 1; i < h.firedPoses.length; i++) {
      expect(
        h.firedPoses[i].timestamp - h.firedPoses[i - 1].timestamp,
        greaterThanOrEqualTo(0.25 - 1e-9),
      );
    }
  });

  // ── 画质硬门:复刻 Aether 原版 Laplacian variance < 200 拒收 ──

  test(
    'an objectively blurry frame is rejected and the next sharp frame fires',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0, sharpness: 1000));
      h.feed(_pose(t: 0.05, sharpness: 1000));
      h.feed(_pose(t: 0.10, sharpness: 1000));
      // Aether 的绝对硬门为 200；低于它时不拍，基准与去抖时钟都不动。
      expect(
        h.feed(_pose(t: _fireT, pos: Vector3(0.22, 0, 0), sharpness: 100)),
        AutoCaptureDecision.skipBlurry,
      );
      expect(h.fires, 0);
      // 画面重新通过绝对门 ⇒ 立刻开火，不需要等待人为超时。
      expect(
        h.feed(
          _pose(t: _fireT + 0.05, pos: Vector3(0.22, 0, 0), sharpness: 1000),
        ),
        AutoCaptureDecision.fire,
      );
      expect(h.fires, 1);
    },
  );

  test('persistent objective blur never fires merely because time elapsed', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 1000));
    h.feed(_pose(t: 0.05, sharpness: 1000));
    h.feed(_pose(t: 0.10, sharpness: 1000));
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 100)),
      AutoCaptureDecision.skipBlurry,
    );
    expect(
      h.feed(_pose(t: 60.0, pos: Vector3(0.22, 0, 0), sharpness: 100)),
      AutoCaptureDecision.skipBlurry,
    );
    expect(h.fires, 0);
  });

  test('bad exposure waits silently for the next usable frame', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 1000));
    expect(
      h.feed(
        _pose(
          t: _fireT,
          pos: Vector3(0.22, 0, 0),
          sharpness: 1000,
          meanBrightness: 30,
        ),
      ),
      AutoCaptureDecision.skipQuality,
    );
    expect(h.fires, 0);
    expect(
      h.feed(
        _pose(
          t: _fireT + 0.05,
          pos: Vector3(0.22, 0, 0),
          sharpness: 1000,
          meanBrightness: 128,
        ),
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('a sharp frame below the segment median is not mislabeled blurry', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 1200));
    h.feed(_pose(t: 0.05, sharpness: 1100));
    h.feed(_pose(t: 0.10, sharpness: 1000));
    // 800 低于本段中位数，但远高于 Aether 的 200 硬门，必须允许开火。
    expect(
      h.feed(_pose(t: _fireT, pos: Vector3(0.22, 0, 0), sharpness: 800)),
      AutoCaptureDecision.fire,
    );
  });

  test('firing resets the sharpness telemetry segment', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 1000));
    h.feed(_pose(t: 0.05, sharpness: 1000));
    h.feed(_pose(t: 0.10, sharpness: 1000));
    h.feed(_pose(t: _fireT, pos: Vector3(0.22, 0, 0), sharpness: 1000));
    expect(h.fires, 1);
    // 新段只保留开火后的样本；500 仍高于 Aether 的客观硬门。
    h.feed(_pose(t: 0.40, pos: Vector3(0.46, 0, 0), sharpness: 500));
    expect(
      h.feed(_pose(t: 0.60, pos: Vector3(0.46, 0, 0), sharpness: 500)),
      AutoCaptureDecision.fire,
    );
  });

  test('the fire frame still reports its sharpness snapshot AFTER the '
      'segment is cleared — the b29 telemetry-None bug', () {
    // 开火清段(subsequence)发生在页面读遥测之前;快照字段必须在清段前
    // 落下,否则 fire_sharpness 恒 None(b29 真机实证)。
    final h = _Harness();
    h.controller.start(_pose(t: 0, sharpness: 1000));
    h.feed(_pose(t: 0.05, sharpness: 1000));
    h.feed(_pose(t: 0.10, sharpness: 1000));
    expect(
      h.feed(_pose(t: 0.30, pos: Vector3(0.22, 0, 0), sharpness: 1000)),
      AutoCaptureDecision.fire,
    );
    // onPose 已返回、段已清空 —— 快照仍在。
    expect(h.controller.lastSharpness, closeTo(1000, 1e-9));
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
