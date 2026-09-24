// AutoCaptureController 接线测试 —— 开火判定 = stella_vslam
// `module::keyframe_inserter::new_keyframe_is_needed()` 整本复刻(2026-09-07)。
// 判据本身在 auto_capture_keyframe_inserter_policy_test.dart 逐条对拍;这里验接线。
//
// 合成预览 _trackGray 的校准(相对参考帧的横向位移 → 仍在跟踪的轨迹比例):
//    8 px ⇒ 97% > 0.9 ⇒ almost_all_lms_are_tracked ⇒ **不拍**(skipRedundant)
//   40 px ⇒ 72% < 0.8 ⇒ view_changed ⇒ 拍
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/map_keyframe_evidence.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

const int _w = 1000;
const int _h = 1000;
const double _fx = 1000;

Uint8List _signatureFor(double timestamp) {
  var x = ((timestamp * 1000000).round() ^ 0x6d2b79f5) & 0x7fffffff;
  return Uint8List.fromList(<int>[
    for (var i = 0; i < 256; i++)
      ((x = (1103515245 * x + 12345) & 0x7fffffff) >> 16) & 0xff,
  ]);
}

/// 128×128 合成预览:非周期哈希纹理整体右移 shiftX 像素。全画面有纹理,任何
/// 方向的位移都让约 shiftX/128 的参考轨迹出画面。
Uint8List _trackGray(int shiftX) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final sx = x - shiftX;
      var h = (sx * 73856093) ^ (y * 19349663);
      h = (h ^ (h >> 13)) * 1274126177;
      final coarse =
          ((((sx >> 3) * 2654435761) ^ ((y >> 3) * 40503)) >> 7) & 0xff;
      out[y * side + x] = ((coarse * 3 + (h & 0xff)) >> 2).clamp(0, 255);
    }
  }
  return out;
}

FrameQualityReport _quality(
  double s,
  double timestamp, {
  int? signatureByte,
  int? grayShiftX,
}) => FrameQualityReport(
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
  signature: signatureByte == null
      ? _signatureFor(timestamp)
      : (Uint8List(256)..fillRange(0, 256, signatureByte)),
  signatureWidth: 16,
  signatureHeight: 16,
  rawGray128: grayShiftX == null ? null : _trackGray(grayShiftX),
  sourceTimestamp: grayShiftX == null ? null : timestamp,
  sourceFocalX: grayShiftX == null ? null : 128,
  sourceFocalY: grayShiftX == null ? null : 128,
);

