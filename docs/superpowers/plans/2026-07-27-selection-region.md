# 选区功能(RS Reconstruction Region 复刻)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 等待页 refined 后"保存草稿|下一步"→ 选区页(朝向预设、包围盒手柄、框外变红、旋转滑杆),框存 JSON,PLY 永不裁,草稿查看器只读回显。

**Architecture:** 共享投影核心 `CloudCamera/CloudProjection` 消除 painter 公式重复;`SelectionBox` 纯数据模型 + JSON 持久化;新路由 `SelectionPage` push 在 capture route 之上;`SparseCloudView` 只加只读回显参数。

**Tech Stack:** Flutter/Dart(纯 Dart 渲染,CustomPaint;无 native 改动)。Spec:`docs/superpowers/specs/2026-07-27-selection-region-design.md`。

## Global Constraints

- 永远用中文注释/文案;技术名词可留英文(CLAUDE.md)。
- **PLY 永不改写、点云永远全量交付**(铁律;本功能只写 `official_selection_box.json`)。
- 计算不搬 Swift;本功能纯 Dart,零 native 改动。
- 测试跑法:`cd ~/Developer/pocketworld && flutter test <file>`;host 需要 `../Aether3D-cross` 存在(部分契约测试读它)。
- 提交:`git commit -F <msgfile> </dev/null`,禁 push(共享脏分支)。commit 末尾加 `Co-Authored-By` 行。
- 提交前跑 `dart format <改动文件>` 与 `flutter analyze lib/ test/`(不许新增 analyzer 问题;当前基线 12 条既有告警)。
- ⚠️ 共享脏树:工作区可能有他人未提交改动,`git add` 只加本任务列出的文件,**绝不 `git add -A` / `commit -a`**。

---

### Task 1: SelectionBox 数据模型 + JSON 持久化

**Files:**
- Create: `lib/official_capture/selection_box.dart`
- Test: `test/selection_box_test.dart`

**Interfaces:**
- Produces:
  - `class SelectionBox { final double cx, cy, cz, sx, sy, sz, yawDeg; }`
  - `SelectionBox.initialFor({required double cx, required double cy, required double cz, required double radius})` — fit 球外接立方(半尺寸=radius)
  - `bool contains(double wx, double wy, double wz)`
  - `SelectionBox copyWith({...})`(全字段可选)
  - `Map<String, dynamic> toJson()` / `static SelectionBox? fromJson(Object? j)`(损坏→null)
  - `static Future<SelectionBox?> loadFrom(String captureDir)` / `Future<void> saveTo(String captureDir)`(文件名常量 `kSelectionBoxFileName = 'official_selection_box.json'`)
  - `static const double kMinHalfSizeFraction = 0.02;`(盒最小半尺寸 = radius × 此值,Task 4 用)

- [ ] **Step 1: 写失败测试**

```dart
// test/selection_box_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';

void main() {
  test('JSON round-trip 保真', () {
    const b = SelectionBox(
      cx: 1, cy: -2, cz: 3, sx: 4, sy: 5, sz: 6, yawDeg: 30);
    final back = SelectionBox.fromJson(b.toJson());
    expect(back, isNotNull);
    expect(back!.cx, 1);
    expect(back.sy, 5);
    expect(back.yawDeg, 30);
  });

  test('损坏 JSON → null,不抛', () {
    expect(SelectionBox.fromJson(null), isNull);
    expect(SelectionBox.fromJson('garbage'), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 'nan?'}), isNull);
    expect(SelectionBox.fromJson(<String, dynamic>{'cx': 1}), isNull); // 缺字段
  });

  test('contains:轴对齐盒', () {
    const b = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6, yawDeg: 0);
    expect(b.contains(0.99, 1.99, 2.99), isTrue);
    expect(b.contains(1.01, 0, 0), isFalse);
    expect(b.contains(0, 2.01, 0), isFalse);
    expect(b.contains(0, 0, -3.01), isFalse);
  });

  test('contains:yaw=90° 时 x/z 半尺寸互换', () {
    // 盒局部 x 半尺寸 1、z 半尺寸 3;绕 Y 转 90° 后世界 x 方向的可容纳
    // 范围由局部 z 决定。
    const b = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 2, sy: 10, sz: 6, yawDeg: 90);
    expect(b.contains(2.9, 0, 0), isTrue); // 世界 x=2.9 < 局部 z 半尺寸 3
    expect(b.contains(0, 0, 1.1), isFalse); // 世界 z=1.1 > 局部 x 半尺寸 1
  });

  test('文件存取 round-trip + 缺失→null', () async {
    final dir = await Directory.systemTemp.createTemp('selbox');
    addTearDown(() => dir.delete(recursive: true));
    expect(await SelectionBox.loadFrom(dir.path), isNull);
    const b = SelectionBox(
      cx: 1, cy: 2, cz: 3, sx: 4, sy: 5, sz: 6, yawDeg: -15);
    await b.saveTo(dir.path);
    final back = await SelectionBox.loadFrom(dir.path);
    expect(back!.yawDeg, -15);
  });

  test('initialFor = fit 球外接立方', () {
    final b = SelectionBox.initialFor(cx: 1, cy: 2, cz: 3, radius: 5);
    expect(b.cx, 1);
    expect(b.sx, 10); // 2×radius
    expect(b.sy, 10);
    expect(b.yawDeg, 0);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/selection_box_test.dart`
Expected: FAIL(找不到 `selection_box.dart`)

- [ ] **Step 3: 最小实现**

```dart
// lib/official_capture/selection_box.dart — 选区盒(重力系轴对齐 + 绕竖直轴
// yaw)。给未来稠密化划边界的元数据;PLY 永不因它改写。
// 设计:docs/superpowers/specs/2026-07-27-selection-region-design.md
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String kSelectionBoxFileName = 'official_selection_box.json';

class SelectionBox {
  const SelectionBox({
    required this.cx,
    required this.cy,
    required this.cz,
    required this.sx,
    required this.sy,
    required this.sz,
    required this.yawDeg,
  });

  /// 盒中心(世界系,点云已重力对齐:Y=重力上)。
  final double cx, cy, cz;

  /// 盒全尺寸(局部系各轴)。
  final double sx, sy, sz;

  /// 绕世界 Y 轴旋转角(度)。盒转、点云不动。
  final double yawDeg;

  /// 盒最小半尺寸 = fit radius × 此值(手柄 clamp 用,防拖成退化盒)。
  static const double kMinHalfSizeFraction = 0.02;

  /// 初始盒 = fit 球(SparseCloudPainter.fitOf)的外接立方。
  factory SelectionBox.initialFor({
    required double cx,
    required double cy,
    required double cz,
    required double radius,
  }) => SelectionBox(
    cx: cx, cy: cy, cz: cz,
    sx: radius * 2, sy: radius * 2, sz: radius * 2,
    yawDeg: 0,
  );

  bool contains(double wx, double wy, double wz) {
    // 世界 → 盒局部。正变换(局部→世界,见 selectionBoxCorners)是
    //   wx = lx·cosθ − lz·sinθ; wz = lx·sinθ + lz·cosθ  (θ = yawDeg)
    // 其标准逆式如下 —— 别用"负角+正式"的写法,那不是它的逆
    // (计划自审时抓过一次这个旋转方向 bug)。
    final t = yawDeg * math.pi / 180.0;
    final c = math.cos(t), s = math.sin(t);
    final px = wx - cx, py = wy - cy, pz = wz - cz;
    final lx = px * c + pz * s;
    final lz = -px * s + pz * c;
    return lx.abs() <= sx / 2 && py.abs() <= sy / 2 && lz.abs() <= sz / 2;
  }

  SelectionBox copyWith({
    double? cx, double? cy, double? cz,
    double? sx, double? sy, double? sz,
    double? yawDeg,
  }) => SelectionBox(
    cx: cx ?? this.cx, cy: cy ?? this.cy, cz: cz ?? this.cz,
    sx: sx ?? this.sx, sy: sy ?? this.sy, sz: sz ?? this.sz,
    yawDeg: yawDeg ?? this.yawDeg,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cx': cx, 'cy': cy, 'cz': cz,
    'sx': sx, 'sy': sy, 'sz': sz,
    'yawDeg': yawDeg,
  };

  /// 任何形状不对/类型不对/非有限值 → null(容错:选区文件坏不许拖垮查看器)。
  static SelectionBox? fromJson(Object? j) {
    if (j is! Map) return null;
    double? d(Object? v) =>
        (v is num && v.isFinite) ? v.toDouble() : null;
    final cx = d(j['cx']), cy = d(j['cy']), cz = d(j['cz']);
    final sx = d(j['sx']), sy = d(j['sy']), sz = d(j['sz']);
    final yaw = d(j['yawDeg']);
    if ([cx, cy, cz, sx, sy, sz, yaw].contains(null)) return null;
    return SelectionBox(
      cx: cx!, cy: cy!, cz: cz!, sx: sx!, sy: sy!, sz: sz!, yawDeg: yaw!);
  }

  static Future<SelectionBox?> loadFrom(String captureDir) async {
    try {
      final f = File('$captureDir/$kSelectionBoxFileName');
      if (!await f.exists()) return null;
      return fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTo(String captureDir) async {
    final f = File('$captureDir/$kSelectionBoxFileName');
    await f.writeAsString(jsonEncode(toJson()), flush: true);
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/selection_box_test.dart`
Expected: 全 PASS

