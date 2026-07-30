// [2026-07-27 controller 修订] testWidgets 体默认跑在 FakeAsync zone;
// SparseCloudViewerPage._load() 里的 compute() + SelectionBox.loadFrom 都是
// 真实 dart:io/isolate Future,在 FakeAsync 里不会自己完成 —— 必须用
// tester.runAsync 切回真实事件循环让它落地,再 tester.pump() 消化随之而来
// 的 setState。brief 原始测试代码没处理这点,会在 pumpAndSettle 上死等
// (Step 1 新增用例实测复现:第 3 个用例挂满 10 分钟框架超时才炸)。
//
// 根因排查(2026-07-27):挂死不是 helper 本身(helper 恒有界),是新增
// 用例把 `Directory.systemTemp.createTemp(...)` 写成裸 `await`、留在
// tester.runAsync(...) 外面 —— testWidgets 默认在 FakeAsync zone 里跑,
// 裸 await 一个真实 dart:io Future 永远等不到它完成(FakeAsync 不会驱动
// 真实事件循环),于是死等到框架 10 分钟超时。本文件前两个既有用例、
// 以及 test/selection_page_test.dart 的用例全部把「所有」真实 IO(含
// createTemp 本身)包进 tester.runAsync —— 新增四个用例已改成同一模式。
// [2026-07-28 用户签决] 浏览与编辑是同一个页面 —— 本文件守门这件事:
// 点"下一步"前后 SparseCloudView 必须是**同一个 State 实例**(相机不重建
// ⇒ 角度/位置/缩放天然连续),工具层只是叠上来。
// helper 原型见旧 selection_page_test 的 _pumpUntilRealAsyncSettles
// (done 谓词版:超时会 fail 带诊断,不会像"跑满轮直接返回"那样掩盖真实
// 卡死)。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/ruler_scrubber.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_rect_handles.dart';
import 'package:pocketworld_flutter/ui/official_capture/selection_tools_layer.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/view_cube.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

/// 反复 runAsync(短真实延时)+pump,直到 [done] 为真;超时 fail 带诊断,
/// 绝不无限挂死。
Future<void> _pumpUntilRealAsyncSettles(
  WidgetTester tester,
  bool Function() done, {
  int maxIters = 40,
  Duration step = const Duration(milliseconds: 20),
}) async {
  for (var i = 0; i < maxIters; i++) {
    if (done()) return;
    await tester.runAsync(() => Future<void>.delayed(step));
    // ⚠️ pump 必须带 duration:等"路由退场/入场"这类谓词时,无参 pump()
    // 不推进动画时钟 —— pop 已发生但页面永远不从树上移除,谓词恒假超时
    // (实测踩过)。50ms/轮 × 40 轮足够覆盖 300ms 转场。
    await tester.pump(const Duration(milliseconds: 50));
  }
  fail('真实 IO 延续在超时前未落地(done() 恒 false)');
}

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

/// 环向最短角差(±π 是同一个角,不能直接相减)。
double _angDiff(double a, double b) {
  var d = (a - b).remainder(2 * math.pi);
  if (d > math.pi) d -= 2 * math.pi;
  if (d < -math.pi) d += 2 * math.pi;
  return d;
}

double _rotDev(SelectionBox b) {
  var d = 0.0;
  for (var i = 0; i < 9; i++) {
    d += (b.rot[i] - kIdentityRot[i]).abs();
  }
  return d;
}

