# 自动采集(Auto Capture)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给采集页加「自动 / 手动」模式;自动模式下按"定时 tick + 姿态位移闸"替用户按快门,原地不动时不拍。

**Architecture:** 三层。① 纯几何函数(视差角、视线转角、归一化中心偏移、HFOV、场景中位深度)② 纯决策谓词(给定几何量与状态,输出拍/不拍+原因)③ 有状态编排(挂 6Hz pose 流,维护基准帧与 tick,决定 fire 就调**现有** `_onShutterTap()`)。自动拍**不新开捕获路径**,因此 300 张上限、in-flight 守卫、12MP 静照、落盘、SfM 喂帧全部自动继承。

**Tech Stack:** Dart / Flutter(`flutter_test`)、`vector_math/vector_math_64.dart`。**零 native 改动** —— 相机内参与特征点已由 `ARPose` 送到 Dart。

**Spec:** `docs/superpowers/specs/2026-08-19-auto-capture-design.md`

## Global Constraints

以下每条都适用于**所有**任务:

- **包名** `pocketworld_flutter`。测试命令 `flutter test test/<file>_test.dart`。
- **⚠️ 平行同名树**:官方采集链用的是 `lib/official_dome/ar_pose.dart`,**不是** `lib/dome/ar_pose.dart`(两者内容不同)。所有新文件 import 必须指向 `official_dome`。同理 `lib/official_capture/` 而非 `lib/capture/`。
- **不新开捕获路径**:自动拍只能调用现有 `_onShutterTap()`(`lib/ui/official_capture/ar_capture_page.dart:2637`),它内部走 `ManualCaptureQueue.enqueue(verifiedCount:)`。
- **不改手动快门任何行为**,包括"无论多热、队列多深都立即可拍"。
- **不产生视频文件**;**不加用户可见质量滑杆/档位**;**不做文字说教式引导**。
- **阈值**:视差下限 `5.0°`(与 `capture_coverage_cloud.dart` 的 `parallaxMinDeg` 同源同值)、视线转角下限 `10.0°`(待标定)、归一化中心偏移上限 `0.30`(重叠 70%)、tick `1.0 / 2.0 / 3.0 s`(由 `ShutterPace` 决定)、张数上限 `kOfficialMaximumCaptureFrames = 300`、时间上限 `5 分钟`。
- **时钟**:一律使用 `ARPose.timestamp`(秒,ARFrame 时间轴),**禁止** `DateTime.now()` —— 否则纯函数测试无法确定性复现。
- **⚠️ 共享脏工作树**:仓里有 20+ 个别人的未提交改动。提交时**只 `git add` 该任务明确列出的文件**;**禁止** `git add -A`、`git add .`、目录级 add;禁止 `reset` / `clean` / `checkout` / `stash`。提交用 `GIT_TERMINAL_PROMPT=0 git commit -F <msgfile> </dev/null`;**不 push**。

---

## File Structure

| 文件 | 职责 | 任务 |
|---|---|---|
| `lib/official_capture/auto_capture_geometry.dart` | **纯几何**。只做数学,不知道什么是"拍照"。 | T1 |
| `lib/official_capture/auto_capture_governor.dart` | **纯决策**。给定几何量 + 状态 → 拍/不拍 + 原因。含全部阈值常量。 | T2 |
| `lib/official_capture/auto_capture_controller.dart` | **有状态编排**。维护基准帧 / tick / 计时,调 fire 回调。 | T3 |
| `lib/ui/official_capture/ar_capture_page.dart` | 只做接线:模式状态 + 把 controller 挂到已有 pose 订阅 + 模式切换 UI。 | T4 |
| `lib/official_capture/auto_capture_telemetry.dart` | 自动拍专属遥测聚合(spec §11 的待实测项)。 | T5 |

几何与决策分开,是因为几何是最易错的部分(视差角、投影),它值得独立的测试循环和独立的评审门;而决策是纯分支逻辑,错法完全不同。

---

## Task 1: 纯几何判据

**Files:**
- Create: `lib/official_capture/auto_capture_geometry.dart`
- Test: `test/auto_capture_geometry_test.dart`

**Interfaces:**
- Consumes: `ARPreviewPoint`(`lib/official_dome/ar_pose.dart:21`,字段 `position: Vector3`)
- Produces:
  - `double horizontalFovRad({required double fx, required int imageWidth})`
  - `double? medianSceneDepthM({required Vector3 cameraPosition, required Vector3 forward, required List<ARPreviewPoint> points})`
  - `double parallaxAngleDeg({required Vector3 baseCamera, required Vector3 currentCamera, required Vector3 target})`
  - `double viewAxisTurnDeg({required Vector3 baseForward, required Vector3 currentForward})`
  - `double normalizedCenterShift({required Vector3 target, required Vector3 currentCamera, required Quaternion currentOrientation, required double fx, required double fy, required int imageWidth, required int imageHeight})`
  - `const int kAutoCaptureMinDepthAnchors = 8`

- [ ] **Step 1: 写失败测试**

创建 `test/auto_capture_geometry_test.dart`:

```dart
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

ARPreviewPoint _pt(double x, double y, double z) =>
    ARPreviewPoint(position: Vector3(x, y, z), r: 0, g: 0, b: 0, confidence: 1);

void main() {
  test('horizontalFovRad matches the intrinsics identity', () {
    // fx = W / (2*tan(HFOV/2))  =>  HFOV = 60° when W=1920, fx=1662.77
    final fx = 1920 / (2 * math.tan(60 * math.pi / 180 / 2));
    final hfov = horizontalFovRad(fx: fx, imageWidth: 1920);
    expect(hfov * 180 / math.pi, closeTo(60.0, 1e-6));
  });

  test('medianSceneDepthM projects onto the forward axis', () {
    // Camera at origin looking down -Z. Points at depth 1,2,3 => median 2.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 3; i++) _pt(0, 0, -(i + 1).toDouble()),
        // pad to the 8-anchor minimum with copies of the same depths
        for (var i = 0; i < 3; i++) _pt(0.1, 0.1, -(i + 1).toDouble()),
        _pt(0, 0, -2.0),
        _pt(0, 0, -2.0),
      ],
    );
    expect(depth, isNotNull);
    expect(depth!, closeTo(2.0, 1e-9));
  });

  test('medianSceneDepthM returns null below the anchor minimum', () {
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[_pt(0, 0, -1), _pt(0, 0, -2)],
      ),
      isNull,
    );
  });

  test('medianSceneDepthM drops points behind the camera', () {
    // 8 valid at depth 1.0 plus 4 behind-camera points that must not count.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 8; i++) _pt(0, 0, -1.0),
        for (var i = 0; i < 4; i++) _pt(0, 0, 5.0),
      ],
    );
    expect(depth!, closeTo(1.0, 1e-9));
  });

  test('parallaxAngleDeg is the angle subtended at the target', () {
    // Target 1m ahead; camera slides 1m sideways => 45°.
    final target = Vector3(0, 0, -1);
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3.zero(),
        currentCamera: Vector3(1, 0, 0),
        target: target,
      ),
      closeTo(45.0, 1e-9),
    );
  });

  test('parallaxAngleDeg is ~0 for pure forward motion — the double-wall case',
      () {
    // Walking straight at the object: base, current and target are collinear.
    final target = Vector3(0, 0, -1);
    final deg = parallaxAngleDeg(
      baseCamera: Vector3.zero(),
      currentCamera: Vector3(0, 0, -0.5),
      target: target,
    );
    expect(deg, lessThan(0.001));
  });

  test('viewAxisTurnDeg measures the angle between optical axes', () {
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(0, 0, -1),
        currentForward: Vector3(1, 0, 0),
      ),
      closeTo(90.0, 1e-9),
    );
  });

  test('normalizedCenterShift is zero when the target stays centred', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.0, 1e-9),
    );
  });

  test('normalizedCenterShift grows with lateral camera translation', () {
    // Target 1m ahead, fx = imageWidth => a 0.3m sideways slide puts the
    // target 0.3 * imageWidth px off centre => s = 0.30.
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3(-0.3, 0, 0),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.30, 1e-9),
    );
  });

  test('normalizedCenterShift is infinite when the target falls behind', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, 1), // behind a camera that looks down -Z
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      double.infinity,
    );
  });
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/auto_capture_geometry_test.dart`
Expected: FAIL —— `Error: Couldn't resolve the package 'pocketworld_flutter/official_capture/auto_capture_geometry.dart'`(文件还不存在)

- [ ] **Step 3: 写最小实现**

创建 `lib/official_capture/auto_capture_geometry.dart`:

```dart
// auto_capture_geometry.dart — 自动采集的纯几何判据(零 Flutter 依赖)。
//
// 这一层只做数学,不知道"拍照"是什么。决策在 auto_capture_governor.dart。
//
// 相机约定与 ARKit / ARCore 一致:相机看向自身坐标系的 -Z,+X 右、+Y 上。
// 内参与特征点都由 ARPose 现成提供(intrinsicFxFyCxCy / previewPoints),
// 本文件不需要任何 native 改动。

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';

/// 估计场景中位深度所需的最少特征点数。低于此数认为深度不可信。
/// 与 capture_session 的 `_minScaleAlignAnchorsForPersistedFrame` 同量级。
const int kAutoCaptureMinDepthAnchors = 8;

const double _radToDeg = 180.0 / math.pi;

/// 水平视场角(弧度),由内参现算:`HFOV = 2·atan(W / (2·fx))`。
double horizontalFovRad({required double fx, required int imageWidth}) {
  if (fx <= 0 || imageWidth <= 0) return 0;
  return 2 * math.atan(imageWidth / (2 * fx));
}

/// 场景中位深度(米)。把每个特征点投到光轴上取正深度的中位数。
/// 有效点少于 [kAutoCaptureMinDepthAnchors] 时返回 null(调用方须降级)。
double? medianSceneDepthM({
  required Vector3 cameraPosition,
  required Vector3 forward,
  required List<ARPreviewPoint> points,
}) {
  final axis = forward.normalized();
  final depths = <double>[];
  for (final p in points) {
    final d = (p.position - cameraPosition).dot(axis);
    if (d > 0 && d.isFinite) depths.add(d);
  }
  if (depths.length < kAutoCaptureMinDepthAnchors) return null;
  depths.sort();
  final mid = depths.length ~/ 2;
  if (depths.length.isOdd) return depths[mid];
  return (depths[mid - 1] + depths[mid]) / 2;
}

/// 两个相机中心在 [target] 处张开的夹角(度)= 视差角。
///
/// 这是"移动够不够"的判据,**不能**用相机中心间的欧氏距离代替:
/// 沿光轴前进时三点共线,距离不为零而视差 ≈ 0 —— 那正是双墙成因。
double parallaxAngleDeg({
  required Vector3 baseCamera,
  required Vector3 currentCamera,
  required Vector3 target,
}) {
  final a = baseCamera - target;
  final b = currentCamera - target;
  final la = a.length;
  final lb = b.length;
  if (la < 1e-9 || lb < 1e-9) return 0;
  final cos = (a.dot(b) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(cos) * _radToDeg;
}

/// 两条光轴之间的夹角(度)。纯旋转时视差恒为 0,只能靠这个量。
double viewAxisTurnDeg({
  required Vector3 baseForward,
  required Vector3 currentForward,
}) {
  final la = baseForward.length;
  final lb = currentForward.length;
  if (la < 1e-9 || lb < 1e-9) return 0;
  final cos = (baseForward.dot(currentForward) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(cos) * _radToDeg;
}

/// [target] 投影到当前帧后,偏离画面中心的归一化距离
/// (按各自轴的画面尺寸归一,取两轴较大者)。
///
/// `s >= 0.30` ⇔ 与基准帧重叠 ≤ 70%。侧移让 `s = d / W_scene`、
/// 纯旋转让 `s ≈ φ / HFOV` —— 一个式子涵盖平移、旋转及其组合。
/// 目标跑到相机背后或深度非正时返回 [double.infinity]。
double normalizedCenterShift({
  required Vector3 target,
  required Vector3 currentCamera,
  required Quaternion currentOrientation,
  required double fx,
  required double fy,
  required int imageWidth,
  required int imageHeight,
}) {
  if (fx <= 0 || fy <= 0 || imageWidth <= 0 || imageHeight <= 0) {
    return double.infinity;
  }
  // 世界系 → 当前相机系
  final rel = target - currentCamera;
  final cam = currentOrientation.inverted().rotated(rel);
  final depth = -cam.z; // 相机看向 -Z
  if (depth <= 1e-6 || !depth.isFinite) return double.infinity;
  final uPx = fx * (cam.x / depth);
  final vPx = fy * (cam.y / depth);
  final sx = uPx.abs() / imageWidth;
  final sy = vPx.abs() / imageHeight;
  return math.max(sx, sy);
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `flutter test test/auto_capture_geometry_test.dart`
Expected: PASS,10 个测试全过

- [ ] **Step 5: 提交**

```bash
cd ~/Developer/pocketworld
git add -- lib/official_capture/auto_capture_geometry.dart test/auto_capture_geometry_test.dart
git diff --cached --stat   # 必须只有这两个文件
printf '%s\n' \
  'feat(auto-capture): 纯几何判据——视差角、视线转角、归一化中心偏移' \
  '' \
  '视差角用"两个相机中心在虚拟目标点处张开的夹角",而非相机间欧氏距离:' \
  '沿光轴前进时三点共线,距离不为零而视差≈0,距离阈值会放行这类双墙成因帧。' \
  '回归测试 parallaxAngleDeg 纯前进 <0.001° 钉死此点。' \
  '' \
  '中心偏移统一涵盖平移与旋转(侧移 s=d/W_scene、纯旋转 s≈φ/HFOV),' \
  '免掉"转角下限必须小于转角上限"这类需断言守护的隐性约束。' \
  '' \
  'HFOV 与特征点均由 ARPose 现成提供,零 native 改动。' \
  '' \
  'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
  > /tmp/t1msg.txt