- [ ] **Step 5: format + analyze + 提交**

```bash
dart format lib/official_capture/selection_box.dart test/selection_box_test.dart
flutter analyze lib/official_capture/selection_box.dart test/selection_box_test.dart
git add lib/official_capture/selection_box.dart test/selection_box_test.dart
git commit -F <(printf 'feat(selection): SelectionBox 数据模型 + JSON 持久化\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```

---

### Task 2: CloudCamera/CloudProjection 共享投影核心

**Files:**
- Create: `lib/ui/official_capture/cloud_camera.dart`
- Modify: `lib/ui/official_capture/sparse_cloud_view.dart`(paint:765-773 段与 pointAtScreen:634-641 段的标量来源)
- Test: `test/cloud_camera_test.dart`

**Interfaces:**
- Produces:
  - `class CloudCamera { final double yaw, pitch, zoom, panX, panY, pivotX, pivotY, pivotZ, radius, fillK; CloudProjection projectionFor(Size size); }`
  - `class CloudProjection { final double cosY, sinY, cosP, sinP, f, camDist, ox, oy; (double, double, double) project(double wx, double wy, double wz); double worldPerPixelAt(double depth); List<double> rightAxisWorld(); List<double> upAxisWorld(); }`
- 关键事实(实现者必读):现有权威公式在 `sparse_cloud_view.dart` paint()/pointAtScreen(),两处完全相同:
  `x1=px·cosY+pz·sinY; z1=-px·sinY+pz·cosY; y2=py·cosP-z1·sinP; z2=py·sinP+z1·cosP; depth=z2+camDist; sx=ox-x1·f/depth; sy=oy-y2·f/depth`
  其中 `f=half·fillK·zoom`(half=size.shortestSide·0.5,fillK=2.6)、`camDist=radius·3.2`、`ox=size.width·0.5+panX`、`oy=size.height·0.5+panY`。

- [ ] **Step 1: 写失败测试**

```dart
// test/cloud_camera_test.dart
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

void main() {
  test('project() 与手工展开逐位一致(随机相机×随机点)', () {
    final rnd = math.Random(42);
    for (var t = 0; t < 200; t++) {
      final cam = CloudCamera(
        yaw: rnd.nextDouble() * 6 - 3,
        pitch: rnd.nextDouble() * 3 - 1.5,
        zoom: 0.3 + rnd.nextDouble() * 3,
        panX: rnd.nextDouble() * 100 - 50,
        panY: rnd.nextDouble() * 100 - 50,
        pivotX: rnd.nextDouble() * 4 - 2,
        pivotY: rnd.nextDouble() * 4 - 2,
        pivotZ: rnd.nextDouble() * 4 - 2,
        radius: 0.5 + rnd.nextDouble() * 5,
      );
      const size = Size(390, 700);
      final p = cam.projectionFor(size);
      final wx = rnd.nextDouble() * 8 - 4;
      final wy = rnd.nextDouble() * 8 - 4;
      final wz = rnd.nextDouble() * 8 - 4;
      // 手工展开 = sparse_cloud_view paint() 的原式
      final cosY = math.cos(cam.yaw), sinY = math.sin(cam.yaw);
      final cosP = math.cos(cam.pitch), sinP = math.sin(cam.pitch);
      final half = size.shortestSide * 0.5;
      final f = half * cam.fillK * cam.zoom;
      final camDist = cam.radius * 3.2;
      final ox = size.width * 0.5 + cam.panX;
      final oy = size.height * 0.5 + cam.panY;
      final px = wx - cam.pivotX, py = wy - cam.pivotY, pz = wz - cam.pivotZ;
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;
      final depth = z2 + camDist;
      final (sx, sy, d) = p.project(wx, wy, wz);
      expect(d, closeTo(depth, 1e-9));
      expect(sx, closeTo(ox - x1 * f / depth, 1e-9));
      expect(sy, closeTo(oy - y2 * f / depth, 1e-9));
    }
  });

  test('worldPerPixelAt:1 像素屏幕位移 ≈ depth/f 世界位移', () {
    const cam = CloudCamera(
      yaw: 0.3, pitch: -0.4, zoom: 1, panX: 0, panY: 0,
      pivotX: 0, pivotY: 0, pivotZ: 0, radius: 2);
    const size = Size(400, 400);
    final p = cam.projectionFor(size);
    final wpp = p.worldPerPixelAt(5.0);
    expect(wpp, closeTo(5.0 / p.f, 1e-12));
  });

  test('视平面基向量:right/up 与投影一致(数值微分验证)', () {
    const cam = CloudCamera(
      yaw: 0.7, pitch: -0.5, zoom: 1.4, panX: 3, panY: -8,
      pivotX: 0.2, pivotY: -0.1, pivotZ: 0.4, radius: 1.5);
    const size = Size(390, 700);
    final p = cam.projectionFor(size);
    const w = (0.5, -0.3, 0.8);
    final (sx0, sy0, d0) = p.project(w.$1, w.$2, w.$3);
    // 沿 rightAxisWorld 移动 ε 世界距离 → 屏幕 x 增加 ε·f/depth,y 不变
    final r = p.rightAxisWorld();
    const eps = 1e-4;
    final (sx1, sy1, _) =
        p.project(w.$1 + r[0] * eps, w.$2 + r[1] * eps, w.$3 + r[2] * eps);
    expect((sx1 - sx0) / eps, closeTo(-1 * -1 * p.f / d0, 1e-2)); // +f/depth
    expect((sy1 - sy0).abs() / eps, lessThan(1e-2));
    final u = p.upAxisWorld();
    final (sx2, sy2, _) =
        p.project(w.$1 + u[0] * eps, w.$2 + u[1] * eps, w.$3 + u[2] * eps);
    expect((sy2 - sy0) / eps, closeTo(-p.f / d0, 1e-2)); // 屏幕 y 向下为正
    expect((sx2 - sx0).abs() / eps, lessThan(1e-2));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/cloud_camera_test.dart`
Expected: FAIL(找不到 `cloud_camera.dart`)

- [ ] **Step 3: 实现**