void main() {
  Future<(Directory, String)> fixture(WidgetTester tester) async {
    late Directory dir;
    late String ply;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer_edit');
      ply = await _writePly(dir);
    });
    return (dir, ply);
  }

  Future<void> openViewer(WidgetTester tester, String ply) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: SparseCloudViewerPage(plyPath: ply),
      ),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('Next').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  }

  SelectionBox? boxOf(WidgetTester tester) =>
      tester.widget<SparseCloudView>(find.byType(SparseCloudView)).selectionBox;

  testWidgets('下一步 = 工具层叠上来,点云视图仍是同一个 State(零重建)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);

    final before = tester.state(find.byType(SparseCloudView));
    final rectBefore = tester.getRect(find.byType(SparseCloudView));
    expect(find.byType(SelectionToolsLayer), findsNothing);

    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // 核心断言:同一个 State 实例 ⇒ 相机(yaw/pitch/zoom/pan/pivot)原地
    // 未动,不存在"两个画面"之间的跳变。
    expect(
      identical(tester.state(find.byType(SparseCloudView)), before),
      isTrue,
    );
    // 视图矩形逐像素不变 —— 编辑态曾隐藏 AppBar 导致 body 变高、点云整体
    // 上移(用户实机指认"整个点云的位置应该完全不变")。UI 只能叠加。
    expect(tester.getRect(find.byType(SparseCloudView)), rectBefore);
    // 编辑态必须画出 2D 矩形手柄(painter 参数曾漏接,框整个不见)。
    expect(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is RectHandlesPainter,
      ),
      findsOneWidget,
    );
    expect(find.byType(SelectionToolsLayer), findsOneWidget);
    expect(find.byType(ViewCube), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(boxOf(tester), isNotNull);

    // 返回浏览态:同样不重建视图。
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byType(SparseCloudView)), before),
      isTrue,
    );
    expect(tester.getRect(find.byType(SparseCloudView)), rectBefore);
    expect(find.text('Next'), findsOneWidget);
    expect(boxOf(tester), isNull); // 浏览态不显示框
  });

  testWidgets('编辑态:单指一律转视角,框只由手柄改动', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(SparseCloudView));
    double cubeYaw() => tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;

    // 盒外(左上角)拖 → 转视角,盒不动。
    final yaw0 = cubeYaw();
    final box0 = boxOf(tester)!;
    await tester.dragFrom(
      rect.topLeft + const Offset(6, 6),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    expect(cubeYaw(), isNot(closeTo(yaw0, 1e-6)));
    expect(boxOf(tester)!.cx, closeTo(box0.cx, 1e-12));

    // [2026-07-29] 单指整体平移框已按用户签决删除 ⇒ 框内空白拖动同样是转
    // 视角,框纹丝不动(只有拖手柄才改框)。
    final yawMid = cubeYaw();
    await tester.dragFrom(
      rect.center + const Offset(0, 60),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    expect(cubeYaw(), isNot(closeTo(yawMid, 1e-6)), reason: '框内拖动应转视角');
    expect(boxOf(tester)!.cx, closeTo(box0.cx, 1e-12), reason: '框被平移了');
    expect(boxOf(tester)!.cz, closeTo(box0.cz, 1e-12));
  });

  testWidgets('拖动骰子 = 点云跟着转,松手有惯性', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    double cubeYaw() => tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;
    // 点云视角与骰子同源(骰子读的就是相机 yaw),断言骰子即断言点云。
    final before = cubeYaw();
    final cube = find.byType(ViewCube);
    // [2026-07-28 用户签决] 立方体可自由拖动,点云跟着转,阻力要小:
    // 30px 拖动应转出 ≥0.3 rad(灵敏度 0.02 rad/px,扣掉手势 slop)。
    await tester.drag(cube, const Offset(-30, 0));
    await tester.pumpAndSettle();
    final afterDrag = cubeYaw();
    expect((afterDrag - before).abs(), greaterThan(0.3));

    // 甩动后松手继续滑行(惯性)。
    await tester.fling(cube, const Offset(-40, 0), 1000);
    await tester.pump();
    final atRelease = cubeYaw();
    await tester.pump(const Duration(milliseconds: 60));
    expect((cubeYaw() - atRelease).abs(), greaterThan(0.01));
    await tester.pumpAndSettle();
  });

  testWidgets('点击骰子的面 = 该面转到正对', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    // 先转到一个歪视角,再点骰子。
    final rect = tester.getRect(find.byType(SparseCloudView));
    await tester.dragFrom(
      rect.topLeft + const Offset(6, 6),
      const Offset(40, 25),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final cube = tester.widget<ViewCube>(find.byType(ViewCube));
    final target = primaryViewCubeFace(cube.viewYaw, cube.viewPitch);
    await tester.tapAt(tester.getCenter(find.byType(ViewCube)));
    await tester.pumpAndSettle();

    final after = tester.widget<ViewCube>(find.byType(ViewCube));
    final preset = kOrientationPresets.firstWhere((p) => p.label == target);
    expect(after.viewPitch, closeTo(preset.pitch, 1e-6));
    expect(primaryViewCubeFace(after.viewYaw, after.viewPitch), target);
  });

  testWidgets('滑轨拨出去再拨回初始刻度:框朝向精确复原', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    final before = [...rot()];
    // [2026-07-29 用户实机指认"每次拨回初始刻度角度都不一样"] 转轴此前每次
    // 都拿被转过的框重算,增量不可逆。锁轴后来回等量拨动必须精确抵消。
    final ruler = find.byType(RulerScrubber);
    await tester.drag(ruler, const Offset(-60, 0));
    await tester.pumpAndSettle();
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (rot()[i] - before[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '先要真的转出去');

    await tester.drag(ruler, const Offset(60, 0));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(rot()[i], closeTo(before[i], 1e-9), reason: '回到 0 刻度必须复原');
    }
  });

  testWidgets('连拨一整圈(360°)回到黄色刻度:框朝向精确复原', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    final before = [...rot()];
    // [2026-07-29 用户实机指认"转完一圈还是无法回到原点"] 一圈 = 396px
    // (1.1 px/度)。分 4 段拨完,中途框会转过很多角度 —— 转轴绝不能因此
    // 被重算,否则每段绕的是不同的轴,累计不闭合。
    // 慢速匀速拨(19.8 px/s < 甩动阈值),避免惯性多转一截让"整圈"失准。
    final ruler = find.byType(RulerScrubber);
    final g = await tester.startGesture(tester.getCenter(ruler));
    for (var i = 0; i < 50; i++) {
      await g.moveBy(const Offset(-7.92, 0));
      await tester.pump(const Duration(milliseconds: 400));
    }
    await g.up();
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(rot()[i], closeTo(before[i], 1e-6), reason: '整圈必须闭合');
    }
  });

  testWidgets('拨滑轨 = 点云转、框在屏幕上不动、画面永不歪', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    ViewCube cube() => tester.widget<ViewCube>(find.byType(ViewCube));
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    final poseY = cube().viewYaw, poseP = cube().viewPitch;
    final poseR = cube().viewRoll;
    final rot0 = [...box().rot];
    await tester.drag(find.byType(RulerScrubber), const Offset(-70, 0));
    await tester.pumpAndSettle();

    // ① [2026-07-29 横轴翻滚] 框相对点云翻了 ⇒ 框朝向整体偏离基准。
    var dev = 0.0;
    for (var i = 0; i < 9; i++) {
      dev += (box().rot[i] - rot0[i]).abs();
    }
    expect(dev, greaterThan(0.1), reason: '点云没翻');
    // ② 骰子 = 框相对相机的姿态 ⇒ 框在屏幕上不动,骰子 pose 三分量都不动。
    // ±π 是同一个角,用环向最短差比较。
    expect(
      _angDiff(cube().viewYaw, poseY).abs(),
      lessThan(1e-6),
      reason: '框在屏幕上动了(yaw)',
    );
    expect(
      _angDiff(cube().viewPitch, poseP).abs(),
      lessThan(1e-6),
      reason: '框动了(pitch)',
    );
    expect(
      _angDiff(cube().viewRoll, poseR).abs(),
      lessThan(1e-6),
      reason: '框动了(roll)',
    );
  });

  testWidgets('点击骰子任一面:框与立方体同步正对(极面也不歪)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    ViewCube cube() => tester.widget<ViewCube>(find.byType(ViewCube));

    // 初始正俯视,正对面 = Top。拨歪(横轴翻滚)后点当前正对面归位,
    // 归位后该面应重新精确正对相机(primaryViewCubeFace 稳定)。
    expect(cube().viewPitch.abs(), greaterThan(1.2), reason: '初始应为正俯视');
    final target = primaryViewCubeFace(cube().viewYaw, cube().viewPitch);
    await tester.drag(find.byType(RulerScrubber), const Offset(-37, 0));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(find.byType(ViewCube)));
    await tester.pumpAndSettle();
    expect(
      primaryViewCubeFace(cube().viewYaw, cube().viewPitch),
      target,
      reason: '归位后该面未正对',
    );
  });

  testWidgets('滑轨方向 = 垂直翻滚(俯仰),不是水平自转', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    // [2026-07-29 用户签决] "滑轨应该让点云垂直方向旋转,而不是水平方向"。
    // 判据取框的**局部 +Y 轴**(rot 第 1 列)在世界中的走向:
    //   · 绕竖直轴自转(旧行为)⇒ +Y 始终指向世界 +Y,竖直分量不变;
    //   · 绕横轴翻滚(新行为)⇒ +Y 被扳倒,竖直分量显著减小。
    double upY() => box().rot[4]; // rot[3..5] 是第 1 列 → [4] 是它的 y 分量
    expect(upY().abs(), closeTo(1.0, 1e-9), reason: '初始框应轴对齐');
    await tester.drag(find.byType(RulerScrubber), const Offset(-70, 0));
    await tester.pumpAndSettle();
    expect(upY().abs(), lessThan(0.9), reason: '框的竖直轴没被扳倒 ⇒ 还是水平自转,不是垂直翻滚');
  });

  testWidgets('连续拨动不会中途把点云重置回初始角度', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    List<double> rot() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!
        .rot;

    // [2026-07-29 用户实机指认"开始调节时点云自动重置到初始角度"] 根因是
    // moveTo 同步回调把基准重新烘焙、读数归零。慢速连续拨动,框的朝向必须
    // 单调累积,不能中途跳回。
    final ruler = find.byType(RulerScrubber);
    final g = await tester.startGesture(tester.getCenter(ruler));
    var lastDev = 0.0;
    for (var i = 0; i < 12; i++) {
      await g.moveBy(const Offset(-6, 0));
      await tester.pump(const Duration(milliseconds: 400));
      var dev = 0.0;
      for (var k = 0; k < 9; k++) {
        dev += (rot()[k] - kIdentityRot[k]).abs();
      }
      // 单调不减(容差留给浮点);任何一次归零都说明被重置了。
      expect(dev, greaterThanOrEqualTo(lastDev - 1e-9), reason: '第 $i 步被重置');
      lastDev = dev;
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(lastDev, greaterThan(0.05), reason: '整段拨动应累积出可观的旋转');
  });

  testWidgets('⋯ 菜单:回到初始旋转角度 / 回到初始点云大小', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    // 先把框转歪(拨滑轨),再用菜单还原。
    await tester.drag(find.byType(RulerScrubber), const Offset(-70, 0));
    await tester.pumpAndSettle();
    // 注意:转轴 = 当前正对面的法向,默认视角正对 Front ⇒ 绕世界 Z 转,
    // 绕 Y 的分量(yawDeg)并不会变 —— 断言矩阵整体偏离单位阵才对。
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (box().rot[i] - kIdentityRot[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '滑轨应已转动框');

    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    expect(find.text('Reset Rotation'), findsOneWidget);
    expect(find.text('Reset Zoom'), findsOneWidget);
    expect(find.text('Reset Box Size'), findsOneWidget);
    await tester.tap(find.text('Reset Rotation'));
    await tester.pumpAndSettle();
    // 朝向回到轴对齐(单位阵),尺寸不动。
    for (var i = 0; i < 9; i++) {
      expect(box().rot[i], closeTo(kIdentityRot[i], 1e-12));
    }

    // 缩放:菜单还原到默认取景(不崩、工具层仍在即达标 —— 相机重置的
    // 数值语义由 SparseCloudView 的 reframe 自身负责)。
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Zoom'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectionToolsLayer), findsOneWidget);

    // 恢复原始框大小:先拨滑轨改朝向,再复位 —— 框必须回到按点云重算的初始
    // 框(朝向为轴对齐、尺寸等于场景包围盒)。
    await tester.drag(find.byType(RulerScrubber), const Offset(-50, 0));
    await tester.pumpAndSettle();
    expect(_rotDev(box()), greaterThan(0.1), reason: '先要真的拨歪');
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Box Size'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(box().rot[i], closeTo(kIdentityRot[i], 1e-12));
    }
  });

  testWidgets('⋯ 菜单展开时:仍能拨刻度 / 转立方体 / 转点云', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    ViewCube cube() => tester.widget<ViewCube>(find.byType(ViewCube));
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    // 展开菜单(自绘浮层,**不带遮罩**)。
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    expect(find.text('Reset Rotation'), findsOneWidget);

    // [2026-07-29 用户签决] 菜单展开时底下照常可操作 —— PopupMenuButton 的
    // 全屏 ModalBarrier 会把这些手势全吞掉,故改自绘浮层。
    final dev0 = _rotDev(box());
    await tester.drag(find.byType(RulerScrubber), const Offset(-45, 0));
    await tester.pumpAndSettle();
    expect((_rotDev(box()) - dev0).abs(), greaterThan(0.1), reason: '菜单挡住了刻度');

    final cubeYaw0 = cube().viewYaw;
    await tester.drag(find.byType(ViewCube), const Offset(-30, 0));
    await tester.pumpAndSettle();
    expect(
      (cube().viewYaw - cubeYaw0).abs(),
      greaterThan(0.1),
      reason: '菜单挡住了立方体拖动',
    );

    // 菜单仍然开着(自绘浮层不会因为下层手势自动收起)。
    expect(find.text('Reset Rotation'), findsOneWidget);
  });

  testWidgets('加载失败:无编辑入口', (tester) async {
    late Directory dir;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('viewer_fail');
    });
    addTearDown(() => dir.delete(recursive: true));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: SparseCloudViewerPage(plyPath: '${dir.path}/nope.ply'),
      ),
    );
    await tester.pump();
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.text('Failed to load point cloud').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('Next'), findsNothing);
  });
  // ── [2026-07-30 实机定罪] 斜朝向存档:进编辑必须把相机对齐到框 ────────
  //
  // 手机草稿实测 rot 带 yawDeg=-41.2°(滑轨转框留下的**合法**朝向:滑轨
  // 语义就是"刻度转一圈点云转 360°",转半圈框相对场景自然是歪的)。滑轨
  // 转动期间相机与框同步转、相对姿态恒为正对,所以骰子不歪、矩形贴合;
  // 破裂只发生在**重开草稿**:框朝向落了盘,当时的视角没落盘 ⇒ 框歪 41°
  // 而相机是默认俯视,相对姿态歪 41° ⇒ 骰子被画成菱形(用户实机指认
  // "立方体没有水平放置")。修法 = 进编辑时对齐到最近主面一次。
  testWidgets('斜朝向存档(yawDeg=-41.2°)进编辑:骰子回正(相对姿态落在 90° 倍数)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await tester.runAsync(
      () => File('${dir.path}/official_selection_box.json').writeAsString(
        '{"v":2,"cx":0.0,"cy":0.0,"cz":0.0,'
        '"sx":3.4273421857647204,"sy":2.9928319280554696,'
        '"sz":3.9394953630036667,'
        '"rot":[0.7522755429705815,0.0,0.6588486225593229,'
        '0.0,1.0,0.0,'
        '-0.6588486225593229,0.0,0.7522755429705815],'
        '"yawDeg":-41.21212121212105}',
      ),
    );
    await openViewer(tester, ply);

    await tester.tap(find.text('Next'));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // 存档确实是斜的(否则本用例什么都没测到)。
    final box = boxOf(tester)!;
    expect(_rotDev(box), greaterThan(0.5), reason: '存档框应带 41° 朝向');

    // 骰子读的是"框相对相机"的姿态:立方体正着放 ⟺ 三分量都落在 90° 倍数。
    final cube = tester.widget<ViewCube>(
      find.byKey(const ValueKey('view-cube')),
    );
    for (final (name, v) in [
      ('yaw', cube.viewYaw),
      ('pitch', cube.viewPitch),
      ('roll', cube.viewRoll),
    ]) {
      final q = v / (math.pi / 2);
      expect(
        (q - q.roundToDouble()).abs(),
        lessThan(0.02),
        reason: '骰子 $name=${v * 180 / math.pi}° 不是 90° 的整数倍(立方体歪着)',
      );
    }
  });
}