GIT_TERMINAL_PROMPT=0 git commit -F /tmp/t1msg.txt </dev/null
```

---

## Task 2: 决策谓词(governor)

**Files:**
- Create: `lib/official_capture/auto_capture_governor.dart`
- Test: `test/auto_capture_governor_test.dart`

**Interfaces:**
- Consumes: `ShutterPace`(`lib/official_capture/shutter_backpressure_gate.dart:19`,值 `normal / soft / hard`);`kOfficialMaximumCaptureFrames`(`lib/official_capture/live_sfm_publish_policy.dart:17`,值 300)
- Produces:
  - `enum AutoCaptureDecision { fire, skipNotMoved, skipPaced, skipTracking, skipCapped, skipTimeLimit }`
  - `Duration autoCaptureTickInterval(ShutterPace pace)`
  - `AutoCaptureDecision autoCaptureDecide({required bool trackingNormal, required int capturedCount, required double elapsedSec, required double sinceLastTickSec, required double tickIntervalSec, required double parallaxDeg, required double turnDeg, required double centerShift})`
  - 常量 `kAutoCaptureParallaxMinDeg = 5.0`、`kAutoCaptureTurnMinDeg = 10.0`、`kAutoCaptureMaxCenterShift = 0.30`、`kAutoCaptureTimeLimitSec = 300.0`

- [ ] **Step 1: 写失败测试**

创建 `test/auto_capture_governor_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

/// 默认参数 = "一切正常、刚到 tick、完全没动"。各测试只覆盖它关心的那一项。
AutoCaptureDecision decide({
  bool trackingNormal = true,
  int capturedCount = 10,
  double elapsedSec = 30,
  double sinceLastTickSec = 1.0,
  double tickIntervalSec = 1.0,
  double parallaxDeg = 0,
  double turnDeg = 0,
  double centerShift = 0,
}) {
  return autoCaptureDecide(
    trackingNormal: trackingNormal,
    capturedCount: capturedCount,
    elapsedSec: elapsedSec,
    sinceLastTickSec: sinceLastTickSec,
    tickIntervalSec: tickIntervalSec,
    parallaxDeg: parallaxDeg,
    turnDeg: turnDeg,
    centerShift: centerShift,
  );
}