```dart
// lib/ui/official_capture/cloud_camera.dart — 点云相机/投影的单一事实源。
//
// 公式所有权在 CloudProjection.project();SparseCloudPainter 与
// SelectionCloudView 的热循环仍用标量展开(数万点逐点调函数不划算),但
// 八个标量一律从这里取,一致性由 test/cloud_camera_test.dart 的 parity
// 测试锁死。历史:此前 paint() 与 pointAtScreen() 各写一份同式,注释靠
// "Kept bit-identical" 人肉维持 —— 本文件终结这种维持方式。
import 'dart:math' as math;
import 'dart:ui' show Size;

class CloudCamera {
  const CloudCamera({
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
    required this.radius,
    this.fillK = 2.6, // SparseCloudView 开屏取景系数(user-locked 2026-07-06)
  });

  final double yaw, pitch, zoom, panX, panY;
  final double pivotX, pivotY, pivotZ;

  /// 取景 fit 球半径(SparseCloudPainter.fitOf 的 radius)。
  final double radius;
  final double fillK;

  CloudProjection projectionFor(Size size) {
    final half = size.shortestSide * 0.5;
    return CloudProjection._(
      cosY: math.cos(yaw),
      sinY: math.sin(yaw),
      cosP: math.cos(pitch),
      sinP: math.sin(pitch),
      f: half * fillK * zoom,
      camDist: radius * 3.2,
      ox: size.width * 0.5 + panX,
      oy: size.height * 0.5 + panY,
      pivotX: pivotX,
      pivotY: pivotY,
      pivotZ: pivotZ,
    );
  }
}

class CloudProjection {
  const CloudProjection._({
    required this.cosY,
    required this.sinY,
    required this.cosP,
    required this.sinP,
    required this.f,
    required this.camDist,
    required this.ox,
    required this.oy,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
  });

  final double cosY, sinY, cosP, sinP, f, camDist, ox, oy;
  final double pivotX, pivotY, pivotZ;

  /// 权威投影:世界点 → (屏幕x, 屏幕y, 深度)。深度 <= 0 表示在相机后。
  (double, double, double) project(double wx, double wy, double wz) {
    final px = wx - pivotX, py = wy - pivotY, pz = wz - pivotZ;
    final x1 = px * cosY + pz * sinY;
    final z1 = -px * sinY + pz * cosY;
    final y2 = py * cosP - z1 * sinP;
    final z2 = py * sinP + z1 * cosP;
    final depth = z2 + camDist;
    return (ox - x1 * f / depth, oy - y2 * f / depth, depth);
  }

  /// 深度 depth 处,1 屏幕像素对应的世界距离(手柄拖拽逆映射)。
  double worldPerPixelAt(double depth) => depth / f;

  /// 屏幕 +x 方向(注意投影带负号:sx = ox - x1·f/depth,所以屏幕右移
  /// = 视空间 x1 减小)对应的世界方向单位向量。
  List<double> rightAxisWorld() => [-cosY, 0, -sinY];

  /// 屏幕 +y(向下)对应的世界方向单位向量。
  /// 推导:sy = oy − y2·f/depth ⇒ 屏幕下移要求 y2 减小;
  /// y2 = py·cosP − z1·sinP,z1 = −px·sinY + pz·cosY
  /// ⇒ ∂y2/∂(px,py,pz) = (sinY·sinP, cosP, −cosY·sinP),取负即得。
  List<double> upAxisWorld() => [-sinY * sinP, -cosP, cosY * sinP];
}
```

⚠️ `rightAxisWorld/upAxisWorld` 的推导要点(实现者自查,别抄错符号):
视空间 `x1 = px·cosY + pz·sinY`,屏幕 `sx = ox − x1·f/depth` ⇒ 屏幕 +x 要求
`x1` 减小 ⇒ 世界方向 `(−cosY, 0, −sinY)`。
`y2 = py·cosP − z1·sinP`,`z1 = −px·sinY + pz·cosY`,屏幕 `sy = oy − y2·f/depth`
⇒ 屏幕 +y(向下)要求 `y2` 减小 ⇒ 世界方向 `(−sinY·sinP, −cosP, cosY·sinP)`。
Step 1 的数值微分测试就是抓这里的符号错的 —— 以测试为准。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/cloud_camera_test.dart`
Expected: 全 PASS(若基向量测试红,按数值微分修符号)

- [ ] **Step 5: SparseCloudView 改从 CloudProjection 取标量**

`sparse_cloud_view.dart` 两处(paint() 与 pointAtScreen())把

```dart
final cosY = math.cos(yaw), sinY = math.sin(yaw);
final cosP = math.cos(pitch), sinP = math.sin(pitch);
final half = size.shortestSide * 0.5;
final f = half * _fitFillK * zoom;
final camDist = _radius * 3.2;
final ox = size.width * 0.5 + panX, oy = size.height * 0.5 + panY;
```

替换为(pointAtScreen 里 pivot 是 `List<double> pivot`,对应取 `pivot[0..2]`):

```dart
final proj = CloudCamera(
  yaw: yaw, pitch: pitch, zoom: zoom, panX: panX, panY: panY,
  pivotX: pivotX, pivotY: pivotY, pivotZ: pivotZ,
  radius: _radius, fillK: _fitFillK,
).projectionFor(size);
final cosY = proj.cosY, sinY = proj.sinY;
final cosP = proj.cosP, sinP = proj.sinP;
final f = proj.f, camDist = proj.camDist, ox = proj.ox, oy = proj.oy;
```

循环体一行不动。文件头加 `import 'cloud_camera.dart';`。

- [ ] **Step 6: 跑全量测试确认零回归**

Run: `flutter test`
Expected: 与基线相同(当前 177 pass;若基线已被并发改动,以"无新增失败"为准)

- [ ] **Step 7: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/cloud_camera.dart lib/ui/official_capture/sparse_cloud_view.dart test/cloud_camera_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/cloud_camera.dart lib/ui/official_capture/sparse_cloud_view.dart test/cloud_camera_test.dart
git commit -F <(printf 'refactor(cloud): CloudCamera/CloudProjection 投影单一事实源\n\npaint/pointAtScreen 标量改由共享派生;公式一致性由 parity 测试锁死。\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```

---

### Task 3: SparseCloudView 只读 selectionBox 回显(框线 + 框外红)

**Files:**
- Modify: `lib/ui/official_capture/sparse_cloud_view.dart`
- Test: `test/sparse_cloud_selection_overlay_test.dart`

**Interfaces:**
- Consumes: Task 1 `SelectionBox`(`contains`),Task 2 `CloudProjection`
- Produces:
  - `SparseCloudView({..., SelectionBox? selectionBox})` — 只读回显
  - `SparseCloudPainter({..., SelectionBox? selectionBox})`
  - 顶层函数 `List<List<double>> selectionBoxCorners(SelectionBox b)` — 8 角世界坐标,序:局部 (±sx/2, ±sy/2, ±sz/2) 按 `(x,y,z)` 位翻转,index = x位 + y位·2 + z位·4(0=负,1=正)
  - `const int kSelectionOutColor = 0xFFE05252;` — 框外点调制色

- [ ] **Step 1: 写失败测试**

```dart
// test/sparse_cloud_selection_overlay_test.dart
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

void main() {
  test('selectionBoxCorners:轴对齐盒 8 角', () {
    const b = SelectionBox(
      cx: 1, cy: 2, cz: 3, sx: 2, sy: 4, sz: 6, yawDeg: 0);
    final c = selectionBoxCorners(b);
    expect(c, hasLength(8));
    // index 0 = (-,-,-):世界 (1-1, 2-2, 3-3) = (0,0,0)
    expect(c[0][0], closeTo(0, 1e-9));
    expect(c[0][1], closeTo(0, 1e-9));
    expect(c[0][2], closeTo(0, 1e-9));
    // index 7 = (+,+,+):世界 (2,4,6)
    expect(c[7][0], closeTo(2, 1e-9));
    expect(c[7][1], closeTo(4, 1e-9));
    expect(c[7][2], closeTo(6, 1e-9));
  });

  test('selectionBoxCorners:yaw 旋转绕中心', () {
    const b = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 2, sy: 2, sz: 2, yawDeg: 90);
    final c = selectionBoxCorners(b);
    // 局部 (+1,·,0±):yaw90° 后局部 +x → 世界 -z(与 contains 逆变换互逆)
    // 所有角到中心距离不变
    for (final p in c) {
      expect(
        math.sqrt(p[0] * p[0] + p[1] * p[1] + p[2] * p[2]),
        closeTo(math.sqrt(3), 1e-9),
      );
    }
  });

  testWidgets('带 selectionBox 渲染不崩(1000 点半内半外)', (tester) async {
    final n = 1000;
    final xyz = Float32List(n * 3);
    final rgb = Uint8List(n * 3);
    final rnd = math.Random(7);
    for (var i = 0; i < n; i++) {
      xyz[i * 3] = rnd.nextDouble() * 4 - 2;
      xyz[i * 3 + 1] = rnd.nextDouble() * 4 - 2;
      xyz[i * 3 + 2] = rnd.nextDouble() * 4 - 2;
      rgb[i * 3] = 100;
    }
    const box = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 2, sy: 2, sz: 2, yawDeg: 20);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SparseCloudView(xyz: xyz, rgb: rgb, selectionBox: box),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sparse_cloud_selection_overlay_test.dart`
Expected: FAIL(`selectionBoxCorners` 未定义 / 参数不存在)

- [ ] **Step 3: 实现**

`sparse_cloud_view.dart` 改动四处:

