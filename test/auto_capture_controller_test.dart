import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

const int _w = 1000;
const int _h = 1000;
const double _fx = 1000;

/// 相机在 [pos],朝向由绕 Y 轴的 [yawDeg] 决定(0 = 看向 -Z)。
/// 特征点铺在相机前方 [depthM] 处,足够触发中位深度估计。
///
/// 默认值刻意与任务书给的辅助函数逐字等价;其余具名参数是后加的
/// 单变量旋钮(点数、内参、画幅、tracking 两路信号),默认全部不改变行为。
ARPose _pose({
  required double t,
  Vector3? pos,
  double yawDeg = 0,
  String? tracking = 'normal',
  bool? isTracking,
  double depthM = 1.0,
  int pointCount = 12,
  double fx = _fx,
  double? fy,
  bool withIntrinsics = true,
  List<double>? intrinsics,
  int width = _w,
  int height = _h,
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
    hasOrigin: true,
    worldOrigin: Vector3.zero(),
    worldYaw: 0,
    // extrinsic4x4 与 intrinsicFxFyCxCy 都是 ARPose 的 required 参数。
    // 本判据不消费 extrinsic,给空列表即可(mock 路径的合法取值)。
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: intrinsics ??
        (withIntrinsics
            ? <double>[fx, fy ?? fx, width / 2, height / 2]
            : const <double>[]),
    imageWidth: width,
    imageHeight: height,
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
  bool enqueueSucceeds = true;
  ShutterPace pace = ShutterPace.normal;
  int captured = 0;

  late final AutoCaptureController controller = AutoCaptureController(
    onFire: () {
      if (!enqueueSucceeds) return false;
      fires++;
      captured++;
      return true;
    },
    paceProvider: () => pace,
    capturedCountProvider: () => captured,
  );
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

  test('walking straight at the object fires nothing — the double-wall case', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // Creep forward 1 cm per 6 Hz frame for 10 s: 60 cm of travel, ~0 parallax.
    for (var i = 1; i <= 60; i++) {
      h.controller.onPose(
        _pose(t: i / 6.0, pos: Vector3(0, 0, -i * 0.01)),
      );
    }
    expect(h.fires, 0);
  });

  test('lateral movement past the parallax floor fires on the tick', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 0.1 m sideways at 1 m depth ≈ 5.7° parallax, past the 5° floor.
    h.controller.onPose(_pose(t: 0.5, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 0, reason: 'tick has not elapsed yet');
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);
  });

  test('fast lateral movement fires before the tick via the overlap bound', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 0.35 m sideways at 1 m depth => s = 0.35 >= 0.30 upper bound.
    h.controller.onPose(_pose(t: 0.2, pos: Vector3(0.35, 0, 0)));
    expect(h.fires, 1);
  });

  test('pure rotation fires via the turn threshold', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, yawDeg: 12));
    expect(h.fires, 1);
  });

  test('a failed enqueue leaves the baseline untouched', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    final baselineBefore = h.controller.baselineDepthM;

    h.enqueueSucceeds = false;
    final d = h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.2, 0, 0)));
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 0);
    expect(h.controller.baselineDepthM, baselineBefore);

    // The same displacement must still be judged against the ORIGINAL
    // baseline, so it fires again once the queue accepts.
    h.enqueueSucceeds = true;
    h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.2, 0, 0)));
    expect(h.fires, 1);
  });

  test('non-normal tracking fires nothing and freezes the baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    final before = h.controller.baselineDepthM;
    final d = h.controller.onPose(
      _pose(t: 1.0, pos: Vector3(5, 0, 0), tracking: 'limited_relocalizing'),
    );
    expect(d, AutoCaptureDecision.skipTracking);
    expect(h.fires, 0);
    expect(h.controller.baselineDepthM, before);

    // The depth scalar alone cannot see the baseline MOVE (it is 1 m either
    // way), so pin the position too: back at normal, 0.2 m from the origin
    // still reads as 11° of parallax — which it only can if the baseline
    // never followed the limited frame out to x = 5.
    expect(
      h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.2, 0, 0))),
      AutoCaptureDecision.fire,
    );
  });

  test('shutter pace stretches the tick interval', () {
    final h = _Harness()..pace = ShutterPace.hard;
    h.controller.start(_pose(t: 0));
    // 0.1 m sideways clears the parallax floor but not the 3 s hard tick.
    h.controller.onPose(_pose(t: 1.5, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 0);
    h.controller.onPose(_pose(t: 3.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);
  });

  test('the 300-frame cap stops the run', () {
    final h = _Harness()..captured = 300;
    h.controller.start(_pose(t: 0));
    final d = h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipCapped);
    expect(h.controller.isRunning, isFalse);
  });

  test('the five-minute limit stops the run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    final d = h.controller.onPose(_pose(t: 300.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipTimeLimit);
    expect(h.controller.isRunning, isFalse);
  });

  // ──────────────────────────────────────────────────────────────────────
  // 以下是任务书之外补的编排测试。有状态代码的风险几乎全在**连续多帧
  // 之间**:基准漂移、tick 记账、停止后的残留状态、入队失败后的重试
  // 节奏、跑着的时候宿主状态变了 —— 只调一次 onPose 的测试一条都抓不到。
  // ──────────────────────────────────────────────────────────────────────

  test('start() marks the run live and seeds the baseline depth from the '
      'scene points', () {
    final h = _Harness();
    expect(h.controller.isRunning, isFalse);
    expect(h.controller.baselineDepthM, isNull);

    h.controller.start(_pose(t: 0, depthM: 2.5));

    expect(h.controller.isRunning, isTrue);
    expect(h.controller.baselineDepthM, closeTo(2.5, 1e-9));
  });

  test('stop() clears the baseline and halts firing mid-run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.stop();

    expect(h.controller.isRunning, isFalse);
    expect(h.controller.baselineDepthM, isNull);

    // 0.5 m sideways clears both gates outright — it must still not fire.
    final d = h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipNotMoved);
    expect(h.fires, 0);
  });

  test('a run stopped by the frame cap ignores later poses even after the '
      'count drops back', () {
    final h = _Harness()..captured = 300;
    h.controller.start(_pose(t: 0));
    expect(
      h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.5, 0, 0))),
      AutoCaptureDecision.skipCapped,
    );

    // Say the host's count drops back (queue drained, frames pruned): the
    // run is over regardless — the controller no longer consults anything.
    h.captured = 0;
    final d = h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipNotMoved);
    expect(h.fires, 0);
  });

  test('a run stopped by the time limit stops evaluating later poses', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.controller.onPose(_pose(t: 300.0, pos: Vector3(0.5, 0, 0))),
      AutoCaptureDecision.skipTimeLimit,
    );

    // Not `skipTimeLimit` a second time: the run stopped, so the governor
    // is not consulted at all any more.
    final d = h.controller.onPose(_pose(t: 301.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipNotMoved);
    expect(h.fires, 0);
  });

  test('a 6 Hz stream of continuous motion fires once per tick, not once '
      'per frame', () {
    final h = _Harness();
    // fx = 500 on a 1000 px wide frame is wide enough that 2 s of this walk
    // never reaches the 0.30 overlap bound, so only the tick can fire —
    // which is the whole point of this test.
    h.controller.start(_pose(t: 0, fx: 500));
    for (var i = 1; i <= 12; i++) {
      // 9 cm per frame at 1 m depth: EVERY frame is past the 5° parallax
      // floor on its own, so without tick accounting this fires 6 Hz.
      h.controller.onPose(
        _pose(t: i / 6.0, pos: Vector3(i * 0.09, 0, 0), fx: 500),
      );
    }
    expect(h.fires, 2, reason: '2 s of walking at a 1 s tick');
  });

  test('start() seeds both clocks from the pose timestamp, not from zero', () {
    final h = _Harness();
    // ARFrame timestamps are seconds since boot — never near zero.
    h.controller.start(_pose(t: 1000.0));

    // Tick clock: 0.5 s in, the tick has not elapsed.
    expect(
      h.controller.onPose(_pose(t: 1000.5, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    // Elapsed clock: 1 s into the run, nowhere near the 5-minute limit.
    expect(
      h.controller.onPose(_pose(t: 1001.0, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('the five-minute limit counts from the start of the run, not from the '
      'last capture', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    // The tick clock now sits 1 s ahead of the run clock; the two are only
    // distinguishable once something has actually fired.
    expect(h.fires, 1);

    // 300 s into the RUN, but only 299 s since that capture.
    final d = h.controller.onPose(_pose(t: 300.0, pos: Vector3(0.5, 0, 0)));
    expect(d, AutoCaptureDecision.skipTimeLimit);
    expect(h.controller.isRunning, isFalse);
    expect(h.fires, 1);
  });

  test('restarting resets both clocks', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);

    h.controller.stop();
    h.controller.start(_pose(t: 500.0));

    // Tick clock restarted at 500 s (a stale 1.0 would fire immediately).
    expect(
      h.controller.onPose(_pose(t: 500.5, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    // Elapsed clock restarted too (a stale 0 would read 500 s > the limit).
    expect(
      h.controller.onPose(_pose(t: 501.0, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 2);
  });

  test('the shutter pace is read on every pose, so slowing down mid-run '
      'stretches the next tick', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);

    h.pace = ShutterPace.hard; // the queue got deep while the run was live
    expect(
      h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.2, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.controller.onPose(_pose(t: 4.0, pos: Vector3(0.2, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 2);
  });

  test('the captured count is read on every pose, so hitting the cap mid-run '
      'stops the run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);

    h.captured = 300; // manual shutter taps land in the same 300-frame cap
    final d = h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.3, 0, 0)));
    expect(d, AutoCaptureDecision.skipCapped);
    expect(h.controller.isRunning, isFalse);
    expect(h.fires, 1);
  });

  test('a tracking hiccup pauses the run without ending it or moving the '
      'baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.controller.onPose(
        _pose(
          t: 1.0,
          pos: Vector3(0.2, 0, 0),
          tracking: 'limited_excessive_motion',
        ),
      ),
      AutoCaptureDecision.skipTracking,
    );
    expect(h.fires, 0);
    expect(h.controller.isRunning, isTrue);

    // Recovered without moving further: the displacement is still measured
    // from the ORIGINAL baseline, so this fires. Had the baseline followed
    // the limited frame, parallax would now be 0 and nothing would fire.
    expect(
      h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.2, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('a pose with no tracking-state string still counts as tracking when '
      'isTracking is set', () {
    // Non-ARKit backends (ARCore, WebXR, HarmonyOS) publish no state string.
    final h = _Harness();
    h.controller.start(_pose(t: 0, tracking: null, isTracking: true));
    final d = h.controller.onPose(
      _pose(t: 1.0, pos: Vector3(0.1, 0, 0), tracking: null, isTracking: true),
    );
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('a pose with isTracking false is skipped even when no tracking-state '
      'string is present', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    final d = h.controller.onPose(
      _pose(t: 1.0, pos: Vector3(0.5, 0, 0), tracking: null, isTracking: false),
    );
    expect(d, AutoCaptureDecision.skipTracking);
    expect(h.fires, 0);
  });

  test('a hybrid pose with isTracking forced true is skipped while the '
      'state string is limited', () {
    // CaptureSession substitutes IMU dead reckoning and flips isTracking
    // back to true, deliberately keeping the raw ARKit reason string.
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    final d = h.controller.onPose(
      _pose(
        t: 1.0,
        pos: Vector3(0.5, 0, 0),
        tracking: 'limited_excessive_motion',
        isTracking: true,
      ),
    );
    expect(d, AutoCaptureDecision.skipTracking);
    expect(h.fires, 0);
  });

  test('a failed enqueue still consumes the tick, so the retry waits a full '
      'interval', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    h.enqueueSucceeds = false;
    expect(
      h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 0);

    // spec §7 says "retry on the next tick", not "retry on the next frame".
    h.enqueueSucceeds = true;
    expect(
      h.controller.onPose(_pose(t: 1.5, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('a successful enqueue moves the baseline to the frame that was shot',
      () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0)));
    expect(h.fires, 1);

    // Measured from the NEW baseline at x = 0.1, standing at x = 0.1 has not
    // moved at all. A baseline still stuck at the origin would re-fire.
    final d = h.controller.onPose(_pose(t: 2.0, pos: Vector3(0.1, 0, 0)));
    expect(d, AutoCaptureDecision.skipNotMoved);
    expect(h.fires, 1);
  });

  test('a successful enqueue also refreshes the baseline scene depth', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 1.0));
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));

    h.controller.onPose(
      _pose(t: 1.0, pos: Vector3(0.1, 0, 0), depthM: 3.0),
    );
    expect(h.fires, 1);
    expect(h.controller.baselineDepthM, closeTo(3.0, 1e-9));
  });

  test('a failed enqueue leaves the baseline scene depth untouched', () {
    // The sharp version of the brief's baseline check: here the depth the
    // baseline WOULD have taken (3 m) differs from the one it must keep.
    final h = _Harness()..enqueueSucceeds = false;
    h.controller.start(_pose(t: 0, depthM: 1.0));

    expect(
      h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0), depthM: 3.0)),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 0);
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));
  });

  test('standing still through several ticks does not end the run', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    for (var i = 1; i <= 18; i++) {
      final d = h.controller.onPose(_pose(t: i / 6.0));
      // The tick clock measures time since the last CAPTURE, so it does
      // not advance while nothing fires: the first 5 frames are "not yet",
      // and from the 1 s mark on every frame is judged and reports "you
      // have not moved". Neither one ends the run.
      expect(
        d,
        i < 6
            ? AutoCaptureDecision.skipPaced
            : AutoCaptureDecision.skipNotMoved,
      );
    }
    expect(h.controller.isRunning, isTrue);

    final d = h.controller.onPose(_pose(t: 4.0, pos: Vector3(0.1, 0, 0)));
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('too few feature points degrade the parallax gate to zero, not to a '
      'fire', () {
    final h = _Harness();
    // 7 points is one short of the 8-anchor floor, so depth is untrusted.
    h.controller.start(_pose(t: 0, pointCount: 7));
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9),
        reason: 'the documented fallback depth');

    final d = h.controller.onPose(
      _pose(t: 1.0, pos: Vector3(0.2, 0, 0), pointCount: 7),
    );
    expect(d, AutoCaptureDecision.skipNotMoved,
        reason: '0.2 m sideways would be 11° of parallax if depth were real');
    expect(h.fires, 0);
  });

  test('too few feature points also switch off the overlap bound instead of '
      'firing on it', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, pointCount: 0));
    // 0.5 m sideways at the fallback depth would be s = 0.5, well past the
    // 0.30 bound — but with no trusted depth there is no bound to cross.
    final d = h.controller.onPose(
      _pose(t: 0.2, pos: Vector3(0.5, 0, 0), pointCount: 0),
    );
    expect(d, AutoCaptureDecision.skipPaced);
    expect(h.fires, 0);
  });

  test('missing camera intrinsics switch off the overlap bound but leave the '
      'tick gate working', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, withIntrinsics: false));
    // s would be 0.5 if the bound were evaluable. It is not — and "unknown"
    // must not be read as "fire now".
    expect(
      h.controller.onPose(
        _pose(t: 0.2, pos: Vector3(0.5, 0, 0), withIntrinsics: false),
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(h.fires, 0);
    // Depth is still trusted, so the lower bound keeps working on the tick.
    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.5, 0, 0), withIntrinsics: false),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('a zero camera-image size switches off the overlap bound even though '
      'intrinsics are present', () {
    final h = _Harness();
    // The pose path publishes intrinsics but leaves imageWidth/Height at 0
    // whenever the backend exposes no real camera frame.
    h.controller.start(_pose(t: 0, width: 0, height: 0));
    expect(
      h.controller.onPose(
        _pose(t: 0.2, pos: Vector3(0.5, 0, 0), width: 0, height: 0),
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(h.fires, 0);
    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.5, 0, 0), width: 0, height: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('the horizontal overlap term uses fx, not fy', () {
    final h = _Harness();
    // fy is twice fx, so swapping the two doubles sx.
    h.controller.start(_pose(t: 0, fx: 1000, fy: 2000));
    // sx = 1000 * 0.2 / 1000 = 0.20 (< 0.30). Through fy it would be 0.40.
    final d = h.controller.onPose(
      _pose(t: 0.2, pos: Vector3(0.2, 0, 0), fx: 1000, fy: 2000),
    );
    expect(d, AutoCaptureDecision.skipPaced);
    expect(h.fires, 0);
  });

  test('the vertical overlap term uses fy, not fx', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, fx: 1000, fy: 2000));
    // sy = 2000 * 0.2 / 1000 = 0.40 (>= 0.30). Through fx it would be 0.20.
    final d = h.controller.onPose(
      _pose(t: 0.2, pos: Vector3(0, 0.2, 0), fx: 1000, fy: 2000),
    );
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('the horizontal overlap term divides by imageWidth, not imageHeight',
      () {
    final h = _Harness();
    // A 2:1 camera image: swapping the two dimensions doubles sx.
    h.controller.start(_pose(t: 0, width: 1000, height: 500));
    // sx = 1000 * 0.2 / 1000 = 0.20 (< 0.30). Over the height it is 0.40.
    final d = h.controller.onPose(
      _pose(t: 0.2, pos: Vector3(0.2, 0, 0), width: 1000, height: 500),
    );
    expect(d, AutoCaptureDecision.skipPaced);
    expect(h.fires, 0);
  });

  test('the vertical overlap term divides by imageHeight, not imageWidth', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, width: 1000, height: 500));
    // sy = 1000 * 0.2 / 500 = 0.40 (>= 0.30). Over the width it is 0.20.
    final d = h.controller.onPose(
      _pose(t: 0.2, pos: Vector3(0, 0.2, 0), width: 1000, height: 500),
    );
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('a fast turn fires before the tick, judged from the current '
      'orientation', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 20° of yaw puts the baseline target tan(20°) = 0.36 of a frame width
    // off centre — past the 0.30 bound, and 0.2 s is well inside the 1 s
    // tick. Judged from the BASELINE orientation it would be dead centre.
    final d = h.controller.onPose(_pose(t: 0.2, yawDeg: 20));
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('walking past the target fires at once via the behind-the-camera '
      'bound', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    // 1.5 m straight ahead: the baseline target is now 0.5 m BEHIND the
    // camera, so the overlap bound is +inf — which is a fire, not a null.
    final d = h.controller.onPose(_pose(t: 0.2, pos: Vector3(0, 0, -1.5)));
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  // ──────────────────────────────────────────────────────────────────────
  // 修复轮 1:降级必须可逆(spec §7「⚠️ 死锁」)+ 两个变异幸存者。
  // ──────────────────────────────────────────────────────────────────────

  test('a start() frame with too few feature points does not deadlock the '
      'run — the textureless-surface case', () {
    // 单变量:两臂只有 start() 那一帧的特征点数不同,其后 180 帧逐字相同。
    // 修好之前,饥饿臂 30 秒横移产出 0 张,而且永远不会有 —— 基准帧的
    // depthTrusted=false 同时关掉视差与上限两条路,只剩转角;纯横移转角恒 0
    // ⇒ 永不开火 ⇒ 永不重播种 ⇒ 回到起点。
    int runArm({required int startPoints}) {
      final h = _Harness();
      h.controller.start(_pose(t: 0, pointCount: startPoints));
      for (var i = 1; i <= 180; i++) {
        h.controller.onPose(_pose(t: i / 6.0, pos: Vector3(i * 0.02, 0, 0)));
      }
      return h.fires;
    }

    expect(runArm(startPoints: 12), 30, reason: '30 s of walking at a 1 s tick');
    expect(runArm(startPoints: 0), 30,
        reason: 'the starved arm re-seeds on the first textured frame');
  });

  test('a re-seed does not reset the tick clock', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, pointCount: 0));

    // 0.9 s in, the first textured frame rolls the degradation back.
    expect(h.controller.onPose(_pose(t: 0.9)), AutoCaptureDecision.skipNotMoved);

    // 0.1 s later the tick is due. A re-seed is not a capture and must not
    // have spent the pacing budget, or every rollback costs a full interval.
    expect(
      h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.1, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('an untrusted candidate does not replace an untrusted baseline, so the '
      'turn path keeps measuring from the original frame', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, pointCount: 0));

    // Still textureless at 12° of yaw: no re-seed is possible here. Were the
    // baseline to follow this frame anyway, the turn would reset to 0 every
    // frame and nothing would ever fire — the deadlock in another costume.
    expect(
      h.controller.onPose(_pose(t: 0.5, yawDeg: 12, pointCount: 0)),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.controller.onPose(_pose(t: 1.0, yawDeg: 12, pointCount: 0)),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('start() on a bad-tracking pose seeds nothing, and the first normal '
      'frame becomes the baseline', () {
    final h = _Harness();
    h.controller.start(
      _pose(t: 0, tracking: 'limited_relocalizing', depthM: 2.5),
    );
    expect(h.controller.baselineDepthM, isNull);

    // The first healthy frame seeds — with ITS scene depth, at ITS position.
    expect(
      h.controller.onPose(_pose(t: 0.5, pos: Vector3(1, 0, 0), depthM: 4.0)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.controller.baselineDepthM, closeTo(4.0, 1e-9));

    // Displacement is now measured from x = 1. Measured from the start()
    // frame at the origin this would be 21° of parallax and would fire.
    expect(
      h.controller.onPose(_pose(t: 1.5, pos: Vector3(1, 0, 0), depthM: 4.0)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 0);
  });

  test('start() on bad tracking followed by only bad-tracking frames never '
      'seeds and never fires', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, tracking: 'limited_relocalizing'));
    for (var i = 1; i <= 60; i++) {
      expect(
        h.controller.onPose(
          _pose(
            t: i / 6.0,
            pos: Vector3(i * 0.05, 0, 0),
            tracking: 'limited_relocalizing',
          ),
        ),
        AutoCaptureDecision.skipTracking,
      );
    }
    expect(h.controller.baselineDepthM, isNull);
    expect(h.fires, 0);
  });

  test('a textureless first frame is still seeded, so the turn path works '
      'from the very beginning', () {
    // Seeding an UNTRUSTED baseline is better than seeding none: with no
    // baseline at all there is no reference optical axis either, so the turn
    // path is dead too and the run does nothing until texture shows up.
    final h = _Harness();
    h.controller.start(_pose(t: 0, tracking: 'limited_relocalizing'));
    expect(
      h.controller.onPose(_pose(t: 0.5, pointCount: 0)),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));

    final d = h.controller.onPose(_pose(t: 1.5, yawDeg: 12, pointCount: 0));
    expect(d, AutoCaptureDecision.fire);
    expect(h.fires, 1);
  });

  test('the time limit still ends a run that never managed to seed a baseline',
      () {
    // 张数/时间上限排在 tracking 之前(governor 的既定优先级)。补播种入口
    // 若抢在判定之前 return,这两道闸就永远轮不到 —— 跟丢的一轮会一直
    // isRunning=true 挂着,五分钟上限形同虚设。
    final h = _Harness();
    h.controller.start(_pose(t: 0, tracking: 'limited_relocalizing'));
    expect(h.controller.baselineDepthM, isNull);

    final d = h.controller.onPose(
      _pose(t: 300.0, pos: Vector3(0.5, 0, 0), tracking: 'limited_relocalizing'),
    );
    expect(d, AutoCaptureDecision.skipTimeLimit);
    expect(h.controller.isRunning, isFalse);
  });

  test('the frame cap still ends a run that never managed to seed a baseline',
      () {
    final h = _Harness()..captured = 300;
    h.controller.start(_pose(t: 0, tracking: 'limited_relocalizing'));

    final d = h.controller.onPose(
      _pose(t: 1.0, tracking: 'limited_relocalizing'),
    );
    expect(d, AutoCaptureDecision.skipCapped);
    expect(h.controller.isRunning, isFalse);
  });

  test('a tracking-loss frame does not consume the tick clock', () {
    // ARKit ships limited_* frames in bursts at 6 Hz. If each one spent the
    // pacing budget, every hiccup would push the next capture out by a full
    // interval — up to 3 s on ShutterPace.hard — and a stuttering tracker
    // could starve the whole run while isRunning stays true.
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(
      h.controller.onPose(
        _pose(
          t: 0.5,
          pos: Vector3(0.1, 0, 0),
          tracking: 'limited_excessive_motion',
        ),
      ),
      AutoCaptureDecision.skipTracking,
    );
    // Recovered, 0.2 m sideways = 11° of parallax, and the tick is due at
    // 1.0 s measured from start() — not from the hiccup at 0.5 s.
    expect(
      h.controller.onPose(_pose(t: 1.0, pos: Vector3(0.2, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  test('a one-element intrinsics list is rejected instead of read past its '
      'end', () {
    // Defensive: no producer in lib/ ships a length-1 list today, but the
    // guard is what stops `fy: intr[1]` from throwing RangeError on the
    // 6 Hz pose stream.
    final h = _Harness();
    h.controller.start(_pose(t: 0, intrinsics: const <double>[1000]));
    // The overlap bound is unevaluable — "unknown", not "fire now".
    expect(
      h.controller.onPose(
        _pose(
          t: 0.2,
          pos: Vector3(0.5, 0, 0),
          intrinsics: const <double>[1000],
        ),
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(h.fires, 0);
    // The lower bound is unaffected.
    expect(
      h.controller.onPose(
        _pose(
          t: 1.0,
          pos: Vector3(0.5, 0, 0),
          intrinsics: const <double>[1000],
        ),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
  });

  // ==========================================================================
  // 深度记忆(spec §5.4):pose 逐 ARFrame 20–60 Hz,特征点单独按 8 Hz 节流
  // ⇒ 30 fps 下约 3/4 的 pose 帧带的是**空**点列表(Dart 侧 _decodePreviewPoints
  // 对缺字段返回 const <ARPreviewPoint>[],不沿用上一帧)。基准帧只在 start()
  // 与每次成功入队时重算,两者都有约 3/4 的概率落在空帧上。
  // ==========================================================================

  test('a capture landing on a frame with no feature points keeps the last '
      'measured scene depth instead of the hardcoded fallback', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 2.0));
    expect(h.controller.baselineDepthM, closeTo(2.0, 1e-9));

    // The frame that actually gets shot carries no feature points — the
    // common case at 30 fps, not an edge case.
    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.2, 0, 0), depthM: 2.0, pointCount: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);
    // 2.0 m is a depth somebody measured 1 s ago on this very scene.
    // 1.0 m — the fallback — is a depth nobody ever measured.
    expect(h.controller.baselineDepthM, closeTo(2.0, 1e-9),
        reason: 'the remembered depth, not kAutoCaptureFallbackDepthM');
  });

  test('a capture landing on a frame with no feature points anchors the '
      'baseline at that frame, not at the next frame that has points', () {
    // This is the whole point of remembering the depth. Without the memory
    // the shot frame yields depthTrusted=false, which makes needsSeed true,
    // which hands the baseline to the NEXT textured frame — up to 125 ms and
    // (at 1 m/s) 12.5 cm downrange of the photo that was actually taken.
    // Always in the same direction: bias, not noise.
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 2.0));

    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.20, 0, 0), depthM: 2.0, pointCount: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 1);

    // 100 ms later the 8 Hz feature-point payload arrives. It must NOT move
    // the baseline: this frame is not the one that was photographed.
    // (A deferred baseline would re-seed here and report skipNotMoved.)
    expect(
      h.controller.onPose(
        _pose(t: 1.1, pos: Vector3(0.25, 0, 0), depthM: 2.0),
      ),
      AutoCaptureDecision.skipPaced,
    );

    // 0.18 m past the frame that was shot = 5.14 deg of parallax at 2 m:
    // just over the 5 deg floor. Measured from the deferred baseline at
    // x = 0.25 it would be only 3.72 deg and would not fire.
    expect(
      h.controller.onPose(
        _pose(t: 2.2, pos: Vector3(0.38, 0, 0), depthM: 2.0, pointCount: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.fires, 2);
  });

  test('the depth memory is refreshed by frames that never become a baseline',
      () {
    // _baselineFrom runs at most ~1/s (start, fire, re-seed). If the memory
    // were only written there, "the most recent trusted depth" would really
    // mean "the depth at the last frame that happened to seed" — minutes
    // stale in a run where every capture lands on an empty frame. The 8 Hz
    // points are in hand on every pose; take them there.
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 2.0));

    // Mid-tick, standing still: no fire, no re-seed (the baseline is already
    // trusted), so this frame never reaches _baselineFrom. The scene has
    // moved to 6 m — a doorway opening onto a larger room.
    expect(
      h.controller.onPose(_pose(t: 0.5, depthM: 6.0)),
      AutoCaptureDecision.skipPaced,
    );

    // The capture lands on an empty frame and must use 6.0, not 2.0.
    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.2, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.baselineDepthM, closeTo(6.0, 1e-9));
  });

  test('bad-tracking frames do not refresh the depth memory', () {
    // Symmetric twin of the test above. Depth is computed FROM the camera
    // pose; while tracking is limited the pose is exactly what is not
    // trustworthy, and this number goes straight into the next baseline.
    // Same discipline as spec section 7's "no seeding during tracking loss".
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 2.0));

    expect(
      h.controller.onPose(
        _pose(t: 0.5, depthM: 9.0, tracking: 'limited_relocalizing'),
      ),
      AutoCaptureDecision.skipTracking,
    );

    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.2, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.baselineDepthM, closeTo(2.0, 1e-9),
        reason: 'the 9 m reading arrived on a frame we do not trust');
  });

  test('a run that has never measured a depth still degrades to an untrusted '
      'baseline — the deadlock regression stays meaningful', () {
    // The memory must not paper over the genuine "no depth at all" case:
    // there the fallback really is an unmeasured assertion, and both the
    // parallax gate and the overlap gate must stay off (spec section 7).
    final h = _Harness();
    h.controller.start(_pose(t: 0, pointCount: 0));
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));

    // 0.5 m sideways: 26.6 deg of parallax and s = 0.5 if the fallback depth
    // were real. Neither gate may act on a depth nobody measured.
    expect(
      h.controller.onPose(
        _pose(t: 0.2, pos: Vector3(0.5, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      h.controller.onPose(
        _pose(t: 1.0, pos: Vector3(0.5, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 0);
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));
  });

  test('stop() clears the depth memory, so a new run never inherits the '
      'previous scene', () {
    final h = _Harness();
    // Run A: a 3 m scene.
    h.controller.start(_pose(t: 0, depthM: 3.0));
    h.controller.onPose(_pose(t: 0.5, depthM: 3.0));
    h.controller.stop();

    // Poses keep arriving between runs; a stopped controller must not be
    // learning from them either.
    h.controller.onPose(_pose(t: 5.0, depthM: 7.0));

    // Run B: the user has walked somewhere else and starts on a textureless
    // surface. Nothing measured in run A is admissible here.
    h.controller.start(_pose(t: 10.0, pointCount: 0));
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9),
        reason: 'neither run A\'s 3 m nor the 7 m seen while stopped');

    // And it is untrusted, not just numerically different: 0.5 m sideways
    // would be 9.5 deg of parallax at run A's 3 m depth.
    expect(
      h.controller.onPose(
        _pose(t: 11.0, pos: Vector3(0.5, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 0);
  });

  test('a second start() without a stop() also clears the depth memory', () {
    // Symmetric twin: stop() is not the only way a run ends. Task 4 owns the
    // lifecycle wiring, so the controller must not depend on it being polite.
    final h = _Harness();
    h.controller.start(_pose(t: 0, depthM: 3.0));
    expect(h.controller.baselineDepthM, closeTo(3.0, 1e-9));

    h.controller.start(_pose(t: 10.0, pointCount: 0));
    expect(h.controller.baselineDepthM, closeTo(1.0, 1e-9));
    expect(
      h.controller.onPose(
        _pose(t: 11.0, pos: Vector3(0.5, 0, 0), pointCount: 0),
      ),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(h.fires, 0);
  });

  test('the depth memory never expires inside a run — the run boundary is the '
      'only staleness bound', () {
    // Deliberate design decision, pinned here so nobody adds a timeout
    // without arguing for it. Expiring the memory has exactly one fallback:
    // the unmeasured 1 m constant WITH both gates switched off — i.e. the
    // spec section 7 deadlock. A stale depth mis-scales a threshold; an
    // expired one removes the threshold. Any cutoff would also be a number
    // with no source, and this file already carries one such (turnMinDeg,
    // flagged "must be calibrated on device").
    //
    // Three points, spread across the whole admissible range: comfortably
    // fresh, a minute stale, and just under the 300 s run limit. All three
    // must behave identically.
    for (final gapSec in <double>[1.0, 60.0, 290.0]) {
      final h = _Harness();
      h.controller.start(_pose(t: 0, depthM: 2.0));
      // Nothing but empty frames from here on.
      final d = h.controller.onPose(
        _pose(t: gapSec, pos: Vector3(0.2, 0, 0), pointCount: 0),
      );
      expect(d, AutoCaptureDecision.fire, reason: 'gap = $gapSec s');
      expect(h.fires, 1, reason: 'gap = $gapSec s');
      expect(h.controller.baselineDepthM, closeTo(2.0, 1e-9),
          reason: 'gap = $gapSec s');
    }
  });

  test('feature points on one frame in four leave the capture cadence '
      'unchanged — the 8 Hz points vs the 30 fps pose stream', () {
    // The regression that would have caught the bias. Single variable: the
    // two arms differ ONLY in which frames carry feature points.
    //
    // 2 m scene, 0.16 m/s sideways => the 5 deg parallax floor needs 0.175 m
    // = 1.09 s, just past the 1 s tick, so the PARALLAX gate is what paces
    // this run (a tick-bound arm would sit at 120 and hide everything).
    //
    // Before the fix: control 109, mixed 100 — 8 % of the captures lost to a
    // baseline that kept being handed to the next frame with points.
    int runArm({required bool everyFrameHasPoints}) {
      final h = _Harness();
      const fps = 30.0;
      const v = 0.16;
      h.controller.start(_pose(t: 0, depthM: 2.0));
      for (var i = 1; i <= 3600; i++) {
        final t = i / fps;
        h.controller.onPose(
          _pose(
            t: t,
            pos: Vector3(v * t, 0, 0),
            depthM: 2.0,
            // 8 Hz points on a 30 fps pose stream: roughly one in four.
            pointCount: (everyFrameHasPoints || i % 4 == 0) ? 12 : 0,
          ),
        );
      }
      return h.fires;
    }

    final control = runArm(everyFrameHasPoints: true);
    final mixed = runArm(everyFrameHasPoints: false);

    expect(control, lessThan(120),
        reason: 'the parallax floor, not the 1 s tick, is pacing this arm');
    expect(control, 109);
    expect(mixed, control,
        reason: 'the point rate must not change the capture cadence at all');
  });
}