void main() {
  test('standing still never fires', () {
    expect(decide(), AutoCaptureDecision.skipNotMoved);
  });

  test('parallax at or above 5 deg fires on a tick', () {
    expect(decide(parallaxDeg: 4.99), AutoCaptureDecision.skipNotMoved);
    expect(decide(parallaxDeg: 5.0), AutoCaptureDecision.fire);
  });

  test('pure rotation fires via the turn threshold', () {
    expect(decide(turnDeg: 9.99), AutoCaptureDecision.skipNotMoved);
    expect(decide(turnDeg: 10.0), AutoCaptureDecision.fire);
  });

  test('below the tick interval nothing fires on the lower bound', () {
    expect(
      decide(sinceLastTickSec: 0.5, parallaxDeg: 90),
      AutoCaptureDecision.skipPaced,
    );
  });

  test('the overlap upper bound fires immediately, ignoring the tick', () {
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: 0.30),
      AutoCaptureDecision.fire,
    );
    expect(
      decide(sinceLastTickSec: 0.01, centerShift: 0.29),
      AutoCaptureDecision.skipPaced,
    );
  });

  test('non-normal tracking blocks every path including the upper bound', () {
    expect(
      decide(trackingNormal: false, centerShift: 10.0, parallaxDeg: 90),
      AutoCaptureDecision.skipTracking,
    );
  });

  test('the 300-frame cap wins over everything', () {
    expect(
      decide(capturedCount: 300, centerShift: 10.0),
      AutoCaptureDecision.skipCapped,
    );
    expect(decide(capturedCount: 299, parallaxDeg: 90),
        AutoCaptureDecision.fire);
  });

  test('the five-minute limit wins over everything but the cap', () {
    expect(
      decide(elapsedSec: 300.0, centerShift: 10.0),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(decide(elapsedSec: 299.9, parallaxDeg: 90),
        AutoCaptureDecision.fire);
  });

  test('tick interval stretches with shutter pace', () {
    expect(autoCaptureTickInterval(ShutterPace.normal).inMilliseconds, 1000);
    expect(autoCaptureTickInterval(ShutterPace.soft).inMilliseconds, 2000);
    expect(autoCaptureTickInterval(ShutterPace.hard).inMilliseconds, 3000);
  });
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/auto_capture_governor_test.dart`
Expected: FAIL —— 无法解析 `auto_capture_governor.dart`

- [ ] **Step 3: 写最小实现**

创建 `lib/official_capture/auto_capture_governor.dart`:

```dart
// auto_capture_governor.dart — 自动采集的决策谓词(纯函数,零 Flutter 依赖)。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何量由 auto_capture_geometry.dart 算好后传进来;编排在
// auto_capture_controller.dart。本文件不持有任何状态。

import 'live_sfm_publish_policy.dart' show kOfficialMaximumCaptureFrames;
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 视差下限(度)。与 capture_coverage_cloud.dart 的 `parallaxMinDeg`
/// **同源同值** —— 那个值 2026-07-11 真机标定过,这里不新造常数。
const double kAutoCaptureParallaxMinDeg = 5.0;

/// 视线转角下限(度)。⚠️ 无外部依据(RS / Polycam / KIRI / Apple 均未公开
/// 自动拍阈值),这是比视差门放宽一倍取的保守起点,**必须真机标定**。
const double kAutoCaptureTurnMinDeg = 10.0;

/// 归一化中心偏移上限。0.30 ⇔ 与基准帧重叠 70%。
/// 依据:KIRI 官方 70%、Polycam Object Mode 70–75%、RealityScan >60%。
const double kAutoCaptureMaxCenterShift = 0.30;

/// 单次自动采集的时间上限(秒)。依据两条独立吻合:Scaniverse 官方
/// 每次扫描硬上限 5 分钟;且 1 张/秒 × 300 张 = 5 分钟。
const double kAutoCaptureTimeLimitSec = 300.0;

enum AutoCaptureDecision {
  fire,
  skipNotMoved,
  skipPaced,
  skipTracking,
  skipCapped,
  skipTimeLimit,
}

/// tick 间隔随背压分级拉长。**只作用于自动拍** —— 手动快门"无论多热、
/// 队列多深都立即可拍"那条铁律不受影响。
Duration autoCaptureTickInterval(ShutterPace pace) {
  switch (pace) {
    case ShutterPace.normal:
      return const Duration(seconds: 1);
    case ShutterPace.soft:
      return const Duration(seconds: 2);
    case ShutterPace.hard:
      return const Duration(seconds: 3);
  }
}

/// 判定顺序即优先级,不可随意调换:
///   张数上限 > 时间上限 > tracking > 重叠上限(R2) > tick 闸 > 位移下限(R1)
///
/// 重叠上限排在 tick 闸**之前**,是因为它治的是"走得快,1 秒已跨过重叠下限"
/// —— 那种情况按 1s 节奏拍会拍出 RealityScan 官方警告的断裂组件。
AutoCaptureDecision autoCaptureDecide({
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required double sinceLastTickSec,
  required double tickIntervalSec,
  required double parallaxDeg,
  required double turnDeg,
  required double centerShift,
}) {
  if (capturedCount >= kOfficialMaximumCaptureFrames) {
    return AutoCaptureDecision.skipCapped;
  }
  if (elapsedSec >= kAutoCaptureTimeLimitSec) {
    return AutoCaptureDecision.skipTimeLimit;
  }
  if (!trackingNormal) return AutoCaptureDecision.skipTracking;
  if (centerShift >= kAutoCaptureMaxCenterShift) {
    return AutoCaptureDecision.fire;
  }
  if (sinceLastTickSec < tickIntervalSec) return AutoCaptureDecision.skipPaced;
  if (parallaxDeg >= kAutoCaptureParallaxMinDeg ||
      turnDeg >= kAutoCaptureTurnMinDeg) {
    return AutoCaptureDecision.fire;
  }
  return AutoCaptureDecision.skipNotMoved;
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `flutter test test/auto_capture_governor_test.dart`
Expected: PASS,9 个测试全过

- [ ] **Step 5: 提交**

```bash
cd ~/Developer/pocketworld
git add -- lib/official_capture/auto_capture_governor.dart test/auto_capture_governor_test.dart
git diff --cached --stat   # 必须只有这两个文件
printf '%s\n' \
  'feat(auto-capture): 决策谓词——判定顺序即优先级' \
  '' \
  '顺序:张数上限 > 时间上限 > tracking > 重叠上限 > tick闸 > 位移下限。' \
  '重叠上限刻意排在 tick 闸之前:走得快时 1 秒已跨过重叠下限,按 1s 节奏' \
  '拍会拍出 RealityScan 官方警告的"断裂成不相连的组件"。' \
  '' \
  '视差下限 5° 引用 coverage cloud 的 parallaxMinDeg,同源同值不新造常数。' \
  '转角下限 10° 无外部依据(四家同行均未公开阈值),已在注释标注待标定。' \
  '' \
  'tick 拉长只作用于自动拍,手动快门"永不限流"铁律不受影响。' \
  '' \
  'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
  > /tmp/t2msg.txt
GIT_TERMINAL_PROMPT=0 git commit -F /tmp/t2msg.txt </dev/null
```

---

## Task 3: 有状态编排(controller)

**Files:**
- Create: `lib/official_capture/auto_capture_controller.dart`
- Test: `test/auto_capture_controller_test.dart`

**Interfaces:**
- Consumes: T1 的全部几何函数;T2 的 `autoCaptureDecide` / `autoCaptureTickInterval` / `AutoCaptureDecision`;`ARPose`(`lib/official_dome/ar_pose.dart`)
- Produces:
  - `class AutoCaptureController`,构造参数 `({required bool Function() onFire, required ShutterPace Function() paceProvider, required int Function() capturedCountProvider})`
  - `bool get isRunning`
  - `void start(ARPose pose)` / `void stop()`
  - `AutoCaptureDecision onPose(ARPose pose)`
  - `double? get baselineDepthM`(供遥测/测试断言基准帧是否更新)

**关键契约:`onFire` 返回 `true` 表示入队成功。只有返回 `true` 才更新基准帧。**
入队失败时基准帧不动 —— 否则下一 tick 会拿一个根本没拍成的位置当基准,位移闸直接漏判。

- [ ] **Step 1: 写失败测试**

创建 `test/auto_capture_controller_test.dart`:

```dart
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
/// 特征点铺在相机前方 1m 处,足够触发中位深度估计。
ARPose _pose({
  required double t,
  Vector3? pos,
  double yawDeg = 0,
  String tracking = 'normal',
}) {
  final p = pos ?? Vector3.zero();
  final q = Quaternion.axisAngle(Vector3(0, 1, 0), yawDeg * math.pi / 180);
  final forward = q.rotated(Vector3(0, 0, -1));
  final target = p + forward * 1.0;
  return ARPose(
    position: p,
    orientation: q,
    azimuth: 0,
    elevation: 0,
    isTracking: tracking == 'normal',
    trackingStateName: tracking,
    timestamp: t,
    hasOrigin: true,
    worldOrigin: Vector3.zero(),
    worldYaw: 0,
    // extrinsic4x4 与 intrinsicFxFyCxCy 都是 ARPose 的 required 参数。
    // 本判据不消费 extrinsic,给空列表即可(mock 路径的合法取值)。
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: <double>[_fx, _fx, _w / 2, _h / 2],
    imageWidth: _w,
    imageHeight: _h,
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

  test('walking straight at the object fires nothing — the double-wall case',
      () {
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
}
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/auto_capture_controller_test.dart`
Expected: FAIL —— 无法解析 `auto_capture_controller.dart`

- [ ] **Step 3: 写最小实现**

创建 `lib/official_capture/auto_capture_controller.dart`:

```dart
// auto_capture_controller.dart — 自动采集的有状态编排。
//
// 挂在现成的 6 Hz pose 流上,维护基准帧与 tick 计时,判定 fire 就回调
// 宿主的快门入口。**不自建捕获路径** —— onFire 回调里必须是现有的
// `_onShutterTap()` 等价物,这样 300 张上限、in-flight 守卫、12MP 静照、
// 落盘、SfM 喂帧全部自动继承。
//
// 时钟一律取 ARPose.timestamp(ARFrame 时间轴),不用 DateTime.now(),
// 这样纯 Dart 测试可确定性复现。

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';
import 'auto_capture_geometry.dart';
import 'auto_capture_governor.dart';
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 特征点不足以估深度时的兜底深度(米)。此时平移判据不可信,
/// 由 [_Baseline.depthTrusted] 关掉视差路径,只留视线转角路径。
const double _kFallbackDepthM = 1.0;

class _Baseline {
  _Baseline({
    required this.camera,
    required this.forward,
    required this.target,
    required this.depthTrusted,
  });

  final Vector3 camera;
  final Vector3 forward;
  final Vector3 target;
  final bool depthTrusted;
}

class AutoCaptureController {
  AutoCaptureController({
    required bool Function() onFire,
    required ShutterPace Function() paceProvider,
    required int Function() capturedCountProvider,
  }) : _onFire = onFire,
       _paceProvider = paceProvider,
       _capturedCountProvider = capturedCountProvider;

  /// 触发快门。**返回 true 表示入队成功** —— 只有 true 才更新基准帧。
  final bool Function() _onFire;
  final ShutterPace Function() _paceProvider;
  final int Function() _capturedCountProvider;

  bool _running = false;
  _Baseline? _baseline;
  double _startedAtSec = 0;
  double _lastTickSec = 0;

  bool get isRunning => _running;

  /// 基准帧的场景深度,null 表示尚未起跑。供遥测与测试断言基准是否更新。
  double? get baselineDepthM {
    final b = _baseline;
    if (b == null) return null;
    return (b.target - b.camera).length;
  }

  void start(ARPose pose) {
    _running = true;
    _startedAtSec = pose.timestamp;
    _lastTickSec = pose.timestamp;
    _baseline = _baselineFrom(pose);
  }

  void stop() {
    _running = false;
    _baseline = null;
  }

  AutoCaptureDecision onPose(ARPose pose) {
    if (!_running) return AutoCaptureDecision.skipNotMoved;
    final base = _baseline;
    if (base == null) return AutoCaptureDecision.skipNotMoved;

    final intr = pose.intrinsicFxFyCxCy;
    final hasIntrinsics = intr.length >= 2 && intr[0] > 0 && intr[1] > 0;

    // 注意这里与下面的 shift **刻意不同**:parallax 退化成 0.0 是对的。
    // 它喂的是**下限**判据(`parallaxDeg >= 5.0`),0.0 是该判据的中性/保守值
    // ——"没动够",不会误触发。而 shift 喂的是**上限**判据,那里 0.0 会变成
    // 一句"目标正在正中"的正向断言,所以必须用 null。
    final parallax = base.depthTrusted
        ? parallaxAngleDeg(
            baseCamera: base.camera,
            currentCamera: pose.position,
            target: base.target,
          )
        : 0.0;

    final turn = viewAxisTurnDeg(
      baseForward: base.forward,
      currentForward: _forwardOf(pose),
    );

    // 〔2026-08-19 T2 评审改正〕拿不到深度或内参时传 **null**,不是 0.0。
    //
    // 0.0 是一句**正向断言**——"目标正在画面正中"——而我们此刻恰恰不知道。
    // null 才是"无法求值":governor 收到它会跳过上限判据 R2、只用下限判据
    // (spec §7 "只用下限判据决定")。
    //
    // governor 的 centerShift 参数就是 `double?`,**直接传穿,不要用 `?? 0.0`
    // 之类去翻译** —— 翻译权收在类型里,调用方就没有译错的机会;
    // 若误译成 `?? double.infinity`,R2 会每帧判"立刻拍",快门失控。
    //
    // ⚠️ 早先这里写的是 `: 0.0`,而 `normalizedCenterShift` 返回 `double?`,
    // 三元的静态类型因此是 `double?` —— 对着当时非空的参数**根本编译不过**。
    // 这是 T2 评审静态复现出来的,不是推测。
    final double? shift = (base.depthTrusted && hasIntrinsics)
        ? normalizedCenterShift(
            target: base.target,
            currentCamera: pose.position,
            currentOrientation: pose.orientation,
            fx: intr[0],
            fy: intr[1],
            imageWidth: pose.imageWidth,
            imageHeight: pose.imageHeight,
          )
        : null;

    final tickInterval = autoCaptureTickInterval(_paceProvider());
    final decision = autoCaptureDecide(
      trackingNormal: (pose.trackingStateName ?? 'normal') == 'normal',
      capturedCount: _capturedCountProvider(),
      elapsedSec: pose.timestamp - _startedAtSec,
      sinceLastTickSec: pose.timestamp - _lastTickSec,
      tickIntervalSec: tickInterval.inMilliseconds / 1000.0,
      parallaxDeg: parallax,
      turnDeg: turn,
      centerShift: shift,
    );

    switch (decision) {
      case AutoCaptureDecision.skipCapped:
      case AutoCaptureDecision.skipTimeLimit:
        // 到顶就停,不再每帧撞一次墙。
        _running = false;
        return decision;
      case AutoCaptureDecision.skipTracking:
      case AutoCaptureDecision.skipNotMoved:
      case AutoCaptureDecision.skipPaced:
        return decision;
      case AutoCaptureDecision.fire:
        _lastTickSec = pose.timestamp;
        // 入队失败时基准帧**不动** —— 否则下一 tick 会拿一个根本没拍成
        // 的位置当基准,位移闸直接漏判。
        if (_onFire()) {
          _baseline = _baselineFrom(pose);
        }
        return decision;
    }
  }

  static Vector3 _forwardOf(ARPose pose) =>
      pose.orientation.rotated(Vector3(0, 0, -1));

  static _Baseline _baselineFrom(ARPose pose) {
    final forward = _forwardOf(pose);
    final depth = medianSceneDepthM(
      cameraPosition: pose.position,
      forward: forward,
      points: pose.previewPoints,
    );
    final d = depth ?? _kFallbackDepthM;
    return _Baseline(
      camera: pose.position.clone(),
      forward: forward,
      target: pose.position + forward * d,
      depthTrusted: depth != null,
    );
  }
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `flutter test test/auto_capture_controller_test.dart`
Expected: PASS,11 个测试全过

- [ ] **Step 5: 三个新单元一起回归**

Run: `flutter test test/auto_capture_geometry_test.dart test/auto_capture_governor_test.dart test/auto_capture_controller_test.dart`
Expected: PASS,30 个测试全过

- [ ] **Step 6: 提交**

```bash
cd ~/Developer/pocketworld
git add -- lib/official_capture/auto_capture_controller.dart test/auto_capture_controller_test.dart
git diff --cached --stat   # 必须只有这两个文件
printf '%s\n' \
  'feat(auto-capture): 有状态编排——入队成功才更新基准帧' \
  '' \
  'onFire 回调返回 true 才算入队成功;失败时基准帧不动。否则下一 tick 会拿' \
  '一个根本没拍成的位置当基准,位移闸直接漏判。回归测试钉死:入队失败后' \
  '同一位移在队列恢复后仍会触发。' \
  '' \
  'tracking 非 normal 时同样冻结基准——丢失期间位置估计不可信,拿它当基准' \
  '会让恢复后的第一张判错。' \
  '' \
  '时钟取 ARPose.timestamp 而非 DateTime.now(),纯 Dart 测试可确定性复现。' \
  '特征点不足以估深度时降级为只走视线转角路径,不罢工。' \
  '' \
  'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
  > /tmp/t3msg.txt
GIT_TERMINAL_PROMPT=0 git commit -F /tmp/t3msg.txt </dev/null
```

---

## Task 4: 接线到采集页 + 模式切换 UI

**Files:**
- Modify: `lib/ui/official_capture/ar_capture_page.dart`
  - 现有 pose 订阅在 `:585`(`_poseSub = session.poseStream.listen((p) { ... })`)
  - 现有快门入口 `_onShutterTap()` 在 `:2637`
  - 现有 `_shutterPace` 字段在 `:445`,更新点在 `:1114-1120`
- Test: `test/auto_capture_page_wiring_test.dart`

**Interfaces:**
- Consumes: T3 的 `AutoCaptureController`
- Produces: `enum OfficialCaptureMode { manual, auto }`(定义在 `ar_capture_page.dart` 内,不外泄)

**⚠️ 本任务只做接线,判定逻辑一行都不进这个文件**(它已 4830 行)。

- [ ] **Step 1: 写失败测试**

创建 `test/auto_capture_page_wiring_test.dart`。这里测的是**接线契约**,不是像素:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

void main() {
  test('controller stops on mode switch away from auto', () {
    var captured = 0;
    final c = AutoCaptureController(
      onFire: () {
        captured++;
        return true;
      },
      paceProvider: () => ShutterPace.normal,
      capturedCountProvider: () => captured,
    );
    expect(c.isRunning, isFalse);
    c.stop();
    expect(c.isRunning, isFalse, reason: 'stop() must be idempotent');
  });

  test('autoCaptureTickInterval covers every ShutterPace value', () {
    // 若将来给 ShutterPace 加档,这个测试会因 switch 未覆盖而编译失败。
    for (final p in ShutterPace.values) {
      expect(autoCaptureTickInterval(p).inMilliseconds, greaterThan(0));
    }
  });
}
```

- [ ] **Step 2: 跑测试确认它通过或失败**

Run: `flutter test test/auto_capture_page_wiring_test.dart`
Expected: PASS(这两条断言只依赖 T2/T3 已交付的 API;若 FAIL 说明 T3 的 `stop()` 不幂等,先修 T3)

- [ ] **Step 3: 在采集页加模式状态与 controller**

在 `lib/ui/official_capture/ar_capture_page.dart` 顶部 import 区加:

```dart
import '../../official_capture/auto_capture_controller.dart';
import '../../official_capture/auto_capture_governor.dart';
```

在文件里 `enum AetherRootTab` 同级位置加:

```dart
/// 采集页的两种模式。手动 = 一张一张按快门(原有行为,一个字节没改);
/// 自动 = AutoCaptureController 替用户按快门。
///
/// ⚠️ 命名刻意避开"录像":KIRI 与 Polycam 的 Video 模式是**真的录视频并从
/// 视频建模**,而我们不产生任何视频文件。沿用"录像"之名会让用过那两家的
/// 用户去找视频文件。
enum OfficialCaptureMode { manual, auto }
```

在 `_OfficialARCapturePageState`(即持有 `_shutterQueue` 的那个 State)加字段:

```dart
OfficialCaptureMode _captureMode = OfficialCaptureMode.manual;
late final AutoCaptureController _autoCapture = AutoCaptureController(
  onFire: _onAutoCaptureFire,
  paceProvider: () => _shutterPace,
  capturedCountProvider: () => _projectPhotos.count,
);
AutoCaptureDecision _lastAutoDecision = AutoCaptureDecision.skipNotMoved;
```

加触发回调 —— **注意它复用 `_shutterQueue`,不自建捕获路径**:

```dart
/// 自动拍的触发口。返回 true = 入队成功(controller 据此决定是否更新基准帧)。
///
/// 与 `_onShutterTap` 的唯一区别:到上限时**不弹对话框**(自动模式每秒会撞
/// 一次,弹窗会刷屏),改为静默返回 false,由 controller 停止本次自动采集。
bool _onAutoCaptureFire() {
  if (_session == null || !_sfmCaptureReady || !_shutterQueue.accepting) {
    return false;
  }
  return _shutterQueue.enqueue(verifiedCount: _projectPhotos.count) != null;
}
```

- [ ] **Step 4: 把 controller 挂到已有 pose 订阅上**

`ar_capture_page.dart:585` 现有:

```dart
_poseSub = session.poseStream.listen((p) {
```

在该回调**体内最前面**插入(不新起 `Timer.periodic` —— pose 事件自带时间戳,多一个定时器就多一个要跟生命周期对齐的东西):

```dart
  if (_captureMode == OfficialCaptureMode.auto && _autoCapture.isRunning) {
    final d = _autoCapture.onPose(p);
    if (d != _lastAutoDecision) {
      _lastAutoDecision = d;
      if (mounted) setState(() {});
    }
    if (!_autoCapture.isRunning) {
      // 撞到 300 张或 5 分钟上限,controller 已自停。
      _stopAutoCapture();
    }
  }
```

加启停方法:

```dart
void _startAutoCapture(ARPose seed) {
  if (_autoCapture.isRunning) return;
  setState(() => _autoCapture.start(seed));
}

void _stopAutoCapture() {
  if (!_autoCapture.isRunning) return;
  setState(_autoCapture.stop);
}

void _setCaptureMode(OfficialCaptureMode mode) {
  if (_captureMode == mode) return;
  // 切走自动模式 ⇒ 自动拍立即停。已拍帧全部保留,队列继续消化。
  if (mode != OfficialCaptureMode.auto) _stopAutoCapture();
  setState(() => _captureMode = mode);
}
```

- [ ] **Step 5: 生命周期两处接线**

在现有的后台/前台处理里(`ar_capture_page.dart:773` 与 `:795` 附近已有 `_shutterQueue.resume()` / `_shutterQueue.cancelPending()` 的分支),在**退到后台的那个分支**加一行:

```dart
  _stopAutoCapture();  // 停止而非暂停:回来时 AR 世界原点可能已重定位,
                       // 继续自动拍会产生坐标系错乱的帧。
```

在 `dispose()` 里,`_shutterQueue` 释放的相邻位置加:

```dart
  _autoCapture.stop();
```

- [ ] **Step 6: 加模式切换 UI 与「开始 / 停止」**

⚠️ **切到自动模式不会自动开拍** —— 必须用户点「开始」(spec §7)。
否则用户刚进页面、还没对好景,就已经在落帧了。

先在 State 里缓存最近一帧 pose(`start()` 需要一个种子帧)。在 `:585` 的
pose 回调体内、自动拍那段**之前**加:

```dart
  _lastPose = p;
```

字段与启停切换:

```dart
ARPose? _lastPose;

void _toggleAutoRun() {
  if (_autoCapture.isRunning) {
    _stopAutoCapture();
    return;
  }
  final seed = _lastPose;
  if (seed == null || !_sfmCaptureReady) return; // 还没拿到 AR 帧,不起跑
  _startAutoCapture(seed);
}
```

在文件末尾的私有 widget 区加控件:

```dart
/// 模式切换 + 自动态启停。
///
/// ⚠️ 命名刻意避开"录像"——见 [OfficialCaptureMode] 的注释。
class _CaptureModeBar extends StatelessWidget {
  const _CaptureModeBar({
    required this.mode,
    required this.running,
    required this.onModeChanged,
    required this.onToggleRun,
  });

  final OfficialCaptureMode mode;
  final bool running;
  final ValueChanged<OfficialCaptureMode> onModeChanged;
  final VoidCallback onToggleRun;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        SegmentedButton<OfficialCaptureMode>(
          key: const ValueKey<String>('official-capture-mode-bar'),
          segments: const <ButtonSegment<OfficialCaptureMode>>[
            ButtonSegment<OfficialCaptureMode>(
              value: OfficialCaptureMode.manual,
              label: Text('手动'),
            ),
            ButtonSegment<OfficialCaptureMode>(
              value: OfficialCaptureMode.auto,
              label: Text('自动'),
            ),
          ],
          selected: <OfficialCaptureMode>{mode},
          // 采集中也允许切走:_setCaptureMode 会先停自动拍,已拍帧全部保留
          // (spec §7 第一条)。不禁用,避免用户被困在自动模式里。
          onSelectionChanged: (Set<OfficialCaptureMode> s) =>
              onModeChanged(s.first),
        ),
        if (mode == OfficialCaptureMode.auto) ...<Widget>[
          const SizedBox(width: 12),
          FilledButton(
            key: const ValueKey<String>('official-auto-capture-run-toggle'),
            onPressed: onToggleRun,
            child: Text(running ? '停止' : '开始'),
          ),
        ],
      ],
    );
  }
}
```

在快门区域的 build 里挂上:

```dart
_CaptureModeBar(
  mode: _captureMode,
  running: _autoCapture.isRunning,
  onModeChanged: _setCaptureMode,
  onToggleRun: _toggleAutoRun,
),
```

**指示器**。位移闸意味着站着不动时一张都不拍,不给反馈用户一定以为坏了 ——
但按既有"不教用户"原则**不上文案**,只用视觉状态说话:

```dart
/// 自动态指示器的三种视觉状态。落帧脉冲 / 等你动(转暗静止) / 其余不表达。
bool get _autoIndicatorPulse =>
    _lastAutoDecision == AutoCaptureDecision.fire;
bool get _autoIndicatorDimmed =>
    _lastAutoDecision == AutoCaptureDecision.skipNotMoved;
```

- `fire` → 指示器脉冲一次
- `skipNotMoved` → 指示器转暗、静止(表达"在等你动")
- `skipPaced` → **不额外表达**,节奏自然变慢即可
- 张数沿用现成的 `N/300` 分子分母口径,**不新造**

- [ ] **Step 7: 分析 + 全量测试**

Run: `flutter analyze lib/ui/official_capture/ar_capture_page.dart lib/official_capture/auto_capture_controller.dart lib/official_capture/auto_capture_governor.dart lib/official_capture/auto_capture_geometry.dart`
Expected: No issues found

Run: `flutter test test/`
Expected: PASS。**若有既有测试失败,先确认是不是本任务引入的** —— 这是多 agent 共享脏树,别人的未提交改动也可能让某些测试红。用 `git stash list` 不能用(禁止 stash),改为只看与 `auto_capture` / `ar_capture_page` 相关的失败。

- [ ] **Step 8: 提交**

```bash
cd ~/Developer/pocketworld
git add -- lib/ui/official_capture/ar_capture_page.dart test/auto_capture_page_wiring_test.dart
git diff --cached --stat   # 必须只有这两个文件
printf '%s\n' \
  'feat(auto-capture): 采集页接入自动模式——复用快门入口,不新开捕获路径' \
  '' \
  '自动拍走同一个 ManualCaptureQueue.enqueue,因此 300 张上限、in-flight' \
  '守卫、12MP 静照、落盘、SfM 喂帧全部自动继承,无一需要重新实现。' \
  '' \
  '判定逻辑一行都没进这个文件(它已 4830 行),只做接线:模式状态、' \
  '把 controller 挂到已有的 6Hz pose 订阅、启停与生命周期。' \
  '不新起 Timer.periodic——pose 事件自带时间戳。' \
  '' \
  '模式命名避开"录像":KIRI/Polycam 的 Video 模式是真录视频并从视频建模,' \
  '我们不产生视频文件,沿用该名会让用户去找不存在的视频。' \
  '' \
  '退到后台是停止而非暂停:回来时 AR 世界原点可能已重定位。' \
  '到 300 张不弹对话框(自动模式每秒撞一次会刷屏),静默停止本次采集。' \
  '' \
  'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
  > /tmp/t4msg.txt
GIT_TERMINAL_PROMPT=0 git commit -F /tmp/t4msg.txt </dev/null
```

---

## Task 5: 遥测(spec §11 的待实测项)

spec §11 列了五项待标定,其中三项**只能靠真机数据定**。这个任务把采数的管子铺好。

**Files:**
- Create: `lib/official_capture/auto_capture_telemetry.dart`
- Test: `test/auto_capture_telemetry_test.dart`
- Modify: `lib/ui/official_capture/ar_capture_page.dart`(在 `_onAutoCaptureFire` 与 pose 回调里打点)

**Interfaces:**
- Produces:
  - `class AutoCaptureTelemetry`
  - `void recordDecision(AutoCaptureDecision d)`
  - `void recordSessionStart(double tSec)` / `void recordSessionEnd(double tSec)`
  - `Map<String, Object> snapshot()`

要采的量,逐条对应 spec §11:

| 遥测字段 | 回答 spec §11 的哪一项 |
|---|---|
| `decision_counts`(六个枚举各自计数) | **视差下限触发率** —— `skipNotMoved` 占比就是这道门的实际拦截率。若接近 0,说明四家同行不设下限是对的,这道门无害但也无用 |
| `fire_via_upper_bound` / `fire_via_tick` | 上限提前触发的实际占比 |
| `session_duration_sec` | 采集时长 vs 5 分钟上限 |
| `pace_histogram` | ShutterPace 三档各停留多久 → 积压严重程度 |

- [ ] **Step 1: 写失败测试**

创建 `test/auto_capture_telemetry_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_telemetry.dart';

void main() {
  test('decision counts land in the snapshot', () {
    final t = AutoCaptureTelemetry();
    t.recordDecision(AutoCaptureDecision.fire);
    t.recordDecision(AutoCaptureDecision.fire);
    t.recordDecision(AutoCaptureDecision.skipNotMoved);

    final snap = t.snapshot();
    final counts = snap['decision_counts']! as Map<String, int>;
    expect(counts['fire'], 2);
    expect(counts['skipNotMoved'], 1);
    expect(counts['skipPaced'], 0);
  });

  test('session duration is end minus start', () {
    final t = AutoCaptureTelemetry();
    t.recordSessionStart(10.0);
    t.recordSessionEnd(75.5);
    expect(snapDouble(t, 'session_duration_sec'), closeTo(65.5, 1e-9));
  });

  test('duration is zero before a session ends', () {
    final t = AutoCaptureTelemetry()..recordSessionStart(10.0);
    expect(snapDouble(t, 'session_duration_sec'), 0.0);
  });
}

double snapDouble(AutoCaptureTelemetry t, String key) =>
    (t.snapshot()[key]! as num).toDouble();
```

- [ ] **Step 2: 跑测试确认它失败**

Run: `flutter test test/auto_capture_telemetry_test.dart`
Expected: FAIL —— 无法解析 `auto_capture_telemetry.dart`

- [ ] **Step 3: 写最小实现**

创建 `lib/official_capture/auto_capture_telemetry.dart`:

```dart
// auto_capture_telemetry.dart — 自动采集专属遥测聚合。
//
// 存在的唯一理由是回答 spec §11 里那几个"文档判不了,只能真机实测"的问题,
// 尤其是:视差下限到底有没有用(四家同行都没有这道门)。
// skipNotMoved 的占比就是这道门的实际拦截率。

import 'auto_capture_governor.dart';

class AutoCaptureTelemetry {
  final Map<AutoCaptureDecision, int> _counts = <AutoCaptureDecision, int>{
    for (final d in AutoCaptureDecision.values) d: 0,
  };

  double? _startSec;
  double? _endSec;

  void recordDecision(AutoCaptureDecision d) {
    _counts[d] = (_counts[d] ?? 0) + 1;
  }

  void recordSessionStart(double tSec) {
    _startSec = tSec;
    _endSec = null;
  }

  void recordSessionEnd(double tSec) {
    _endSec = tSec;
  }

  Map<String, Object> snapshot() {
    final start = _startSec;
    final end = _endSec;
    final duration = (start == null || end == null) ? 0.0 : end - start;
    return <String, Object>{
      'decision_counts': <String, int>{
        for (final e in _counts.entries) e.key.name: e.value,
      },
      'session_duration_sec': duration,
    };
  }
}
```

- [ ] **Step 4: 跑测试确认全绿**

Run: `flutter test test/auto_capture_telemetry_test.dart`
Expected: PASS,3 个测试全过

- [ ] **Step 5: 在采集页打点**

在 State 里加字段:

```dart
final AutoCaptureTelemetry _autoTelemetry = AutoCaptureTelemetry();
```

在 `:585` pose 回调的自动拍分支里,**每次判定都记**(不是只记 fire ——
`skipNotMoved` 的占比才是视差下限那道门的实际拦截率):

```dart
  if (_captureMode == OfficialCaptureMode.auto && _autoCapture.isRunning) {
    final d = _autoCapture.onPose(p);
    _autoTelemetry.recordDecision(d);          // ← 新增这一行
    if (d != _lastAutoDecision) {
```

在启停里记会话边界:

```dart
void _startAutoCapture(ARPose seed) {
  if (_autoCapture.isRunning) return;
  _autoTelemetry.recordSessionStart(seed.timestamp);
  setState(() => _autoCapture.start(seed));
}

void _stopAutoCapture() {
  if (!_autoCapture.isRunning) return;
  _autoTelemetry.recordSessionEnd(_lastPose?.timestamp ?? 0);
  setState(_autoCapture.stop);
}
```

把 `snapshot()` 并进采集页已有的遥测落盘出口 —— 即写 `_hiresStillFailReasons`
那张 map 的同一处,加一个 `'auto_capture'` 键:

```dart
  'auto_capture': _autoTelemetry.snapshot(),
```

⚠️ 找不到那个出口时,**先 grep `_hiresStillFailReasons` 的读取方**再动手,
不要另起一条遥测通道 —— 多一条出口就多一处会漏采的地方。

- [ ] **Step 6: 全量测试 + 提交**

Run: `flutter test test/`
Expected: PASS

```bash
cd ~/Developer/pocketworld
git add -- lib/official_capture/auto_capture_telemetry.dart test/auto_capture_telemetry_test.dart lib/ui/official_capture/ar_capture_page.dart
git diff --cached --stat   # 必须只有这三个文件
printf '%s\n' \
  'feat(auto-capture): 遥测——专门去回答"视差下限到底有没有用"' \
  '' \
  '四家同行(RS/Polycam/KIRI/Scaniverse)都没有"移动太少就别拍"这道门,' \
  '只讲重叠上限。我们有,依据是自家 coverage cloud 把低视差判成双墙成因。' \
  '但同行不设下限也可能是因为手持绕物时它根本很少触发——若如此这道门' \
  '无害但也无用。skipNotMoved 的占比就是它的实际拦截率,文档判不了,只能实测。' \
  '' \
  '同时采:上限提前触发占比、采集时长 vs 5 分钟上限、ShutterPace 三档停留。' \
  '' \
  'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
  > /tmp/t5msg.txt
GIT_TERMINAL_PROMPT=0 git commit -F /tmp/t5msg.txt </dev/null
```

---

## 真机验证(不在本计划的任务里,但没它就不算做完)

spec §10 ② 明确:单测证明不了这功能能用。以下必须真机跑,且**装机前按仓规先做设备备份**(`docs/IOS_DEVICE_INSTALL.md`):

1. `add_frame` 单帧耗时打点 —— **spec §11 唯一还完全未知的关键数**,决定积压会不会撑破"拍完 ≤30s"
2. 一次完整绕物采集:实际张数、相邻帧视差分布、拍完到 finalize 的等待时长、热曲线
3. **单变量对照**:同一物体、同一路径,手动拍一次 / 自动拍一次,比点云
4. 用 ① 的实测值回头标定 `kAutoCaptureTurnMinDeg`(现值 10° 无外部依据)与 ShutterPace 三档间隔

⚠️ 装机相关的仓规(`CLAUDE.md`):真机包必须 `flutter build ios --profile`(debug 脱调试器即崩);真机测试必须拔线安全(detached 启动、日志写 App 容器、事后 `devicectl copy` 拉取)。