3a. import + 顶层函数 + 常量(文件顶部,import 区之后):

```dart
import '../../official_capture/selection_box.dart';

/// 框外点的调制色(RS 同款红;只影响渲染调制,不碰数据)。
const int kSelectionOutColor = 0xFFE05252;

/// 选区盒 8 角世界坐标。index = x位 + y位·2 + z位·4(0=负,1=正)。
List<List<double>> selectionBoxCorners(SelectionBox b) {
  final a = b.yawDeg * math.pi / 180.0;
  final c = math.cos(a), s = math.sin(a);
  final out = <List<double>>[];
  for (var zi = 0; zi < 2; zi++) {
    for (var yi = 0; yi < 2; yi++) {
      for (var xi = 0; xi < 2; xi++) {
        final lx = (xi == 0 ? -1 : 1) * b.sx / 2;
        final ly = (yi == 0 ? -1 : 1) * b.sy / 2;
        final lz = (zi == 0 ? -1 : 1) * b.sz / 2;
        // 局部 → 世界:绕 Y 转 +yaw(contains 的逆变换)
        out.add([
          b.cx + lx * c - lz * s,
          b.cy + ly,
          b.cz + lx * s + lz * c,
        ]);
      }
    }
  }
  return out;
}
```

3b. `SparseCloudView` 构造加 `this.selectionBox`,字段:

```dart
  /// 只读选区回显(草稿查看器):画框线 + 框外点变红。null = 无选区。
  /// 渲染层行为 —— 不影响数据、fit、导出;编辑在 SelectionPage。
  final SelectionBox? selectionBox;
```

并在 build 里传给 `SparseCloudPainter(selectionBox: widget.selectionBox, ...)`(该文件 build 里已有的 painter 构造点,约 :295)。

3c. `SparseCloudPainter` 构造/字段加 `this.selectionBox`;paint() 点循环里,拿到最终 argb 后(写入 `colorA[m]` 之前)插:

```dart
      if (selectionBox != null && !selectionBox!.contains(wx, wy, wz)) {
        argb = kSelectionOutColor; // 框外 → 红(点不消失)
      }
```

(实现者注意:paint() 里颜色变量名以现场为准 —— 若当前是直接写 `colorA[m] = ...` 的表达式,先提出局部变量再插判断。)

3d. paint() 末尾(drawRawAtlas 之后)画框线:

```dart
    final selBox = selectionBox;
    if (selBox != null) {
      final corners = selectionBoxCorners(selBox);
      const edges = [
        [0, 1], [2, 3], [4, 5], [6, 7], // x 向边
        [0, 2], [1, 3], [4, 6], [5, 7], // y 向边
        [0, 4], [1, 5], [2, 6], [3, 7], // z 向边
      ];
      final line = Paint()
        ..color = const Color(0xCCFFFFFF)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      for (final e in edges) {
        final a = corners[e[0]], b = corners[e[1]];
        // 用与点同一套标量投影(cosY 等就是循环上方的那批局部变量)
        Offset? proj3(List<double> w) {
          final px = w[0] - pivotX, py = w[1] - pivotY, pz = w[2] - pivotZ;
          final x1 = px * cosY + pz * sinY;
          final z1 = -px * sinY + pz * cosY;
          final y2 = py * cosP - z1 * sinP;
          final z2 = py * sinP + z1 * cosP;
          final depth = z2 + camDist;
          if (depth <= 1e-6) return null;
          return Offset(ox - x1 * f / depth, oy - y2 * f / depth);
        }
        final pa = proj3(a), pb = proj3(b);
        if (pa != null && pb != null) canvas.drawLine(pa, pb, line);
      }
    }
```

并把 `shouldRepaint` 加上 `old.selectionBox != selectionBox`。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/sparse_cloud_selection_overlay_test.dart && flutter test`
Expected: 新测试 PASS 且全量无新增失败

- [ ] **Step 5: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/sparse_cloud_view.dart test/sparse_cloud_selection_overlay_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/sparse_cloud_view.dart test/sparse_cloud_selection_overlay_test.dart
git commit -F <(printf 'feat(selection): SparseCloudView 只读选区回显(框线+框外红)\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```

---

### Task 4: 选区 2D 矩形手柄数学(纯函数)+ SelectionCloudView

> [2026-07-27 调研修订] 手柄模型 = RS Mobile 官方同款 **2D 投影矩形**
> (角=双轴、边=单轴、纯屏幕命中),不做 3D 的 8 角+4 竖边手柄。
> 矩形几何用盒中心深度统一缩放(正交近似),拖拽逆映射用同一深度 ——
> 往返自洽。盒局部轴的屏幕方向由投影**数值差分**求得,零手写映射表,
> 符号自动正确。

**Files:**
- Create: `lib/ui/official_capture/selection_cloud_view.dart`
- Modify: `lib/ui/official_capture/sparse_cloud_view.dart`(SparseCloudPainter 加 `drawSelectionWireframe` 开关,默认 true —— 选区页要红点但不要 3D 线框)
- Test: `test/selection_rect_math_test.dart`

**Interfaces:**
- Consumes: Task 1 `SelectionBox`;Task 2 `CloudCamera/CloudProjection`;Task 3 `SparseCloudPainter(selectionBox:)`
- Produces(全在 `selection_cloud_view.dart` 顶层,test 直接 import):
  - `enum RectHandle { cornerTL, cornerTR, cornerBL, cornerBR, edgeL, edgeR, edgeT, edgeB }`(屏幕语义命名)
  - `class BoxScreenBasis { final int hAxis, vAxis; final double hSx, vSy; final double scale; final double cxS, cyS; }` — 当前视角下盒的屏幕基:h/vAxis ∈ {0:x,1:y,2:z}(盒局部轴),hSx/vSy = 该局部轴单位向量的屏幕 x/y 分量(带符号),scale = f/centerDepth,(cxS,cyS) = 盒中心屏幕坐标
  - `BoxScreenBasis boxScreenBasis(CloudProjection proj, SelectionBox box)` — 对盒局部 x/y/z 三轴做投影差分,|屏幕x| 最大者为 hAxis、|屏幕y| 最大者为 vAxis(两者必不同轴,断言保护)
  - `Rect selectionScreenRect(BoxScreenBasis b, SelectionBox box)` — 屏幕对齐矩形:中心 (cxS,cyS),半宽 = 盒 hAxis 半尺寸·scale,半高 = vAxis 半尺寸·scale
  - `RectHandle? hitRectHandle(Rect r, Offset tap, {double tolPx = 34})` — 纯 2D:8 个手柄点(4 角 + 4 边中点)最近命中
  - `SelectionBox applyRectHandleDrag({required SelectionBox box, required BoxScreenBasis basis, required RectHandle h, required Offset screenDelta, required double minHalfSize})` — 受控局部面外扩/收缩、对面不动(中心补偿);corner 控 h+v 两轴,edge 控单轴
  - `SelectionBox applyBoxPan({required SelectionBox box, required CloudProjection proj, required Offset screenDelta, required double depth})` — 空白拖动整盒平移(视平面 right/up × worldPerPixelAt)
  - `class SelectionCloudView extends StatefulWidget`:
    `SelectionCloudView({required Float32List xyz, required Uint8List rgb, required SelectionBox box, required ValueChanged<SelectionBox> onBoxChanged, required double viewYaw, required double viewPitch})`
    (viewYaw **已含**滑杆分量 —— Task 5 传 `preset.yaw + box.yawDeg·π/180`)

- [ ] **Step 1: 写失败测试(纯函数层)**

