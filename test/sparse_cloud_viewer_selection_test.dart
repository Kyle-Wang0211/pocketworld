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
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
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

/// 拨滑轨 [deg] 度所需的水平拖动像素。
///
/// [2026-08-07] 密度不再是常量,而是由弧半径导出(rulerPxPerDeg)。此前测试里
/// 写死 -45/-60/-70px 隐含了旧密度 1.1pt/度;密度提到 ≈8.9 后同样的像素只转 5°,
/// 两条断言"偏离 > 0.1"当场变红。改成按**意图**(转多少度)表达。
Future<void> _dragRulerDeg(WidgetTester tester, double deg) async {
  final r = find.byType(RulerScrubber);
  final px = deg * rulerPxPerDeg(tester.getRect(r).width);
  await tester.drag(r, Offset(-px, 0));
  await tester.pumpAndSettle();
}

/// 浏览态当前 pitch —— initialCamera 为 null 时从视图 State 读。
double _browsePitchOf(WidgetTester tester) =>
    ((tester.state(find.byType(SparseCloudView)) as dynamic).debugPitch
        as double);

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
      () => find
          .byKey(const ValueKey('viewer-enter-editing'))
          .evaluate()
          .isNotEmpty,
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

    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    // [2026-07-31] 底部"下一步"已改作启动后续处理;进编辑的入口是右上角那个。
    expect(find.byKey(const ValueKey('viewer-enter-editing')), findsNothing);
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
    expect(find.byKey(const ValueKey('viewer-enter-editing')), findsOneWidget);
    // [2026-08-03 语义更新] 原断言是"一个手柄都没碰过 ⇒ 不算用了选区,浏览态
    // 交回原始点云"。用户随后签决"用户第一次点进来,点云其实就已经是被编辑的
    // 状态了(初始的框就已经算编辑了)" ⇒ 点了**"完成"**就是把当前框(哪怕没
    // 碰过的初始框)确立为选区,浏览态按它裁剪。
    // "未进入编辑页面之前展示原始点云"那条依然成立,由**取消**那一侧和从未进
    // 过编辑的路径守(见「选区 = 可选动作」group)。
    expect(boxOf(tester), isNotNull, reason: '点了"完成"却没把选区应用到浏览态');
    expect(
      tester.widget<SparseCloudView>(find.byType(SparseCloudView)).editing,
      isFalse,
    );
  });

  testWidgets('编辑态:单指一律不转视角,框只由手柄改动', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(SparseCloudView));
    double cubeYaw() => tester.widget<ViewCube>(find.byType(ViewCube)).viewYaw;

    // [2026-07-30 语义反转,不是回归] 原用例断言"单指一律**转**视角"。用户
    // 签决"完全复刻 RS,点云只能固定六个面动"后,编辑态没有自由 orbit ——
    // 换面只能走骰子的四个箭头或点骰子的面(见 group「RS 六面机制」)。
    // "框只由手柄改动"这半条不变,继续守。
    final yaw0 = cubeYaw();
    final box0 = boxOf(tester)!;
    await tester.dragFrom(
      rect.topLeft + const Offset(6, 6),
      const Offset(70, 0),
    );
    await tester.pumpAndSettle();
    expect(cubeYaw(), closeTo(yaw0, 1e-9), reason: '盒外单指拖动转了视角');
    expect(boxOf(tester)!.cx, closeTo(box0.cx, 1e-12));

    await tester.dragFrom(
      rect.center + const Offset(0, 60),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    expect(cubeYaw(), closeTo(yaw0, 1e-9), reason: '框内单指拖动转了视角');
    expect(boxOf(tester)!.cx, closeTo(box0.cx, 1e-12), reason: '框被平移了');
    expect(boxOf(tester)!.cz, closeTo(box0.cz, 1e-12));
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
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await _dragRulerDeg(tester, 55);
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (rot()[i] - before[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '先要真的转出去');

    await _dragRulerDeg(tester, -55); // 同角度回拨 ⇒ 读数归 0
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(rot()[i], closeTo(before[i], 1e-9), reason: '回到 0 刻度必须复原');
    }
  });

  testWidgets('连拨一整圈(360°)回到黄色刻度:框朝向精确复原', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    // [2026-07-29 用户实机指认"转完一圈还是无法回到原点"] 分 50 小段拨满一圈,
    // 中途框会转过很多角度 —— 转轴绝不能因此被重算,否则每段绕的是不同的轴,
    // 累计不闭合。慢速匀速拨(< 甩动阈值),避免惯性多转一截让"整圈"失准。
    // 一圈的像素宽从 rulerPxPerDeg(宽) 算,不硬编码(2026-08-03 灵敏度 1.1→0.75
    // 时这里漏改过一次,红在"整圈必须闭合")。
    final fullTurnPx =
        360.0 * rulerPxPerDeg(tester.getRect(find.byType(RulerScrubber)).width);
    final step = fullTurnPx / 50;
    final ruler = find.byType(RulerScrubber);
    final g = await tester.startGesture(tester.getCenter(ruler));
    for (var i = 0; i < 50; i++) {
      await g.moveBy(Offset(-step, 0));
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
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await _dragRulerDeg(tester, 60);

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
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await _dragRulerDeg(tester, 34);
    await tester.tapAt(tester.getCenter(find.byType(ViewCube)));
    await tester.pumpAndSettle();
    expect(
      primaryViewCubeFace(cube().viewYaw, cube().viewPitch),
      target,
      reason: '归位后该面未正对',
    );
  });

  testWidgets('滑轨方向 = 钟表指针(绕视线轴的屏幕内旋转)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    CloudViewCamera camOf() => tester
        .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
        .camera
        .value!;
    ViewCube cube() =>
        tester.widget<ViewCube>(find.byKey(const ValueKey('view-cube')));

    // [2026-07-30 用户签决] "就跟钟表一样,指针一样" —— 点云在屏幕平面内原地
    // 打转,转轴 = **视线轴**,任何视角下都是钟表。上一版绕横轴翻滚(顶视翻
    // 成侧视)与更早的绕世界竖直轴自转都被实机否决;后者只在顶/底视角碰巧
    // 是钟表效果,侧视角就退化成水平自转(用户原话"现在只有顶部和底部是
    // 垂直方向")。
    //
    // 判据取相机相对基准的旋转 M_now · M_baseᵀ:钟表 ⇒ 它必须是绕相机系 z
    // (视线)的 Rz —— 第 3 行/列恒为 (0,0,1);绕横轴翻滚会变成 Rx(第 1 行
    // 才是不动的那一行),绕竖直轴自转在非极视角下也不是纯 Rz。
    final c0 = camOf();
    final base = composeViewMatrix(c0.yaw, c0.pitch, c0.roll);
    final cubeBefore = cube();

    await _dragRulerDeg(tester, 60);

    final c1 = camOf();
    final now = composeViewMatrix(c1.yaw, c1.pitch, c1.roll);
    // rel = now · baseᵀ
    final rel = List<double>.filled(9, 0);
    for (var i = 0; i < 3; i++) {
      for (var j = 0; j < 3; j++) {
        var acc = 0.0;
        for (var k = 0; k < 3; k++) {
          acc += now[i * 3 + k] * base[j * 3 + k];
        }
        rel[i * 3 + j] = acc;
      }
    }
    // 必须确实转了(否则用例什么都没测到)。注意不能用 rel[0]:横轴翻滚
    // (Rx)下它恒为 1 —— 那正是被否决行为的指纹,不是"没转"。
    var dev = 0.0;
    for (var k = 0; k < 9; k++) {
      dev += (rel[k] - kIdentityRot[k]).abs();
    }
    expect(dev, greaterThan(0.1), reason: '滑轨没让相机动');
    // Rz:视线轴是旋转轴 ⇒ 第 3 行、第 3 列都是 (0,0,1)。
    expect(rel[8], closeTo(1.0, 1e-6), reason: '转轴不是视线轴 ⇒ 不是钟表旋转');
    expect(rel[2], closeTo(0.0, 1e-6), reason: '转轴不是视线轴');
    expect(rel[5], closeTo(0.0, 1e-6), reason: '转轴不是视线轴');
    expect(rel[6], closeTo(0.0, 1e-6), reason: '转轴不是视线轴');
    expect(rel[7], closeTo(0.0, 1e-6), reason: '转轴不是视线轴');

    // 相机与框同步转 ⇒ 相对姿态不变 ⇒ 骰子纹丝不动、永远正着放。
    expect(cube().viewYaw, closeTo(cubeBefore.viewYaw, 1e-6));
    expect(cube().viewPitch, closeTo(cubeBefore.viewPitch, 1e-6));
    expect(cube().viewRoll, closeTo(cubeBefore.viewRoll, 1e-6));
  });

  testWidgets('拨完滑轨再手动转视角:滚转不被清零(否则框与骰子当场失配)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    CloudViewCamera camOf() => tester
        .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
        .camera
        .value!;

    // 钟表旋转把角度存在**相机 roll** 里(框绕视线反转同角度抵消)。旧
    // _applyPose 为"手动 orbit 不带滚转"把 roll 硬写 0 —— 手动转一下视角就
    // 把滑轨的成果清掉,而框的朝向留着,框与骰子当场歪掉。
    await _dragRulerDeg(tester, 60);
    final rolled = camOf().roll;
    expect(rolled.abs(), greaterThan(0.05), reason: '滑轨应产生滚转');

    // 手动拖**骰子** orbit —— 走 _applyPose 的就是这条路径(点云自身的
    // orbit 在 SparseCloudView 内部,不经过它)。
    await tester.drag(
      find.byKey(const ValueKey('view-cube')),
      const Offset(30, 0),
    );
    await tester.pumpAndSettle();
    expect(camOf().roll.abs(), greaterThan(0.05), reason: '手动 orbit 把滑轨的滚转清零了');
  });

  testWidgets('进编辑的初始视角 = 重力正上方的"顶",框朝向一并复位', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    // 实机草稿实测的框:带 41.2° 水平朝向 **且** 61° 俯仰(俯仰是被否决的
    // "横轴翻滚"那版拨出来落盘的)。
    await tester.runAsync(
      () => File('${dir.path}/official_selection_box.json').writeAsString(
        '{"v":2,"cx":-0.1376,"cy":-0.1533,"cz":2.2362,'
        '"sx":3.4273421857647204,"sy":2.9928319280554696,'
        '"sz":3.9394953630036667,'
        '"rot":[0.7522755429705815,0.5757,0.3203,'
        '-0.0,0.4862,-0.8738,'
        '-0.6588486225593229,0.6574,0.3658],'
        '"yawDeg":-41.21212121212105}',
      ),
    );
    await openViewer(tester, ply);

    // 浏览态先转到侧视,确认"初始视角"不是靠继承碰巧对的。
    await tester.drag(find.byType(SparseCloudView), const Offset(0, 220));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // [2026-07-30 用户签决] "初始视角永远是点云正上方的顶" + "你没有加重力的
    // 参数吗"。点云世界 +Y 就是重力上(_gravityAlign,ARKit worldAlignment=
    // .gravity;该草稿实测逐轴标准差 Y=0.289 << X=0.677/Z=0.635)。所以"正
    // 上方"= 相机 pitch 严格 −90°,与框的朝向无关。
    //
    // 上一版反解 M_cam = preset_Top · box.rotᵀ(让**框的**顶面正对),框带
    // 61° 俯仰时实测 pitch=−29.1° —— 用户实机指认的"顶不是点云正上方"。
    // 而单纯硬写 pitch=−90° 又会让歪框的骰子重新变菱形(更早那次实机指认)。
    // 两者数学上不可兼得,唯一两全 = 框朝向一并复位到重力对齐。
    final cam = tester
        .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
        .camera
        .value!;
    expect(
      cam.pitch,
      closeTo(-math.pi / 2, 0.03),
      reason: '不是重力正上方(pitch=${cam.pitch * 180 / math.pi}°)',
    );
    expect(cam.roll.abs(), lessThan(0.03), reason: '正上方视角不该带滚转');

    final box = tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;
    expect(_rotDev(box), lessThan(1e-6), reason: '框朝向没复位到重力对齐');
    // 尺寸/中心不动 —— 复位的只是朝向,不是用户调过的选区大小。
    expect(box.sx, closeTo(3.4273421857647204, 1e-9));
    expect(box.sy, closeTo(2.9928319280554696, 1e-9));
    expect(box.sz, closeTo(3.9394953630036667, 1e-9));

    // 骰子:框正 + 相机正上方 ⇒ 正对面是"顶"且正着放。
    final rel = mulMatrix(
      composeViewMatrix(cam.yaw, cam.pitch, cam.roll),
      box.rot,
    );
    final (ry, rp, _) = decomposeViewMatrix(rel);
    expect(primaryViewCubeFace(ry, rp), 'Top', reason: '骰子的正对面不是"顶"');
    final cube = tester.widget<ViewCube>(
      find.byKey(const ValueKey('view-cube')),
    );
    for (final v in [cube.viewYaw, cube.viewPitch, cube.viewRoll]) {
      final q = v / (math.pi / 2);
      expect(
        (q - q.roundToDouble()).abs(),
        lessThan(0.02),
        reason: '骰子歪着(${v * 180 / math.pi}°)',
      );
    }
  });

  // ── [2026-07-30 用户签决] 完全复刻 RS:点云只能在六个正交面之间切换 ──
  //
  // "点云只能固定六个面动,立方体上下左右的四个箭头也加回来"。自由 orbit
  // (单指拖点云 / 拖骰子)全部取消,唯一的换面入口 = 四个箭头 + 点骰子的面。
  // 箭头机制照 b3588f6^ 的骰子实现回滚:目标姿态 = 90° 视图矩阵 premultiply
  // 当前姿态,每按一次严格 90°,动画走 SO(3) 轴角 slerp。
  group('RS 六面机制', () {
    Future<void> enterEditing(WidgetTester tester, String ply) async {
      await openViewer(tester, ply);
      await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
    }

    CloudViewCamera camOf(WidgetTester tester) => tester
        .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
        .camera
        .value!;

    testWidgets('编辑态单指拖点云不再转视角(自由 orbit 已禁)', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);
      final before = camOf(tester);
      // 用既有"单指一律转视角"用例验证过的坐标(框内,离手柄远)——
      // 靠视图边角起手会被上层 UI 或手柄命中区吃掉,那样是平凡通过。
      final r = tester.getRect(find.byType(SparseCloudView));
      await tester.dragFrom(
        r.center + const Offset(0, 60),
        const Offset(70, 0),
      );
      await tester.pumpAndSettle();
      final after = camOf(tester);
      expect(after.yaw, closeTo(before.yaw, 1e-9), reason: '单指拖动改了 yaw');
      expect(after.pitch, closeTo(before.pitch, 1e-9), reason: '单指拖动改了 pitch');
    });

    testWidgets('拖骰子不再自由转视角', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);
      final before = camOf(tester);
      await tester.drag(
        find.byKey(const ValueKey('view-cube')),
        const Offset(40, 25),
      );
      await tester.pumpAndSettle();
      final after = camOf(tester);
      expect(after.yaw, closeTo(before.yaw, 1e-9));
      expect(after.pitch, closeTo(before.pitch, 1e-9));
    });

    // [2026-07-31 用户签决,推翻 6e83756"接受背面倒置"] "前后左右的文字和点云
    // 都要永远正面朝上(重力参数),因为用户可以用旋转刻度来转"。
    //
    // 判据:点云世界 +Y(= 重力上,ARKit worldAlignment=.gravity)在屏幕上必须
    // 指向**上方**。相机 z 轴与 +Y 平行的顶/底视角除外 —— 那里 +Y 投在屏幕外,
    // 由 preset 自己保证文字正立。
    testWidgets('任何箭头序列之后,面都正立(不倒置也不歪斜)', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);

      // 覆盖到会翻过极点的序列:一路"下"必然过顶/过底。
      const seq = [
        'cube-down',
        'cube-down',
        'cube-down',
        'cube-down',
        'cube-right',
        'cube-down',
        'cube-left',
        'cube-up',
        'cube-up',
        'cube-right',
        'cube-right',
        'cube-down',
      ];
      for (var i = 0; i < seq.length; i++) {
        await tester.tap(find.byKey(ValueKey(seq[i])));
        await tester.pumpAndSettle();
        final cam = camOf(tester);
        final m = composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
        // 世界 +Y 在相机系的分量:x = m[1](屏幕横), y = m[4](屏幕纵)。
        final ux = m[1], uy = m[4];
        final onScreen = math.sqrt(ux * ux + uy * uy);
        if (onScreen < 1e-6) continue; // 顶/底视角
        expect(
          uy,
          greaterThan(0.9),
          reason:
              '第 ${i + 1} 步(${seq[i]})之后重力上在屏幕上不朝上 '
              '(ux=$ux, uy=$uy) ⇒ 画面倒置或歪斜',
        );
        expect(ux.abs(), lessThan(1e-6), reason: '第 ${i + 1} 步之后画面歪了');
      }
    });

    testWidgets('四个箭头:每按一步都换面,且每一步都是正立的正交视图', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);

      // [2026-07-31 语义修正两次]
      // ① 原用例断言"反向箭头精确回到基准"。实测极面起步时**左右也不可逆**:
      //    顶按"左"到右、右按"右"到后 —— 极面的屏幕竖直轴与侧面的不是同一根,
      //    两者不互逆。上下更是按 07-31 签决("永远正面朝上")主动舍弃了可逆。
      // ② 改写版本想"每轮重建页面回到同一基准",但同类型 widget 重复
      //    pumpWidget 会复用 Element、页面停在编辑态,加 key 强制重建后 tap
      //    "Next" 又进不了编辑态(对方 agent 正在重构这条路径)。所以不回基准,
      //    改为在同一次编辑里连着按 —— 守的是每一步的不变量,更强也更稳。
      List<double> pose() {
        final cam = tester
            .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
            .camera
            .value!;
        return composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
      }

      var prev = pose();
      for (final k in [
        'cube-up',
        'cube-left',
        'cube-down',
        'cube-right',
        'cube-left',
        'cube-left',
      ]) {
        await tester.tap(find.byKey(ValueKey(k)));
        await tester.pumpAndSettle();
        final now = pose();

        var moved = 0.0;
        for (var i = 0; i < 9; i++) {
          moved += (now[i] - prev[i]).abs();
        }
        expect(moved, greaterThan(0.1), reason: '$k 没换面');

        // 正立:姿态必须逐位等于该面的 preset(滚转分量为 0),否则面上的文字
        // 是歪的或倒的 —— 07-31 签决"前后左右的文字和点云都要永远正面朝上"。
        final (y, p, _) = decomposeViewMatrix(now);
        final label = primaryViewCubeFace(y, p);
        final preset = kOrientationPresets.firstWhere((e) => e.label == label);
        final ref = composeViewMatrix(preset.yaw, preset.pitch, 0);
        var dev = 0.0;
        for (var i = 0; i < 9; i++) {
          dev += (now[i] - ref[i]).abs();
        }
        expect(dev, lessThan(1e-6), reason: '$k 到达 $label 时不是正立的');
        prev = now;
      }
    });

    testWidgets('拨过滑轨后箭头方向不许错乱(骰子在"左"按"左"要到"后",不是"底")', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);
      String face(WidgetTester t) {
        final c = t.widget<ViewCube>(find.byKey(const ValueKey('view-cube')));
        return primaryViewCubeFace(c.viewYaw, c.viewPitch);
      }

      // 走到"左":Top --左--> Right --左--> Front --左--> Left。
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('cube-left')));
        await tester.pumpAndSettle();
      }
      expect(face(tester), 'Left', reason: '没走到"左"面,后面的断言无意义');

      // 拨滑轨:钟表旋转给**相机**注入 roll,框绕视线反转同角度抵消 ⇒ 骰子
      // 显示的面不变。
      await _dragRulerDeg(tester, 60);
      final camRoll = tester
          .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
          .camera
          .value!
          .roll;
      expect(camRoll.abs(), greaterThan(0.05), reason: '滑轨没产生滚转');
      expect(face(tester), 'Left', reason: '滑轨不该改变骰子显示的面');

      // [2026-07-30 用户实机指认] "我在左的角度,当我想要向左转,就到了底部"。
      // 根因:箭头 premultiply 在**相机**姿态上,而相机带着滑轨的 roll ——
      // 骰子读 M_cam·box.rot 时 roll 被框朝向抵消,所以骰子照样显示"左",但
      // 箭头绕的"屏幕竖直轴"在带 roll 的相机里已经不竖直,"左"退化成俯仰。
      // 探针实测 roll=−90° 时左→Bottom、+90° 时左→Top,与实机吻合。
      // 修法:箭头作用在**骰子看到的姿态**上,再反解回相机(与点击面同一套)。
      await tester.tap(find.byKey(const ValueKey('cube-left')));
      await tester.pumpAndSettle();
      expect(
        face(tester),
        'Back',
        reason: '带滚转时"左"箭头转错了方向(到了 ${face(tester)})',
      );
    });

    testWidgets('四个箭头都在,每按一次换到相邻面且落在六个正交视图上', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await enterEditing(tester, ply);
      for (final k in ['cube-up', 'cube-down', 'cube-left', 'cube-right']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: '$k 箭头不存在');
      }

      // [2026-07-31 语义修订,不是回归] 原断言"相对上一步的整体旋转角 = 90°"。
      // 用户签决"永远正面朝上"之后,这条与"每步 90°"数学上不可兼得:绕屏幕轴
      // 滚 90° 过极点必然把远端那一面滚成倒置的,回正就得再绕视线轴补 180° ——
      // 那一步的整体旋转因此是 180°。
      //
      // 真正守得住、也是用户要的那条是:**正对的面**每次恰好换到相邻面,即
      // 视线轴(姿态矩阵第三行)每步转 90°;至于面内怎么摆,由回正保证正立。
      var prev = composeViewMatrix(
        camOf(tester).yaw,
        camOf(tester).pitch,
        camOf(tester).roll,
      );
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('cube-down')));
        await tester.pumpAndSettle();
        final cam = camOf(tester);
        final now = composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
        for (var k = 0; k < 9; k++) {
          final v = now[k].abs();
          expect(
            math.min(v, (v - 1).abs()),
            lessThan(1e-6),
            reason: '第 ${i + 1} 步姿态不是正交视图(元素 $k = ${now[k]})',
          );
        }
        // 视线轴 = 第三行;相邻面 ⇒ 两轴正交 ⇒ 点积为 0。
        final dot = now[6] * prev[6] + now[7] * prev[7] + now[8] * prev[8];
        expect(
          dot.abs(),
          lessThan(1e-6),
          reason:
              '第 ${i + 1} 步没换到相邻面(视线轴点积 $dot ⇒ '
              '${math.acos(dot.clamp(-1, 1)) * 180 / math.pi}°)',
        );
        prev = now;
      }
    });
  });

  testWidgets('连续拨动不会中途把点云重置回初始角度', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    SelectionBox box() => tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .selectionBox!;

    // 先把框转歪(拨滑轨),再用菜单还原。
    await _dragRulerDeg(tester, 60);
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
    // [2026-07-30 用户实机指认"框变大而且红色点云在框内"] 只复位框是不够的:
    // 拨滑轨是点云转 + 框反向补偿,单独把 rot 打回单位阵会让框相对**当前
    // 视角**歪着 —— 2D 手柄矩形退化成歪框的屏幕包围盒(看着"变大"),矩形内
    // 但 3D 框外的点照常染红(看着"红点在框内")。视角必须一起回"顶"。
    final cube = tester.widget<ViewCube>(find.byType(ViewCube));
    for (final (name, v) in [
      ('yaw', cube.viewYaw),
      ('pitch', cube.viewPitch),
      ('roll', cube.viewRoll),
    ]) {
      final q = v / (math.pi / 2);
      expect(
        (q - q.roundToDouble()).abs(),
        lessThan(0.02),
        reason:
            '复位后骰子 $name=${v * 180 / math.pi}° 不是 90° 的整数倍 ⇒ '
            '框与视角失配(框会显得变大、框内出现红点)',
      );
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
    await _dragRulerDeg(tester, 45);
    expect(_rotDev(box()), greaterThan(0.1), reason: '先要真的拨歪');
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Box Size'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 9; i++) {
      expect(box().rot[i], closeTo(kIdentityRot[i], 1e-12));
    }
  });

  testWidgets('⋯ 菜单展开时:下层操作照常生效(那一次手势不被吞)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
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
    await _dragRulerDeg(tester, 40);
    expect((_rotDev(box()) - dev0).abs(), greaterThan(0.1), reason: '菜单挡住了刻度');

    // [2026-07-30 语义替换] 骰子拖动随"点云只能固定六个面动"删除,换面入口
    // 是四个箭头 —— 守的还是同一件事:菜单浮层不能吞掉下层手势。
    // 判据取骰子姿态矩阵的偏离量(单看 yaw 不行:按"下"主要改 pitch,极面
    // 附近 yaw 还会因欧拉简并跳变)。
    List<double> cubePose() =>
        composeViewMatrix(cube().viewYaw, cube().viewPitch, cube().viewRoll);
    final pose0 = cubePose();
    await tester.tap(find.byKey(const ValueKey('cube-down')));
    await tester.pumpAndSettle();
    var poseDev = 0.0;
    for (var i = 0; i < 9; i++) {
      poseDev += (cubePose()[i] - pose0[i]).abs();
    }
    expect(poseDev, greaterThan(0.5), reason: '菜单挡住了箭头');

    // [2026-08-03 语义反转,不是回归] 原断言是"菜单仍然开着(自绘浮层不会因为
    // 下层手势自动收起)"。用户随后签决"点击屏幕其他区域时弹窗自动消失(跟取消
    // 的弹窗逻辑一样)"⇒ 操作下层就该顺手关掉菜单。本用例保留的核心是**那一次
    // 手势不被吞**(上面已断言刻度/箭头确实生效),菜单去留改由新用例
    // 「⋯ 菜单:点屏幕其他区域自动消失,且不吞掉那一次手势」守。
    expect(find.text('Reset Rotation'), findsNothing, reason: '操作下层后菜单该收起');
  });

  testWidgets('底部弧形刻度盘:点指针收起/展开,面板高度不变(整体旋转)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // [2026-08-07 语义替换,不是回归] 原用例守的是"半圆把手 + 面板折叠变矮"。
    // 弧形刻度盘把收起改成**整个盘绕弧心转 180°** —— 弧心在面板下方,转过去后
    // 弧线落到屏幕外。所以面板高度**恒定不变**,把手也不存在了,入口是指针本身。
    final pin = find.byKey(const ValueKey('ruler-pin'));
    final ruler = find.byType(RulerScrubber);
    expect(ruler, findsOneWidget);
    expect(pin, findsOneWidget, reason: '指针命中区不在,没有收起入口');
    expect(
      tester.widget<RulerScrubber>(ruler).deployed,
      isTrue,
      reason: '打开编辑页应默认升起',
    );

    final panelHeightBefore = tester.getRect(ruler).height;

    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(
      tester.widget<RulerScrubber>(ruler).deployed,
      isFalse,
      reason: '点指针没能收起',
    );
    // 收起靠旋转,不靠改高度 —— 面板尺寸必须逐像素不变,否则上方点云会跳。
    expect(
      tester.getRect(ruler).height,
      panelHeightBefore,
      reason: '收起改了面板高度 ⇒ 点云画布会跳一下',
    );
    expect(ruler, findsOneWidget, reason: '收起后组件不该从树上消失(要能再点回来)');

    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(tester.widget<RulerScrubber>(ruler).deployed, isTrue);
    expect(tester.getRect(ruler).height, panelHeightBefore);
  });

  testWidgets('编辑态不显示右上角 reframe 按钮(浏览态保留)', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);

    // [2026-08-07 用户实机指认] 编辑页右上角那个 filter_center_focus 图标"好像没
    // 有任何作用" —— 它和"⋯"菜单的"回到初始点云大小"是同一个功能,而且 top:10
    // 压在状态栏边缘、被"完成"按钮挤着,基本点不到。编辑态删掉,浏览态保留
    // (那里没有 ⋯ 菜单,它是唯一入口)。
    final reframeBtn = find.byIcon(Icons.filter_center_focus);
    expect(reframeBtn, findsOneWidget, reason: '浏览态的 reframe 入口不该被删');

    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(reframeBtn, findsNothing, reason: '编辑态还留着那个点不到的图标');

    // 回浏览态 ⇒ 重新出现。
    await tester.tap(find.byKey(kSelectionCancelKey));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(reframeBtn, findsOneWidget, reason: '退出编辑后浏览态的入口没回来');
  });

  testWidgets('退出编辑的视角:取消 ⇒ 回斜上 45°,完成 ⇒ 保留当前视角', (tester) async {
    // [2026-08-08 用户签决] "如果用户在编辑页面什么都没做,直接点取消了,那就恢复
    // 到斜上 45 度。如果用户编辑了点云大小,点击完成后,就保留在当前视角。"
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);

    Future<void> enterEditing() async {
      await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
    }

    // ── 取消(什么都没做)⇒ 恢复斜上 45° ──
    await enterEditing();
    // 前提:编辑态确实被拧成了正俯视(否则本用例测不到东西)。
    expect(_browsePitchOf(tester), closeTo(-math.pi / 2, 0.03));

    await tester.tap(find.byKey(kSelectionCancelKey));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      _browsePitchOf(tester),
      closeTo(-math.pi / 4, 0.03),
      reason:
          '取消后没回到斜上 45°(pitch=${_browsePitchOf(tester) * 180 / math.pi}°)'
          ' ⇒ 用户停在编辑态那个正俯视上',
    );

    // ── 完成 ⇒ 保留当前视角(不许偷偷跳回 45°) ──
    await enterEditing();
    expect(_browsePitchOf(tester), closeTo(-math.pi / 2, 0.03));
    await tester.tap(find.byKey(const ValueKey('selection-back')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
    );
    await tester.pumpAndSettle();
    expect(
      _browsePitchOf(tester),
      closeTo(-math.pi / 2, 0.03),
      reason: '完成后视角被重置了 ⇒ 用户说的"保留在当前视角"没做到',
    );
  });

  testWidgets('编辑态绝不出现 45°:进编辑 / 回到初始角度 / 回到初始大小 三条路都是正俯视', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);

    // [2026-08-07 用户签决] 浏览态初始视角改成斜上 45°(与草稿卡片缩略图同姿态,
    // 学 Polycam),但"编辑模式绝对不允许存在这种 45 度的情况" —— 选区的 2D 矩形
    // 手柄只有正俯视才与盒的投影严格重合。
    final browse = tester
        .widget<SparseCloudView>(find.byType(SparseCloudView))
        .initialCamera;
    // 浏览态确实是斜的(否则本用例什么都没测到)。
    expect(
      browse?.pitch ?? _browsePitchOf(tester),
      closeTo(-math.pi / 4, 0.05),
      reason: '浏览态初始视角不是斜上 45°',
    );

    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    double editPitch() => tester
        .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
        .camera
        .value!
        .pitch;

    // ① 进编辑 ⇒ 正俯视。
    expect(
      editPitch(),
      closeTo(-math.pi / 2, 0.03),
      reason: '进编辑没转到正上方(pitch=${editPitch() * 180 / math.pi}°)',
    );

    // ② "回到初始旋转角度" ⇒ 仍是正俯视。
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Rotation'));
    await tester.pumpAndSettle();
    expect(
      editPitch(),
      closeTo(-math.pi / 2, 0.03),
      reason: '"回到初始旋转角度"把视角带到了 45°',
    );

    // ③ "回到初始点云大小"(reframe)⇒ 仍是正俯视。这条是实机指认的真凶:
    //    _reframe() 原先无条件用浏览态的 _kDefaultPitch(45°)。
    await tester.tap(find.byKey(const ValueKey('selection-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset Zoom'));
    await tester.pumpAndSettle();
    expect(
      editPitch(),
      closeTo(-math.pi / 2, 0.03),
      reason: '"回到初始点云大小"把视角拽回了 45°(reframe 用了浏览态默认 pitch)',
    );
  });

  testWidgets('⋯ 菜单:点屏幕其他区域自动消失,且不吞掉那一次手势', (tester) async {
    final (dir, ply) = await fixture(tester);
    addTearDown(() => dir.delete(recursive: true));
    await openViewer(tester, ply);
    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // [2026-08-03 用户签决] "点击屏幕其他区域时弹窗自动消失(跟取消的弹窗逻辑
    // 一样)"。但 07-30 那条"拉开 ⋯ 时依然能转立方体/拨刻度/转点云"仍然有效,
    // 所以这里同时守两件事:空白点击关菜单、并且那一次手势没被吞掉。
    Future<void> openMenu() async {
      await tester.tap(find.byKey(const ValueKey('selection-more')));
      await tester.pumpAndSettle();
      expect(find.text('Reset Rotation'), findsOneWidget);
    }

    // ① 点空白 ⇒ 菜单消失。
    await openMenu();
    final r = tester.getRect(find.byType(SparseCloudView));
    await tester.tapAt(Offset(r.center.dx, r.top + r.height * 0.28));
    await tester.pumpAndSettle();
    expect(find.text('Reset Rotation'), findsNothing, reason: '点空白没关掉菜单');
    expect(find.byType(SelectionToolsLayer), findsOneWidget, reason: '不该退出编辑态');

    // ② 菜单开着时按箭头:菜单关掉,而且箭头**照常生效**(手势没被吞)。
    await openMenu();
    List<double> pose() {
      final cam = tester
          .widget<SelectionToolsLayer>(find.byType(SelectionToolsLayer))
          .camera
          .value!;
      return composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
    }

    final before = pose();
    await tester.tap(find.byKey(const ValueKey('cube-down')));
    await tester.pumpAndSettle();
    expect(find.text('Reset Rotation'), findsNothing, reason: '按箭头后菜单还开着');
    var moved = 0.0;
    for (var i = 0; i < 9; i++) {
      moved += (pose()[i] - before[i]).abs();
    }
    expect(moved, greaterThan(0.1), reason: '菜单把箭头那一次点击吞掉了');
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
    expect(find.byKey(const ValueKey('viewer-enter-editing')), findsNothing);
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

    await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
    await _pumpUntilRealAsyncSettles(
      tester,
      () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();

    // [2026-07-30 语义更新,不是回归] 本用例原来断言"框仍带 41° 朝向、只把
    // 相机对齐过去"。用户随后签决"初始视角永远是重力正上方的顶",而框歪着时
    // "相机在正上方"与"骰子正着放"数学上互斥 ⇒ 改为框朝向一并复位。这里跟着
    // 断言复位到位;骰子落在 90° 倍数这条核心断言不变。
    final box = boxOf(tester)!;
    expect(_rotDev(box), lessThan(1e-6), reason: '框朝向应复位到重力对齐');

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

  // [SEL-ENTRY / SEL-PREVIEW / SEL-DISCARD 2026-07-30 用户签决] 选区从"必经的
  // 下一步"降级成可选动作:右上角一个 icon 进,同一位置的"返回"出;用了选区,
  // 浏览态就只画框内的点;退到草稿页时若改过框要问一句存不存。
  group('选区 = 可选动作', () {
    /// 让 [box] 落到盘上,当作"上次编辑留下的选区"。
    Future<void> seed(WidgetTester tester, Directory dir, SelectionBox box) =>
        tester.runAsync(() => box.saveTo(dir.path));

    /// 把页面 **push** 到一个占位首页之上。
    ///
    /// 不能像 openViewer 那样直接当 `home` —— ④ 的裁决通过后会 pop 本页,而
    /// pop 掉最后一条路由会留下一段永远 settle 不了的转场,pumpAndSettle 要空
    /// 转满 10 分钟默认超时才报错(实测整个测试进程像挂死)。底下垫一层就没事。
    Future<void> pushViewer(WidgetTester tester, String ply) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => SparseCloudViewerPage(plyPath: ply),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.text('Next').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
    }

    Future<void> enterEditing(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('viewer-enter-editing')));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('右上角"选区编辑"是进编辑态的入口(不必再点"下一步")', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await openViewer(tester, ply);

      final entry = find.byKey(const ValueKey('viewer-enter-editing'));
      expect(entry, findsOneWidget);
      // 用户要的是**文字**不是图标。
      expect(find.text('Edit selection'), findsOneWidget);
      // 真的在右上角:中心落在屏幕右侧 1/4、顶部 1/6 内。
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final c = tester.getCenter(entry);
      expect(c.dx, greaterThan(size.width * 0.75));
      expect(c.dy, lessThan(size.height / 6));

      await enterEditing(tester);
      expect(find.byType(SelectionToolsLayer), findsOneWidget);
    });

    testWidgets('编辑态:左"取消"右"完成",六视图立方体在完成下方', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await openViewer(tester, ply);
      final entryRect = tester.getRect(
        find.byKey(const ValueKey('viewer-enter-editing')),
      );
      await enterEditing(tester);

      final back = find.byKey(const ValueKey('selection-back'));
      expect(back, findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      // 苹果相册版式:左上"取消"。
      final cancel = find.byKey(kSelectionCancelKey);
      expect(cancel, findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      final w = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(tester.getCenter(cancel).dx, lessThan(w / 4), reason: '"取消"不在左上角');
      final backRect = tester.getRect(back);
      // ⚠️ 比的是**右边缘**不是中心:"选区编辑"比"完成"宽得多,两个右对齐的
      // 按钮中心天然差几十 pt(实测 71.5),拿中心比会误判成没对齐。
      expect((backRect.right - entryRect.right).abs(), lessThan(12));
      expect((backRect.center.dy - entryRect.center.dy).abs(), lessThan(12));
      // 立方体让位到"完成"下方。
      expect(
        tester.getRect(find.byType(ViewCube)).top,
        greaterThan(backRect.bottom),
        reason: '六视图立方体压在"完成"上,点不到',
      );

      await tester.tap(back);
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('viewer-enter-editing')),
        findsOneWidget,
      );
    });

    testWidgets('盘上已有选区:一进页面浏览态就按框裁剪,标题报框内点数', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      // fixture 是 (0,0,0) 与 (1,1,1) 两点;这个框只圈住原点。
      await seed(
        tester,
        dir,
        SelectionBox.initialSquareFace(cx: 0, cy: 0, cz: 0, halfExtent: 0.2),
      );
      await openViewer(tester, ply);

      expect(boxOf(tester), isNotNull, reason: '浏览态没拿到盘上的框 ⇒ 重开草稿会显示全量点云');
      // 标题必须跟着走,否则"2 pts"和眼前 1 个点自相矛盾。
      expect(find.textContaining('1 pts'), findsOneWidget);
      expect(find.textContaining('2 pts'), findsNothing);
    });

    Future<void> tapAndSettleExitKey(WidgetTester tester, Key key) async {
      await tester.tap(find.byKey(key));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
    }

    Future<void> tapAndSettleExit(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();
    }

    // [2026-07-30 用户签决"点云和投影是同一个"] 07-29 曾给编辑态单独切正交,
    // 结果点"完成"时相机一个数没动、画面却明显形变(近 +14% / 远 −11%,
    // camDist = 8×radius)。两态必须同一种投影。
    testWidgets('浏览与编辑用同一种投影 —— 进出编辑态不产生形变', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      await pushViewer(tester, ply);

      bool orthoOf(WidgetTester t) => t
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<SparseCloudPainter>()
          .single
          .orthographic;

      final browse = orthoOf(tester);
      await enterEditing(tester);
      expect(orthoOf(tester), browse, reason: '编辑态换了投影 ⇒ 点"完成"回浏览态时画面会形变');
      await tapAndSettleExitKey(tester, kSelectionCancelKey);
      expect(orthoOf(tester), browse);
    });

    Future<void> editBox(WidgetTester tester) async {
      await enterEditing(tester);
      await _dragRulerDeg(tester, 55);
      expect(_rotDev(boxOf(tester)!), greaterThan(0.1), reason: '滑轨应已转动框');
    }

    testWidgets('"完成"直接提交,不问 —— 确认只压在破坏性那一侧', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/$kSelectionBoxFileName');

      await pushViewer(tester, ply);
      await editBox(tester);
      await tapAndSettleExit(tester, 'selection-back');

      expect(find.text('Discard changes?'), findsNothing);
      expect(f.existsSync(), isTrue);
      expect(boxOf(tester), isNotNull, reason: '提交后浏览态应按新框裁剪');
    });

    testWidgets('没编辑就点"取消":不弹窗,直接回预览,点云形状回到原样', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/$kSelectionBoxFileName');
      await pushViewer(tester, ply);
      await enterEditing(tester);

      await tapAndSettleExitKey(tester, kSelectionCancelKey);
      expect(
        find.text('Discard changes?'),
        findsNothing,
        reason: '一个手柄都没碰,点"取消"却被拦了一次',
      );
      expect(find.byType(SelectionToolsLayer), findsNothing);
      // [2026-08-03 用户签决] "用户第一次点进来,点云其实就已经是被编辑的状态了
      // (初始的框就已经算编辑了),所以点取消就是撤回本次所有编辑,包括初始
      // 框" —— 撤回要落到**点云形状**上:浏览态交回原始点云,盘上不留记录。
      expect(boxOf(tester), isNull, reason: '浏览态还在按初始框裁剪');
      expect(f.existsSync(), isFalse, reason: '初始框没撤掉,盘上还留着记录');
    });

    testWidgets('首次进编辑什么都不动点"完成":初始框就是选区,必须落盘', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/$kSelectionBoxFileName');
      await pushViewer(tester, ply);
      await enterEditing(tester);

      // 与"取消"对称:初始框既然算一次编辑,点"完成"就该把它确立为选区。
      // 此前 _persist 的 applied 取 _selectionApplied,而它只在用户拖动框时
      // 才置真 ⇒ 不动就点"完成"会走**删文件**分支,选区直接丢掉。
      await tapAndSettleExit(tester, 'selection-back');
      expect(find.text('Discard changes?'), findsNothing, reason: '"完成"不该问');
      expect(f.existsSync(), isTrue, reason: '点了"完成"却没把初始框落盘');
      expect(boxOf(tester), isNotNull, reason: '浏览态应按选区裁剪');
    });

    testWidgets('"放弃更改"浮层锚定在左上"取消"下方(苹果相册版式)', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      // ⚠️ 必须注入状态栏 inset:默认测试环境 padding 全 0,SafeArea 不产生任何
      // 偏移 ⇒ 测不出 showDialog(useSafeArea: true) 把浮层顶下去那个坑(假绿)。
      // 真机 iPhone 14 Pro 顶部约 59pt × dpr 3 = 177 物理像素。
      tester.view.padding = const FakeViewPadding(top: 177);
      tester.view.viewPadding = const FakeViewPadding(top: 177);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await pushViewer(tester, ply);
      await editBox(tester);

      final cancelRect = tester.getRect(find.byKey(kSelectionCancelKey));
      await tester.tap(find.byKey(kSelectionCancelKey));
      await tester.pumpAndSettle();

      // [2026-08-03 用户签决 + 截图] 学苹果:确认从被点的那个按钮下面弹出来,
      // 不是从屏幕底部升起的动作单(原实现 showCupertinoModalPopup 弹在底部,
      // 离触发点最远)。
      final pop = find.byKey(const ValueKey('selection-discard-popover'));
      expect(pop, findsOneWidget, reason: '浮层不在');
      final popRect = tester.getRect(pop);
      expect(
        popRect.top,
        greaterThanOrEqualTo(cancelRect.bottom),
        reason:
            '浮层没落在"取消"下方(top=\${popRect.top} vs 按钮 bottom='
            '\${cancelRect.bottom})',
      );
      expect(
        popRect.top - cancelRect.bottom,
        lessThan(10),
        reason:
            '浮层离"取消"太远(应紧贴其下、盖住"⋯")—— 检查 '
            'showDialog 的 useSafeArea 是否又打开了',
      );
      // 宽度:用户要求收窄,别占掉半个屏。
      final w = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(popRect.width, lessThan(w * 0.62), reason: '浮层太宽');
      expect(
        (popRect.left - cancelRect.left).abs(),
        lessThan(20),
        reason: '浮层没和"取消"左对齐',
      );
      // 屏幕上半部分 —— 反过来锁死"不许再回到底部动作单"。
      final h = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(popRect.top, lessThan(h / 2), reason: '浮层又跑到屏幕下半部了');

      // 点浮层以外 ⇒ 收起,留在编辑页(语义不变)。
      await tester.tapAt(Offset(popRect.left + 10, h - 10));
      await tester.pumpAndSettle();
      expect(pop, findsNothing);
      expect(find.byType(SelectionToolsLayer), findsOneWidget);
    });

    testWidgets('编辑过再点"取消":问一句,"放弃更改"回滚落盘', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/$kSelectionBoxFileName');

      await pushViewer(tester, ply);
      await editBox(tester);
      // 编辑期只改内存；正式记录必须等用户点“完成”才写。
      await tester.tap(find.byKey(kSelectionCancelKey));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      await tester.tap(find.text('Discard Changes'));
      await _pumpUntilRealAsyncSettles(
        tester,
        () => find.byType(SelectionToolsLayer).evaluate().isEmpty,
      );
      await tester.pumpAndSettle();

      // 进编辑前盘上没有框 ⇒ 回滚 = 删掉这次写出来的文件,不能靠"跳过写盘"。
      expect(f.existsSync(), isFalse, reason: '"放弃更改"把本次编辑留在盘上了');
      expect(boxOf(tester), isNull, reason: '放弃后仍在按框裁剪');
    });

    testWidgets('点动作单以外的地方:弹窗消失,留在编辑页', (tester) async {
      final (dir, ply) = await fixture(tester);
      addTearDown(() => dir.delete(recursive: true));
      final persisted = File('${dir.path}/$kSelectionBoxFileName');
      await pushViewer(tester, ply);
      await editBox(tester);
      final edited = boxOf(tester)!;

      // 显式越过去抖期限，再给真实 dart:io 一个完成窗口。pumpAndSettle 只推进
      // FakeAsync，不保证 unawaited 的文件写入已经完成。
      await tester.pump(const Duration(milliseconds: 600));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );

      // 取消是一笔尚未提交的编辑事务。即使停留时间已经超过旧版本的 500ms
      // 去抖窗口，用户没点“完成”前也绝不能写正式记录；否则动作单被点空白
      // 处关闭后，界面看似仍在编辑，磁盘却已偷偷保存。
      expect(
        persisted.existsSync(),
        isFalse,
        reason: '未点“完成”就提前落盘，随后点“取消”无法可靠撤销',
      );

      await tester.tap(find.byKey(kSelectionCancelKey));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);

      // 顶部空白处 = 动作单以外。
      await tester.tapAt(const Offset(200, 40));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsNothing);
      expect(
        find.byType(SelectionToolsLayer),
        findsOneWidget,
        reason: '点外部却退出了编辑页',
      );
      expect(boxOf(tester)!.sameAs(edited), isTrue, reason: '框被动了');
      expect(
        persisted.existsSync(),
        isFalse,
        reason: '关闭放弃动作单不等于提交，正式选区记录必须仍未创建',
      );
    });

    // [2026-07-30 缺口,记在原地] 这里本该有一条 '"保存" = 新框留在盘上' 的
    // 对照用例,写了但**没能让它稳定**:tap 'Save' 之后裁决会 pop 本页,而落盘
    // 是 FakeAsync 里 await 的真实 dart:io —— 等弹窗消失、等页面退出、定量驱动
    // 真实异步三种写法都挂到框架 10 分钟超时(其余六条同文件同 harness 全绿)。
    // 没有把它改成"看起来在测、其实什么都没等"的样子留下。
    //
    // 覆盖现状:回滚语义由上面 '"不保存" = 回滚落盘' 正面守住(它断言文件被
    // 真的删掉);'保存' 分支的代码形状由 test/selection_optional_entry_test.dart
    // 钉住。真正没被自动化覆盖的只剩"选保存后磁盘内容 == 编辑后的框"这一步。
  });
}