ARPose _pose({
  required double t,
  Vector3? pos,
  double yawDeg = 0,
  String? tracking = 'normal',
  double depthM = 1.0,
  double? sharpness = 1000,
  int? signatureByte,
  int? grayShiftX,
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
    isTracking: tracking == 'normal',
    trackingStateName: tracking,
    timestamp: t,
    hasOrigin: true,
    worldOrigin: Vector3(0, 0, -1),
    worldYaw: 0,
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: <double>[_fx, _fx, _w / 2, _h / 2],
    imageWidth: _w,
    imageHeight: _h,
    quality: sharpness == null
        ? null
        : _quality(
            sharpness,
            t,
            signatureByte: signatureByte,
            grayShiftX: grayShiftX,
          ),
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

class _Harness {
  int fires = 0;
  int fireAttempts = 0;
  bool enqueueSucceeds = true;
  int captured = 0;
  bool mapperAccepting = true;
  double? liveDepthM;
  final List<AutoCaptureMotionRole?> firedRoles = <AutoCaptureMotionRole?>[];

  late final AutoCaptureController controller = AutoCaptureController(
    onStartAnchor: () => true,
    onFire: () {
      fireAttempts++;
      if (!enqueueSucceeds) return false;
      fires++;
      captured++;
      return true;
    },
    paceProvider: () => ShutterPace.normal,
    capturedCountProvider: () => captured,
    thermalStateProvider: () => 0,
    liveDepthProvider: (pose) => liveDepthM,
    mapperAcceptingProvider: () => mapperAccepting,
    mapEvidenceProvider: (pose) => mapEvidence,
  );

  /// 地图口径读数;null = 取不到(退回 LK 口径)。测试里现喂。
  StellaMapEvidence? mapEvidence;

  /// false = 模拟真机快门事务:照片要等页面回调 onCaptureCompleted 才算拍成。
  bool instantCapture = true;

  AutoCaptureDecision feed(ARPose pose) {
    final decision = controller.onPose(pose);
    if (decision == AutoCaptureDecision.fire && enqueueSucceeds) {
      firedRoles.add(controller.lastMotionRole);
      if (instantCapture) {
        controller.onCaptureCompleted(captureTimestampSec: pose.timestamp);
      }
    }
    return decision;
  }
}

/// 起跑锚 + 一帧同画面预览(把参考轨迹种下)。
_Harness _started() {
  final h = _Harness();
  h.controller.start(_pose(t: 0, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0));
  h.feed(_pose(t: 0.1, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0));
  return h;
}

void main() {
  // ─── [DEVICE-POSE-TRUST 2026-09-24] tracking 硬闸看追踪器,不看 hybrid ──────
  // CaptureSession._resolveHybridPose 在 ARKit limited 时产出的就是
  // `raw.copyWith(isTracking: true)`(az/el 换成 IMU 推算,trackingStateName
  // 原样保留)。cap_1787733401226757:924 次判定 skipTracking=0,3 张拍在
  // limited_initializing 窗口里。spec §7:limited ⇒ 零触发且基准帧不动。
  group('tracking 硬闸 × hybrid 位姿', () {
    ARPose hybridOf(ARPose raw) => raw.copyWith(isTracking: true);

    test('阳性对照:normal 帧、同一几何 ⇒ 开火', () {
      final h = _started();
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      expect(h.fires, 1);
    });

    test(
      '🔴 hybrid(limited_initializing,isTracking 被强置 true)⇒ skipTracking',
      () {
        final h = _started();
        final raw = _pose(
          t: 0.2,
          pos: Vector3(40 / 128, 0, 0),
          grayShiftX: 40,
          tracking: 'limited_initializing',
        );
        final p = hybridOf(raw);
        expect(p.isTracking, isTrue, reason: '这就是 hybrid 骗过旧闸的那一位');
        expect(p.trackingStateName, 'limited_initializing');
        expect(h.feed(p), AutoCaptureDecision.skipTracking);
        expect(h.fires, 0);
        // 恢复 normal 后同一几何照常开火(闸只停,不永久卡死)。
        expect(
          h.feed(_pose(t: 0.3, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
          AutoCaptureDecision.fire,
        );
      },
    );

    test('provider 没给状态(null,mock 约定)⇒ 维持原 isTracking 语义', () {
      final h = _started();
      final p = hybridOf(
        _pose(
          t: 0.2,
          pos: Vector3(40 / 128, 0, 0),
          grayShiftX: 40,
          tracking: null,
        ),
      );
      expect(p.isTracking, isTrue);
      expect(p.trackingStateName, isNull);
      expect(h.feed(p), AutoCaptureDecision.fire);
    });
  });

  // ─── 地图口径接线(2026-09-11 A 路)────────────────────────────────
  // 判据本身一个字节没改;换的是喂给它的三个量。顺序照抄上游
  // tracking_module.cc:145-148:先判跟踪成没成功,没成功就根本不问判据。
  group('地图口径', () {
    StellaMapEvidence ev(int tracked, int reliable, int ref) =>
        StellaMapEvidence(
          numTrackedLms: tracked,
          numReliableLms: reliable,
          numReliableLmsRef: ref,
          minNumObsThr: 3,
          localKeyframeCount: 4,
          localLandmarkCount: 500,
        );

    test('没有地图口径时,用的还是 LK 轨迹口径(阳性对照:行为不变)', () {
      final h = _started();
      expect(h.controller.lastEvidenceSource, 'tracks');
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8)),
        AutoCaptureDecision.skipRedundant,
      );
      expect(h.controller.lastEvidenceSource, 'tracks');
    });

    test('🔴 跟踪没成功(<20)⇒ 判据不问地图口径,退回 LK', () {
      final h = _started();
      h.mapEvidence = ev(19, 1000, 1000);
      h.feed(_pose(t: 0.2, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8));
      expect(h.controller.lastEvidenceSource, 'tracks');
      expect(h.controller.lastMapEvidence, isNotNull, reason: '读数照样记,只是不采信');
    });

    test('跟踪成功(>=20)⇒ 三个量一起换成地图口径', () {
      final h = _started();
      h.mapEvidence = ev(400, 1000, 1000);
      h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40));
      expect(h.controller.lastEvidenceSource, 'map');
    });

    test('🔴 地图口径说"还是同一批东西"就不拍 —— 哪怕 LK 说画面已经换了', () {
      final h = _started();
      // 40 px 在 LK 口径下 < 80%(会开火);地图口径给 0.95 > 0.9 ⇒ 冗余。
      h.mapEvidence = ev(400, 950, 1000);
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.skipRedundant,
      );
      expect(h.controller.lastEvidenceSource, 'map');
      expect(h.fires, 0);
    });

    test('🔴 地图口径说"视角换了"就拍 —— 哪怕 LK 说还是老样子', () {
      final h = _started();
      // 8 px 在 LK 口径下 > 90%(会报冗余);地图口径给 0.5 < 0.8 ⇒ 视角已变。
      h.mapEvidence = ev(400, 500, 1000);
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8)),
        AutoCaptureDecision.fire,
      );
      expect(h.controller.lastEvidenceSource, 'map');
    });
  });

  test('a stopped controller never fires', () {
    final h = _Harness();
    for (var i = 0; i < 60; i++) {
      h.controller.onPose(_pose(t: i.toDouble(), grayShiftX: i));
    }
    expect(h.fires, 0);
  });

  test('fixture: 8 px keeps > 90% of the tracks, 40 px drops below 80%', () {
    final a = _started()
      ..feed(_pose(t: 0.2, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8));
    final e8 = a.controller.lastTrackEvidence!;
    expect(e8.commonTrackCount, greaterThan(e8.seedTrackCount * 0.9));
    final b = _started()
      ..feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40));
    final e40 = b.controller.lastTrackEvidence!;
    expect(e40.commonTrackCount, lessThan(e40.seedTrackCount * 0.8));
    expect(e40.commonTrackCount, greaterThan(15));
  });

  test(
    'almost_all_lms_are_tracked: the same view is never photographed twice',
    () {
      final h = _started();
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8)),
        AutoCaptureDecision.skipRedundant,
      );
      expect(
        h.feed(_pose(t: 0.3, pos: Vector3(8 / 128, 0, 0), grayShiftX: 8)),
        AutoCaptureDecision.skipRedundant,
      );
      expect(h.fires, 0);
    },
  );

  test('[用户 2026-09-07] 大幅移动 + 转头,但画面内容不变 ⇒ 一张也不拍', () {
    // 相机在一个区域里前后左右上下挪了 2 米、还转了 180°,看到的还是同一批
    // 东西(预览不变)⇒ 上游强制项 !almost_all_lms_are_tracked 全程拦住。
    final h = _started();
    var t = 0.2;
    for (final p in <Vector3>[
      Vector3(0.5, 0, 0),
      Vector3(0.5, 0.5, 0),
      Vector3(-0.8, 0.3, 0.4),
      Vector3(1.5, -0.6, -0.9),
      Vector3(2.0, 0.2, 0.7),
    ]) {
      expect(
        h.feed(_pose(t: t, pos: p, yawDeg: t * 90, grayShiftX: 0)),
        AutoCaptureDecision.skipRedundant,
        reason: 'pos=$p t=$t(已远超 max_interval 1 s,仍然不拍)',
      );
      t += 0.5;
    }
    expect(h.fires, 0);
  });

  test('[用户 2026-09-07] 原地转头:画面换了,但相机没动 ⇒ min_distance 挡住', () {
    // SVO 论文的式子:门槛 = 12% × 场景深度。深度 1 m ⇒ 要走够 12 cm。
    final h = _started()
      ..liveDepthM = 1.0
      ..captured = 10;
    // 先走 31 cm 拍一张(画面同步右移 40 px),上一张照片的位置钉在 x=0.31。
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(0.31, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    // 接着**站在原地**转头:预览一路滚(内容确实换了),位置一动不动。
    var shift = 80;
    for (var t = 0.4; t < 2.0; t += 0.2) {
      expect(
        h.feed(
          _pose(
            t: t,
            pos: Vector3(0.31, 0, 0),
            yawDeg: t * 60,
            grayShiftX: shift % 128,
          ),
        ),
        anyOf(
          AutoCaptureDecision.skipMinDistance,
          AutoCaptureDecision.skipRedundant,
        ),
        reason: 't=$t shift=$shift —— 转头绝不能拍出第二张',
      );
      shift += 40;
    }
    expect(h.fires, 1, reason: '整段只有最开始那一张');
  });

  test('走够 12% 场景深度就恢复开火', () {
    final h = _started()
      ..liveDepthM = 1.0
      ..captured = 10;
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(0.31, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    expect(
      h.feed(_pose(t: 0.4, pos: Vector3(0.41, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.skipMinDistance,
      reason: '相对上一张只走了 10 cm < 12 cm',
    );
    expect(
      h.feed(_pose(t: 0.6, pos: Vector3(0.44, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.fire,
      reason: '走了 13 cm > 12 cm,而且画面也换了',
    );
    expect(h.fires, 2);
  });

  test('深度越远门槛越高:同样走 13 cm,10 m 深度下不算走够', () {
    final h = _started()
      ..liveDepthM =
          10.0 // 门槛 1.2 m
      ..captured = 10;
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(0.31, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    expect(
      h.feed(_pose(t: 0.4, pos: Vector3(0.44, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.skipMinDistance,
    );
    expect(
      h.feed(_pose(t: 0.6, pos: Vector3(1.81, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.fire,
    );
  });

  test('[2026-09-07 前提修正] 冷启动豁免只放过时间下限,不放过距离下限', () {
    // stella 出厂 min_distance = -1,它的 !enough_keyfrms 豁免从没绕过距离门;
    // 我们把 min_distance 打开(值取自 SVO),就得连 SVO 的适用范围一起取:
    // SVO 的 needNewKf 对每一个共视关键帧都比 12%,没有冷启动豁免。
    final h = _started()
      ..liveDepthM = 1.0
      ..captured = 0;
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(0.31, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    // 原地转头把画面换了,但位移 0 ⇒ 照片数还不到 5 也必须挡住。
    expect(
      h.feed(_pose(t: 0.25, pos: Vector3(0.31, 0, 0), grayShiftX: 80)),
      AutoCaptureDecision.skipMinDistance,
      reason: '冷启动期也不许原地转头出片',
    );
    // 时间下限仍照搬 stella 的豁免:照片数 ≤5 时 0.05 s 的间隔不算过快。
    expect(
      h.feed(_pose(t: 0.3, pos: Vector3(0.51, 0, 0), grayShiftX: 80)),
      AutoCaptureDecision.fire,
      reason: '走够 20 cm > 12 cm,且冷启动期不受 min_interval 0.1 s 限制',
    );
  });

  test('view_changed → fire, tagged keyframeInserter', () {
    final h = _started();
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
    expect(h.firedRoles.single, AutoCaptureMotionRole.keyframeInserter);
    expect(
      h.controller.lastMotionMetrics!.role,
      AutoCaptureMotionRole.keyframeInserter,
    );
  });

  // 2026-09-07 真机定罪(未命名(24)):这个位置原来钉的是相反的行为 ——
  // 「重建队列非空 ⇒ skipMapperBusy,排空后才允许开火」。上机后 20/20 次快门
  // 都落在上一帧 `add_frame rc=ok` 之后 23–303 ms 内,到达该闸的 196 个 tick
  // 里 178 个被挡、通过的 18 个全部开火 ⇒ **快门节奏完全由重建队列决定**,
  // 用户体感是"动的时候不拍、停一两秒就拍"。拍摄与重建必须解耦:
  // 遇到合格视角就拍,不等重建。
  test('重建队列深度不得进入快门判决 —— 拍摄与重建解耦', () {
    final h = _started();
    // 连续开火,期间不给重建任何机会"排空";每一步都只由几何决定。
    for (var i = 1; i <= 3; i++) {
      final d = h.feed(
        _pose(
          t: 0.2 * i,
          pos: Vector3(40.0 * i / 128, 0, 0),
          grayShiftX: 40 * i,
        ),
      );
      expect(
        d,
        AutoCaptureDecision.fire,
        reason: '第 $i 次:几何已达标就必须开火,不许被任何重建侧状态推迟',
      );
    }
    expect(h.fires, 3);
  });

  test('mapper paused (shutter queue not accepting) → skipMapperStopped', () {
    final h = _started()..mapperAccepting = false;
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.skipMapperStopped,
    );
    expect(h.fires, 0);
  });

  test(
    'a fire re-seeds the reference: the photographed view is then redundant',
    () {
      final h = _started();
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      expect(
        h.feed(_pose(t: 0.3, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.skipRedundant,
      );
      expect(
        h.feed(_pose(t: 0.5, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.fire,
        reason: '相对刚拍成的参考(40)回到 0 ⇒ 共有 71% < 80%',
      );
      expect(h.fires, 2);
    },
  );

  test('min_interval 0.1 s only bites after more than 5 photos', () {
    final h = _started()..captured = 6;
    expect(
      h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
    expect(
      h.feed(_pose(t: 0.25, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.skipPaced,
      reason: '距上一张只有 0.05 s < min_interval 0.1 s',
    );
    expect(
      h.feed(_pose(t: 0.35, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
      AutoCaptureDecision.fire,
    );
  });

  test('no track evidence (no preview gray) → skipNoVisualEvidence', () {
    final h = _started();
    expect(h.feed(_pose(t: 0.2)), AutoCaptureDecision.skipNoVisualEvidence);
  });

  group('基准取实拍瞬间(2026-09-06 抄对①)', () {
    test('a shutter in flight blocks decisions; completion re-seeds at the '
        'capture instant', () {
      final h = _started()..instantCapture = false;
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(0.22, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      expect(h.controller.awaitingCaptureBaseline, isTrue);
      // [2026-09-09 解耦] 在飞期间喂的是**几何完全合格**的帧(相对实拍参考
      // 位移 40 px ⇒ view_changed,行进 20 cm > 12 cm ⇒ 过距离下限)。旧排序
      // 下这条闸排在几何**之前**,喂什么都返回 skipAwaitingCapture,看不出
      // 它到底挡掉了什么;现在闸排在最后,拿到 skipAwaitingCapture 就等于
      // 「几何已经说开火、被这道闸挡住」—— 这才是要钉的东西。
      for (var t = 0.3; t < 0.65; t += 0.1) {
        expect(
          h.feed(
            _pose(
              t: t,
              pos: Vector3(0.22 + (t - 0.2) * 2.0, 0, 0),
              grayShiftX: 80,
            ),
          ),
          AutoCaptureDecision.skipAwaitingCapture,
          reason: 't=$t',
        );
      }
      expect(h.fires, 1);
      // 照片在 t=0.6 真正拍成:参考 = 那一刻的位姿/预览。
      h.controller.onCaptureCompleted(captureTimestampSec: 0.6);
      expect(h.controller.awaitingCaptureBaseline, isFalse);
      expect(h.controller.baselinePosition!.x, closeTo(1.02, 1e-9));
      expect(
        h.feed(_pose(t: 0.7, pos: Vector3(1.02, 0, 0), grayShiftX: 80)),
        AutoCaptureDecision.skipRedundant,
        reason: '与实拍帧同画面 ⇒ 共有 100% ⇒ almost_all',
      );
      expect(h.fires, 1);
    });

    test('min_distance 从**实拍位置**量起,不是从按快门那一刻', () {
      final h = _started()
        ..liveDepthM = 1.0
        ..captured = 10
        ..instantCapture = false;
      // 在原点按下快门。
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      // 快门事务进行中相机继续走了 50 cm,照片在 x=0.5 处才真正拍成。
      for (var t = 0.3; t < 0.65; t += 0.1) {
        h.feed(
          _pose(t: t, pos: Vector3((t - 0.2) * 1.0, 0, 0), grayShiftX: 40),
        );
      }
      h.controller.onCaptureCompleted(captureTimestampSec: 0.6);
      // 相对**实拍位置** 0.4 m 只走了 8 cm(<12 cm)⇒ 不许再拍。
      expect(
        h.feed(_pose(t: 0.8, pos: Vector3(0.48, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.skipMinDistance,
        reason: '若错用请求位置(0)当原点,这里会算成走了 48 cm 而放行',
      );
      expect(
        h.feed(_pose(t: 1.0, pos: Vector3(0.55, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.fire,
        reason: '相对实拍位置走了 15 cm > 12 cm',
      );
    });

    test('a failed shutter transaction resumes decisions immediately', () {
      final h = _started()..instantCapture = false;
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      // 同上:喂一帧几何会开火的(走了 20 cm、画面换了 40 px),证明挡住它
      // 的是这道闸而不是几何。
      expect(
        h.feed(
          _pose(t: 0.3, pos: Vector3(40 / 128 + 0.2, 0, 0), grayShiftX: 80),
        ),
        AutoCaptureDecision.skipAwaitingCapture,
      );
      h.controller.onCaptureFailed();
      expect(h.controller.awaitingCaptureBaseline, isFalse);
      expect(
        h.feed(_pose(t: 0.4, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.fire,
        reason: '参考是请求时刻那帧(40),回到 0 ⇒ view_changed',
      );
    });

    test('a completion that never arrives times out after 2 s', () {
      final h = _started()..instantCapture = false;
      expect(
        h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
        AutoCaptureDecision.fire,
      );
      expect(
        h.feed(_pose(t: 2.1, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.skipAwaitingCapture,
      );
      expect(
        h.feed(_pose(t: 2.3, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0)),
        AutoCaptureDecision.fire,
        reason: '超时后恢复判定;参考是请求时刻那帧(40)',
      );
    });
  });

  test('stop() forgets the last-keyframe bookkeeping', () {
    final h = _started();
    h.feed(_pose(t: 0.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40));
    h.controller.stop();
    h.controller.start(
      _pose(t: 5.0, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0),
    );
    h.feed(_pose(t: 5.1, pos: Vector3(0 / 128, 0, 0), grayShiftX: 0));
    expect(
      h.feed(_pose(t: 5.2, pos: Vector3(40 / 128, 0, 0), grayShiftX: 40)),
      AutoCaptureDecision.fire,
    );
  });
}