```dart
// test/selection_rect_math_test.dart
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_cloud_view.dart';

CloudProjection _proj({double yaw = 0, double pitch = 0}) => CloudCamera(
  yaw: yaw, pitch: pitch, zoom: 1, panX: 0, panY: 0,
  pivotX: 0, pivotY: 0, pivotZ: 0, radius: 2,
).projectionFor(const Size(400, 400));

void main() {
  const box = SelectionBox(
    cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6, yawDeg: 0);

  test('Front 视角(yaw0,pitch0):可见轴 = 局部 x/y', () {
    final b = boxScreenBasis(_proj(), box);
    expect(b.hAxis, 0); // x
    expect(b.vAxis, 1); // y
    // 屏幕投影带负号(sx = ox − x1·f/depth):局部 +x → 屏幕 −x
    expect(b.hSx, lessThan(0));
    // y 向上为正、屏幕 y 向下 ⇒ 局部 +y → 屏幕 −y
    expect(b.vSy, lessThan(0));
  });

  test('Top 视角(pitch=−π/2):可见轴 = 局部 x/z', () {
    final b = boxScreenBasis(_proj(pitch: -3.141592653589793 / 2), box);
    expect(b.hAxis, 0); // x
    expect(b.vAxis, 2); // z
  });

  test('Right 视角(yaw=π/2):可见轴 = 局部 z/y', () {
    final b = boxScreenBasis(_proj(yaw: 3.141592653589793 / 2), box);
    expect(b.hAxis, 2); // z
    expect(b.vAxis, 1); // y
  });

  test('盒 yaw 被相机 yaw 抵消后仍是干净的 x/y(滑杆语义)', () {
    const turned = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 2, sy: 4, sz: 6, yawDeg: 30);
    // 相机 yaw = preset(0) + 盒 yaw(30°) —— Task 5 的组装约定
    final b = boxScreenBasis(_proj(yaw: 30 * 3.141592653589793 / 180), turned);
    expect(b.hAxis, 0);
    expect(b.vAxis, 1);
    // 抵消后矩形保持屏幕对齐:单位局部轴的屏幕分量 ≈ scale(全量落在
    // 水平方向,没有泄漏到另一轴)
    expect(b.hSx.abs(), greaterThan(b.scale * 0.9));
  });

  test('selectionScreenRect:半宽/半高 = 半尺寸×scale', () {
    final b = boxScreenBasis(_proj(), box);
    final r = selectionScreenRect(b, box);
    expect(r.width, closeTo(box.sx * b.scale, 1e-6));
    expect(r.height, closeTo(box.sy * b.scale, 1e-6));
    expect(r.center.dx, closeTo(b.cxS, 1e-6));
  });

  test('hitRectHandle:角/边/空白', () {
    const r = Rect.fromLTRB(100, 100, 300, 260);
    expect(hitRectHandle(r, const Offset(102, 98)), RectHandle.cornerTL);
    expect(hitRectHandle(r, const Offset(300, 180)), RectHandle.edgeR);
    expect(hitRectHandle(r, const Offset(200, 262)), RectHandle.edgeB);
    expect(hitRectHandle(r, const Offset(200, 180)), isNull); // 矩形内部空白
    expect(hitRectHandle(r, const Offset(10, 10)), isNull);
  });

  test('拖 edgeR 向屏幕右:hAxis 尺寸变、对面不动', () {
    final b = boxScreenBasis(_proj(), box);
    // Front 视角 hSx<0:屏幕右移 = 局部 −x 方向 ⇒ edgeR 对应局部 −x 面
    // 外扩。不管符号怎么落,不变量是:受控轴是 x、y/z 不变、对面世界坐标
    // 不动、矩形右边跟手。
    final out = applyRectHandleDrag(
      box: box, basis: b, h: RectHandle.edgeR,
      screenDelta: const Offset(20, 0), minHalfSize: 0.01);
    expect(out.sy, closeTo(box.sy, 1e-9));
    expect(out.sz, closeTo(box.sz, 1e-9));
    expect(out.sx, greaterThan(box.sx)); // 往外拖 = 变大
    // 对面(edgeL 对应的局部面)世界位置不动:
    final worldGrow = 20 / b.scale;
    expect(out.sx, closeTo(box.sx + worldGrow, 1e-6));
    // 中心沿受控面方向补偿一半
    expect(
      (out.cx - box.cx).abs() + (out.cz - box.cz).abs(),
      closeTo(worldGrow / 2, 1e-6),
    );
  });

  test('拖 cornerBR:h/v 两轴都变,第三轴不变', () {
    final b = boxScreenBasis(_proj(), box);
    final out = applyRectHandleDrag(
      box: box, basis: b, h: RectHandle.cornerBR,
      screenDelta: const Offset(10, 10), minHalfSize: 0.01);
    expect(out.sx, isNot(closeTo(box.sx, 1e-9)));
    expect(out.sy, isNot(closeTo(box.sy, 1e-9)));
    expect(out.sz, closeTo(box.sz, 1e-9));
  });

  test('clamp:往里挤穿也不退化', () {
    final b = boxScreenBasis(_proj(), box);
    final out = applyRectHandleDrag(
      box: box, basis: b, h: RectHandle.edgeR,
      screenDelta: const Offset(-99999, 0), minHalfSize: 0.05);
    expect(out.sx, greaterThanOrEqualTo(0.1));
  });

  test('applyBoxPan:屏幕拖动平移盒中心,尺寸不变', () {
    final proj = _proj();
    final out = applyBoxPan(
      box: box, proj: proj, screenDelta: const Offset(10, -6), depth: 6.4);
    expect(out.sx, box.sx);
    final moved = (out.cx - box.cx).abs() +
        (out.cy - box.cy).abs() +
        (out.cz - box.cz).abs();
    expect(moved, greaterThan(0));
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/selection_rect_math_test.dart`
Expected: FAIL(文件不存在)

- [ ] **Step 3: 实现纯函数**

`selection_cloud_view.dart` 纯函数部分(完整实现):

```dart
// selection_cloud_view.dart — 选区页专用渲染 + RS Mobile 同款 2D 矩形手柄。
//
// [2026-07-27 调研修订] RS Mobile 官方:角手柄=双轴、边手柄=单轴、框是
// 当前视角的屏幕对齐矩形(不是 3D 线框)。矩形用盒中心深度统一缩放
// (正交近似),拖拽逆映射用同一深度 —— 往返自洽;框是控制器 UI,不是
// 几何贴合线。盒局部轴的屏幕方向由投影差分求得,零手写映射表。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart';
import 'sparse_cloud_view.dart' show SparseCloudPainter;

enum RectHandle {
  cornerTL, cornerTR, cornerBL, cornerBR,
  edgeL, edgeR, edgeT, edgeB,
}

class BoxScreenBasis {
  const BoxScreenBasis({
    required this.hAxis,
    required this.vAxis,
    required this.hSx,
    required this.vSy,
    required this.scale,
    required this.cxS,
    required this.cyS,
  });

  /// 屏幕水平/垂直方向对应的盒局部轴(0:x 1:y 2:z)。
  final int hAxis, vAxis;

  /// 该局部轴单位向量的屏幕分量(带符号;拖拽方向映射用)。
  final double hSx, vSy;

  /// f / centerDepth —— 世界长度 → 屏幕像素(正交近似)。
  final double scale;

  /// 盒中心屏幕坐标。
  final double cxS, cyS;
}

/// 盒局部三轴 → 屏幕方向(投影差分,符号自动正确)。
BoxScreenBasis boxScreenBasis(CloudProjection proj, SelectionBox box) {
  final t = box.yawDeg * math.pi / 180.0;
  final c = math.cos(t), s = math.sin(t);
  // 盒局部轴单位向量的世界方向(corners 正变换的列向量)
  final axes = [
    [c, 0.0, s], // 局部 +x
    [0.0, 1.0, 0.0], // 局部 +y
    [-s, 0.0, c], // 局部 +z
  ];
  final (c0x, c0y, d0) = proj.project(box.cx, box.cy, box.cz);
  const eps = 1e-3;
  final sx = List<double>.filled(3, 0);
  final sy = List<double>.filled(3, 0);
  for (var a = 0; a < 3; a++) {
    final (px, py, _) = proj.project(
      box.cx + axes[a][0] * eps,
      box.cy + axes[a][1] * eps,
      box.cz + axes[a][2] * eps,
    );
    sx[a] = (px - c0x) / eps;
    sy[a] = (py - c0y) / eps;
  }
  var h = 0, v = 0;
  for (var a = 1; a < 3; a++) {
    if (sx[a].abs() > sx[h].abs()) h = a;
    if (sy[a].abs() > sy[v].abs()) v = a;
  }
  assert(h != v, 'boxScreenBasis: 视角退化,水平/垂直命中同一局部轴');
  return BoxScreenBasis(
    hAxis: h, vAxis: v, hSx: sx[h], vSy: sy[v],
    scale: proj.f / d0, cxS: c0x, cyS: c0y,
  );
}

double _sizeOfAxis(SelectionBox b, int axis) =>
    axis == 0 ? b.sx : (axis == 1 ? b.sy : b.sz);

ui.Rect selectionScreenRect(BoxScreenBasis b, SelectionBox box) {
  final hw = _sizeOfAxis(box, b.hAxis) / 2 * b.scale;
  final hh = _sizeOfAxis(box, b.vAxis) / 2 * b.scale;
  return ui.Rect.fromCenter(
    center: ui.Offset(b.cxS, b.cyS), width: hw * 2, height: hh * 2);
}

ui.Offset _handlePos(ui.Rect r, RectHandle h) => switch (h) {
  RectHandle.cornerTL => r.topLeft,
  RectHandle.cornerTR => r.topRight,
  RectHandle.cornerBL => r.bottomLeft,
  RectHandle.cornerBR => r.bottomRight,
  RectHandle.edgeL => ui.Offset(r.left, r.center.dy),
  RectHandle.edgeR => ui.Offset(r.right, r.center.dy),
  RectHandle.edgeT => ui.Offset(r.center.dx, r.top),
  RectHandle.edgeB => ui.Offset(r.center.dx, r.bottom),
};

RectHandle? hitRectHandle(ui.Rect r, ui.Offset tap, {double tolPx = 34}) {
  RectHandle? best;
  var bestD2 = tolPx * tolPx;
  for (final h in RectHandle.values) {
    final p = _handlePos(r, h);
    final dx = p.dx - tap.dx, dy = p.dy - tap.dy;
    final d2 = dx * dx + dy * dy;
    if (d2 < bestD2) {
      bestD2 = d2;
      best = h;
    }
  }
  return best;
}

/// 手柄 → (是否控水平轴, 屏幕方向符号) ×(是否控垂直轴, 符号)。
/// 屏幕符号:+1 = 该手柄在矩形的右/下侧。
(({bool on, int side}), ({bool on, int side})) _handleControl(RectHandle h) =>
    switch (h) {
      RectHandle.cornerTL => ((on: true, side: -1), (on: true, side: -1)),
      RectHandle.cornerTR => ((on: true, side: 1), (on: true, side: -1)),
      RectHandle.cornerBL => ((on: true, side: -1), (on: true, side: 1)),
      RectHandle.cornerBR => ((on: true, side: 1), (on: true, side: 1)),
      RectHandle.edgeL => ((on: true, side: -1), (on: false, side: 0)),
      RectHandle.edgeR => ((on: true, side: 1), (on: false, side: 0)),
      RectHandle.edgeT => ((on: false, side: 0), (on: true, side: -1)),
      RectHandle.edgeB => ((on: false, side: 0), (on: true, side: 1)),
    };

SelectionBox applyRectHandleDrag({
  required SelectionBox box,
  required BoxScreenBasis basis,
  required RectHandle h,
  required ui.Offset screenDelta,
  required double minHalfSize,
}) {
  final (hc, vc) = _handleControl(h);
  var out = box;
  if (hc.on) {
    // 屏幕上"往外拖"(delta 与手柄侧同号)= 该侧外扩。
    final growPx = screenDelta.dx * hc.side;
    // 受控的是局部 hAxis;该手柄对应局部面的符号 = 屏幕侧 × 轴屏幕方向符号
    final faceSign = hc.side * (basis.hSx >= 0 ? 1 : -1);
    out = _growAxis(out, basis.hAxis, faceSign, growPx / basis.scale,
        minHalfSize);
  }
  if (vc.on) {
    final growPx = screenDelta.dy * vc.side;
    final faceSign = vc.side * (basis.vSy >= 0 ? 1 : -1);
    out = _growAxis(out, basis.vAxis, faceSign, growPx / basis.scale,
        minHalfSize);
  }
  return out;
}

/// 局部轴 axis 的 faceSign 面外扩 grow(世界长度;负=收缩),对面不动。
SelectionBox _growAxis(
  SelectionBox b, int axis, int faceSign, double grow, double minHalfSize) {
  final old = _sizeOfAxis(b, axis);
  final next = math.max(old + grow, minHalfSize * 2);
  final applied = next - old;
  // 中心沿该局部面方向补偿一半(局部 → 世界用 corners 正变换)
  final t = b.yawDeg * math.pi / 180.0;
  final c = math.cos(t), s = math.sin(t);
  final shift = faceSign * applied / 2;
  double dx = 0, dy = 0, dz = 0;
  if (axis == 0) {
    dx = shift * c;
    dz = shift * s;
  } else if (axis == 1) {
    dy = shift;
  } else {
    dx = -shift * s;
    dz = shift * c;
  }
  return b.copyWith(
    cx: b.cx + dx, cy: b.cy + dy, cz: b.cz + dz,
    sx: axis == 0 ? next : b.sx,
    sy: axis == 1 ? next : b.sy,
    sz: axis == 2 ? next : b.sz,
  );
}

SelectionBox applyBoxPan({
  required SelectionBox box,
  required CloudProjection proj,
  required ui.Offset screenDelta,
  required double depth,
}) {
  final wpp = proj.worldPerPixelAt(depth);
  final r = proj.rightAxisWorld();
  final u = proj.upAxisWorld();
  return box.copyWith(
    cx: box.cx + (r[0] * screenDelta.dx + u[0] * screenDelta.dy) * wpp,
    cy: box.cy + (r[1] * screenDelta.dx + u[1] * screenDelta.dy) * wpp,
    cz: box.cz + (r[2] * screenDelta.dx + u[2] * screenDelta.dy) * wpp,
  );
}
```

⚠️ 实现者自查两处符号:
1. `applyRectHandleDrag` 的 faceSign 推导 —— "屏幕右侧手柄往右拖 = 外扩"
   是不变量;faceSign = 屏幕侧 × 局部轴屏幕方向符号,Step 1 的 edgeR 测试
   (对面不动 + 尺寸增大)就是抓它。
2. `boxScreenBasis` 的 axes 列向量必须与 `selectionBoxCorners` 的正变换
   一致(x 轴 `[c,0,s]`、z 轴 `[-s,0,c]`)—— 与 Task 1 `contains` 逆式
   互逆,别再引入第三种旋转写法。

- [ ] **Step 4: Widget 部分实现**

`SelectionCloudView`(同文件,State 内):
- 状态:`_zoom`(双指捏合 0.3–6 clamp)、`_activeHandle`(`RectHandle?`,
  onScaleStart 时 `hitRectHandle`;null 且落在矩形内 = 平移盒;矩形外 =
  无操作)。
- 相机组装:`CloudCamera(yaw: widget.viewYaw, pitch: widget.viewPitch,
  zoom: _zoom, panX: 0, panY: 0, pivot: SparseCloudPainter.fitOf(xyz) 中心,
  radius: fitOf.radius)`(fillK 默认)。
- onScaleUpdate:`pointerCount >= 2` → `_zoom` 乘增量;单指:
  `_activeHandle != null` → `applyRectHandleDrag`(basis 每次用当前投影现
  算;`minHalfSize = fit.radius × SelectionBox.kMinHalfSizeFraction`);
  否则落点在 `selectionScreenRect` 内 → `applyBoxPan(depth: 盒中心深度)`;
  结果经 `widget.onBoxChanged` 上报。
- 渲染 Stack:
  1. `CustomPaint(painter: SparseCloudPainter(..., selectionBox: widget.box,
     drawSelectionWireframe: false))` — 点云 + 框外红,**无 3D 线框**;
  2. 自绘矩形层:`selectionScreenRect` 白描边(1.4,`0xCCFFFFFF`)+ 4 角
     `drawCircle(r: 9, 白)` + 4 边中点圆角胶囊
     `RRect.fromRectAndRadius(22×8, r4)`(横边横放、竖边竖放)。
- `SparseCloudPainter` 加 `this.drawSelectionWireframe = true`,Task 3 画
  框线段包 `if (drawSelectionWireframe)`;`shouldRepaint` 补该字段。

- [ ] **Step 5: 跑测试确认通过**

Run: `flutter test test/selection_rect_math_test.dart && flutter test`
Expected: 新测试全 PASS;全量无新增失败

- [ ] **Step 6: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/selection_cloud_view.dart lib/ui/official_capture/sparse_cloud_view.dart test/selection_rect_math_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/selection_cloud_view.dart lib/ui/official_capture/sparse_cloud_view.dart test/selection_rect_math_test.dart
git commit -F <(printf 'feat(selection): RS 同款 2D 矩形手柄数学 + SelectionCloudView\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```


### Task 5: SelectionPage(朝向立方体 + 滑杆 + Ready to Process + 持久化)

**Files:**
- Create: `lib/ui/official_capture/selection_page.dart`
- Test: `test/selection_page_test.dart`

**Interfaces:**
- Consumes: Task 1 `SelectionBox.loadFrom/saveTo/initialFor`;Task 4 `SelectionCloudView`;`SparseCloudPainter.fitOf`
- Produces:
  - `class SelectionPage extends StatefulWidget { SelectionPage({required Float32List xyz, required Uint8List rgb, required String captureDir}); }`
  - pop 返回值:`'save_draft'`(左上返回)。Ready to Process 不 pop。
  - 顶层 `const List<({String label, double yaw, double pitch})> kOrientationPresets`,六项按序:Top(yaw 0, pitch −π/2)、Front(0, 0)、Right(π/2, 0)、Back(π, 0)、Left(−π/2, 0)、Bottom(0, π/2)。
- **滑杆↔相机联动约定(调研修订)**:传给 `SelectionCloudView` 的
  `viewYaw = kOrientationPresets[i].yaw + box.yawDeg·π/180`(点云随滑杆
  绕重力轴转、矩形保持屏幕对齐;Top/Bottom 下与 RS 语义完全一致,侧视角
  差异已在 spec 记录)。`viewPitch = preset.pitch`。

- [ ] **Step 1: 写失败测试**

```dart
// test/selection_page_test.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_page.dart';

Future<(Directory, Float32List, Uint8List)> _fixture() async {
  final dir = await Directory.systemTemp.createTemp('selpage');
  final xyz = Float32List.fromList([
    for (var i = 0; i < 300; i++) (i % 17) * 0.1 - 0.8,
  ]);
  final rgb = Uint8List(300);
  return (dir, xyz, rgb);
}

void main() {
  test('朝向预设表:六面 + Top 是 -90° 俯视', () {
    expect(kOrientationPresets, hasLength(6));
    expect(kOrientationPresets.first.label, 'Top');
    expect(kOrientationPresets.first.pitch, closeTo(-math.pi / 2, 1e-9));
  });

  testWidgets('返回键 pop save_draft 并已写盘', (tester) async {
    final (dir, xyz, rgb) = await _fixture();
    addTearDown(() => dir.delete(recursive: true));
    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<String>(
                MaterialPageRoute(
                  builder: (_) => SelectionPage(
                    xyz: xyz, rgb: rgb, captureDir: dir.path),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await tester.pumpAndSettle();
    expect(popped, 'save_draft');
    expect(
      File('${dir.path}/$kSelectionBoxFileName').existsSync(),
      isTrue, // 返回时兜底 flush
    );
  });

  testWidgets('Ready to Process:轻提示,不 pop', (tester) async {
    final (dir, xyz, rgb) = await _fixture();
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ready to Process'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('稠密化处理即将上线'), findsOneWidget);
    expect(find.byType(SelectionPage), findsOneWidget); // 没退出
  });

  testWidgets('已有 JSON 时恢复上次的框', (tester) async {
    final (dir, xyz, rgb) = await _fixture();
    addTearDown(() => dir.delete(recursive: true));
    const saved = SelectionBox(
      cx: 9, cy: 9, cz: 9, sx: 1, sy: 1, sz: 1, yawDeg: 45);
    await saved.saveTo(dir.path);
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await tester.pumpAndSettle();
    final page = tester.state(find.byType(SelectionPage)) as dynamic;
    expect((page.debugBox as SelectionBox).yawDeg, 45);
  });

  testWidgets('滑杆改 yawDeg,且 viewYaw 跟随(滑杆↔相机联动)', (tester) async {
    final (dir, xyz, rgb) = await _fixture();
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        home: SelectionPage(xyz: xyz, rgb: rgb, captureDir: dir.path),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();
    final page = tester.state(find.byType(SelectionPage)) as dynamic;
    final yaw = (page.debugBox as SelectionBox).yawDeg;
    expect(yaw, isNot(0));
    // 相机联动:SelectionCloudView 收到的 viewYaw 含滑杆分量
    final view = tester
        .widget<SelectionCloudView>(find.byType(SelectionCloudView));
    final preset = kOrientationPresets.first; // 初始 Top
    expect(
      view.viewYaw,
      closeTo(preset.yaw + yaw * math.pi / 180, 1e-9),
    );
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/selection_page_test.dart`
Expected: FAIL(文件不存在)

- [ ] **Step 3: 实现**

`selection_page.dart` 要点(布局参照用户提供的 RS 截图 2/3):

```dart
// selection_page.dart — RS Reconstruction Region 同款选区页。
// 返回 = flush 框 → pop('save_draft')(调用方走保存草稿链路;签决:
// 不回等待页,直接草稿列表)。Ready to Process = 稠密化占位。
// 滑杆↔相机联动:viewYaw = preset.yaw + box.yawDeg(调研修订,spec 有
// 差异记录)。
```

- State:`SelectionBox? _box`;`int _presetIdx = 0`;
  `Timer? _saveDebounce`;预设切换用 `AnimationController`(200ms)lerp
  `_animPresetYaw/_animPitch` 到 `kOrientationPresets[_presetIdx]`。
- `initState`:`SelectionBox.loadFrom(captureDir)` → null 时
  `SelectionBox.initialFor(fitOf(xyz)...)`。加载完成前中央转圈。
- `_onBoxChanged(b)`:`setState(_box = b)` + debounce 500ms
  `b.saveTo(captureDir)`(写失败 catch 静默 + `DeviceLog.log`)。
- 暴露 `@visibleForTesting SelectionBox? get debugBox => _box;`
- 返回按钮(`ValueKey('selection-back')`,左上):
  `await _flush(); Navigator.pop(context, 'save_draft');`
  (`_flush` = 取消 debounce 立即 save)。
- 朝向立方体(右上):中央方块显示当前 label,左右 `<` `>` 在四个水平面
  (Front/Right/Back/Left,索引 1..4)循环,上箭头 → Top(0)、下箭头 →
  Bottom(5)。
- 中央:`SelectionCloudView(xyz: ..., rgb: ..., box: _box!,
  onBoxChanged: _onBoxChanged,
  viewYaw: _animPresetYaw + _box!.yawDeg * math.pi / 180,
  viewPitch: _animPitch)`。
- 底部:`Rotate Point Cloud` 标签 + `Slider(min: -180, max: 180,
  value: _box!.yawDeg)` → `_onBoxChanged(_box!.copyWith(yawDeg: v))`;
  `Ready to Process` 全宽蓝底按钮 →
  `ScaffoldMessenger.showSnackBar(SnackBar(content: Text('稠密化处理即将上线')))`。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/selection_page_test.dart`
Expected: 全 PASS

- [ ] **Step 5: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/selection_page.dart test/selection_page_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/selection_page.dart test/selection_page_test.dart
git commit -F <(printf 'feat(selection): SelectionPage 朝向预设+滑杆联动+持久化+占位处理键\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```


### Task 6: 等待页双按钮 + 路由接线

**Files:**
- Modify: `lib/ui/official_capture/sfm_preview_overlay.dart`(canFinish 底部按钮区,:179-213)
- Modify: `lib/ui/official_capture/ar_capture_page.dart`(SfmPreviewOverlay 构造点 :2846 附近 + `_onSfmPreviewDone` 旁新增 `_onSfmPreviewNext`)
- Test: `test/sfm_preview_overlay_buttons_test.dart`

**Interfaces:**
- Consumes: Task 5 `SelectionPage`
- Produces: `SfmPreviewOverlay({..., required VoidCallback onDone, VoidCallback? onNext})` — `refined` 且 `onNext != null` 时渲染"保存草稿|下一步";`error` 或 `onNext == null` 保持单"完成"。

- [ ] **Step 1: 写失败测试**

```dart
// test/sfm_preview_overlay_buttons_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';

Widget _host(SfmPreviewPhase phase,
    {VoidCallback? onNext, VoidCallback? onDone}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          SfmPreviewOverlay(
            phase: phase,
            snapshot: null,
            onBack: () {},
            onDone: onDone ?? () {},
            onNext: onNext,
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('refined + onNext:保存草稿|下一步,无"完成"', (tester) async {
    var next = 0, done = 0;
    await tester.pumpWidget(_host(SfmPreviewPhase.refined,
        onNext: () => next++, onDone: () => done++));
    expect(find.text('保存草稿'), findsOneWidget);
    expect(find.text('下一步'), findsOneWidget);
    expect(find.text('完成'), findsNothing);
    await tester.tap(find.text('下一步'));
    expect(next, 1);
    await tester.tap(find.text('保存草稿'));
    expect(done, 1);
  });

  testWidgets('error:只有"完成"', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.error, onNext: () {}));
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('generating:无底部按钮', (tester) async {
    await tester.pumpWidget(_host(SfmPreviewPhase.generating, onNext: () {}));
    expect(find.text('完成'), findsNothing);
    expect(find.text('下一步'), findsNothing);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sfm_preview_overlay_buttons_test.dart`
Expected: FAIL(`onNext` 参数不存在)

- [ ] **Step 3: 实现 overlay 改动**

`sfm_preview_overlay.dart`:构造加 `this.onNext`(`final VoidCallback? onNext;`);`if (canFinish)` 的按钮区改为:

```dart
            if (canFinish)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    // refined 且有下一步入口 → RS 同款双按钮;error(没云
                    // 没得选)或调用方未接选区 → 保持单"完成"。
                    child: phase == SfmPreviewPhase.refined && onNext != null
                        ? Row(
                            children: [
                              Expanded(
                                child: _bottomButton(
                                  label: '保存草稿',
                                  filled: false,
                                  onTap: onDone,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: _bottomButton(
                                  label: '下一步',
                                  filled: true,
                                  onTap: onNext!,
                                ),
                              ),
                            ],
                          )
                        : Center(
                            child: _bottomButton(
                              label: '完成',
                              filled: true,
                              onTap: onDone,
                            ),
                          ),
                  ),
                ),
              ),
```

新增私有构建方法:

```dart
  Widget _bottomButton({
    required String label,
    required bool filled,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled ? Colors.white : const Color(0xFF2A2A2E),
          borderRadius: BorderRadius.circular(26),
          border: filled ? null : Border.all(color: Colors.white24),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: filled ? Colors.black : Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
```

- [ ] **Step 4: ar_capture_page 接线**

`ar_capture_page.dart` 的 `SfmPreviewOverlay(...)` 构造点加 `onNext: _sfmSnapshot != null ? _onSfmPreviewNext : null,`;`_onSfmPreviewDone` 旁新增:

```dart
  /// [选区 2026-07-27] 等待页"下一步"→ 选区页。返回 'save_draft'(签决:
  /// 选区页返回不回等待页)→ 走与"保存草稿"完全同一的退出链路。
  Future<void> _onSfmPreviewNext() async {
    if (_sfmPhase != SfmPreviewPhase.refined) return;
    final snap = _sfmSnapshot;
    final dir = _session?.captureDir;
    if (snap == null || dir == null || snap.pointCount == 0) return;
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => SelectionPage(
          xyz: snap.xyz,
          rgb: snap.rgb,
          captureDir: dir,
        ),
      ),
    );
    if (result == 'save_draft') await _onSfmPreviewDone();
  }
```

import 加 `import 'selection_page.dart';`。
(实现者核对:`SfmLiveSnapshot` 的字段名 `xyz/rgb/pointCount`、`_session?.captureDir` 均已在该文件使用,照抄现场。)

- [ ] **Step 5: 跑测试**

Run: `flutter test test/sfm_preview_overlay_buttons_test.dart && flutter test`
Expected: 新测试 PASS;全量无新增失败(⚠️ 若有契约测试断言"完成"按钮文案,按其注释意图更新断言而非删除)

- [ ] **Step 6: format + analyze + 提交**

```bash
dart format lib/ui/official_capture/sfm_preview_overlay.dart lib/ui/official_capture/ar_capture_page.dart test/sfm_preview_overlay_buttons_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/sfm_preview_overlay.dart lib/ui/official_capture/ar_capture_page.dart test/sfm_preview_overlay_buttons_test.dart
git commit -F <(printf 'feat(selection): 等待页 refined 双按钮(保存草稿|下一步)+ 选区页路由\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
```

---

### Task 7: 草稿查看器只读回显

**Files:**
- Modify: `lib/ui/official_capture/sparse_cloud_viewer_page.dart`
- Test: `test/sparse_cloud_viewer_selection_test.dart`

**Interfaces:**
- Consumes: Task 1 `SelectionBox.loadFrom`;Task 3 `SparseCloudView.selectionBox`
- 关键事实:captureDir = `File(widget.plyPath).parent.path`(PLY 在采集目录根)。

- [ ] **Step 1: 写失败测试**

```dart
// test/sparse_cloud_viewer_selection_test.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

/// 写一个最小合法 PLY(2 点)。
Future<String> _writePly(Directory dir) async {
  final head =
      'ply\nformat binary_little_endian 1.0\nelement vertex 2\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final body = BytesBuilder();
  for (final p in [
    [0.0, 0.0, 0.0],
    [1.0, 1.0, 1.0],
  ]) {
    final bd = ByteData(15);
    bd.setFloat32(0, p[0], Endian.little);
    bd.setFloat32(4, p[1], Endian.little);
    bd.setFloat32(8, p[2], Endian.little);
    bd.setUint8(12, 10);
    body.add(bd.buffer.asUint8List());
  }
  final f = File('${dir.path}/official_sfm_sparse.ply');
  await f.writeAsBytes([...head.codeUnits, ...body.toBytes()]);
  return f.path;
}

void main() {
  testWidgets('有 JSON:SparseCloudView 收到 selectionBox', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer');
    addTearDown(() => dir.delete(recursive: true));
    final ply = await _writePly(dir);
    const box = SelectionBox(
      cx: 0, cy: 0, cz: 0, sx: 1, sy: 1, sz: 1, yawDeg: 10);
    await box.saveTo(dir.path);
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNotNull);
    expect(view.selectionBox!.yawDeg, 10);
  });

  testWidgets('无 JSON:selectionBox 为 null,页面正常', (tester) async {
    final dir = await Directory.systemTemp.createTemp('viewer2');
    addTearDown(() => dir.delete(recursive: true));
    final ply = await _writePly(dir);
    await tester.pumpWidget(
      MaterialApp(home: SparseCloudViewerPage(plyPath: ply)),
    );
    await tester.pumpAndSettle();
    final view = tester.widget<SparseCloudView>(find.byType(SparseCloudView));
    expect(view.selectionBox, isNull);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/sparse_cloud_viewer_selection_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

`sparse_cloud_viewer_page.dart`:State 加 `SelectionBox? _selectionBox;`;`_load()` 里 PLY 加载后追加:

```dart
    // [选区 2026-07-27] 只读回显:有选区文件就显示框 + 框外红。
    // 损坏/缺失 → null(loadFrom 内部容错),查看器照常全量显示。
    final selBox =
        await SelectionBox.loadFrom(File(widget.plyPath).parent.path);
```

`setState` 里 `_selectionBox = selBox;`,`SparseCloudView(xyz: ..., rgb: ..., selectionBox: _selectionBox)`。import 两行。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/sparse_cloud_viewer_selection_test.dart && flutter test`
Expected: 全 PASS / 无新增失败

- [ ] **Step 5: format + analyze + 提交 + 真机验证**

```bash
dart format lib/ui/official_capture/sparse_cloud_viewer_page.dart test/sparse_cloud_viewer_selection_test.dart
flutter analyze lib/ test/
git add lib/ui/official_capture/sparse_cloud_viewer_page.dart test/sparse_cloud_viewer_selection_test.dart
git commit -F <(printf 'feat(selection): 草稿查看器只读回显选区框\n\nCo-Authored-By: Claude Fable 5 <noreply@anthropic.com>\n') </dev/null
# 真机(纯 Dart 改动,无需 rebuild_native):
flutter build ios --release
xcrun devicectl device install app --device 1B290474-D354-5B4C-AAB0-0805AC5DC832 build/ios/iphoneos/Runner.app --timeout 600
```

真机手测清单(用户执行,拔线安全):拍 20+ 张 → refined → 双按钮 → 下一步 → 切六面朝向 / 拖角与边手柄 / 滑杆旋转、框外变红 → Ready to Process 出提示不退出 → 返回落草稿列表 → 草稿"查看点云"看到框 + 红点、点数不变(全量)。
