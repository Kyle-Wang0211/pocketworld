// 拍摄退出弹窗(黑白 + 开关)。
//
// [2026-08-09 用户签决,附截图] 旧版:第一行滑轴,滑块只能停在左右两侧;左
// (默认)= 黑底白字"退出并保存照片",右 = 红底白字"退出并不保存照片";点文字
// 区执行当前动作。第二行"继续拍摄"。
//
// [2026-08-22 用户签决,本次改版] 现版:标题居中;第一行 =
// "是否保存照片,方便下次补拍" + 右侧小开关(开/绿 = 保存,默认;关/红 =
// 不保存);第二行 = "确定"(白底黑边黑字)/ "取消"(黑底白字)。点弹窗外仍
// 自动返回拍摄。
//
// ⚠️ 本文件里最重要的一条是"破坏性出路需要两个刻意动作":默认态下**任何单次
// 手势**都不能拿到 discardExit —— 见 `单次手势拿不到 discardExit` 一例。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/capture_exit_dialog.dart';

Finder get saveToggle =>
    find.byKey(const ValueKey<String>('capture-exit-save-toggle'));
Finder get confirmBtn =>
    find.byKey(const ValueKey<String>('capture-exit-confirm'));
Finder get cancelBtn =>
    find.byKey(const ValueKey<String>('capture-exit-cancel'));

Finder get saveKnob =>
    find.byKey(const ValueKey<String>('capture-exit-save-knob'));

/// 弹窗**卡片**的矩形。⚠️ 不能用 `find.byType(CaptureExitDialog)` —— 它的
/// RenderBox 是整屏(0..393),拿它当边界等于没做断言。真卡片是 Dialog 里那层
/// Material。
Finder get dialogCard => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

/// 开关轨道**当前画出来的**颜色。
///
/// ⚠️ 读 `AnimatedContainer` 这个 widget 的 decoration 拿到的是**动画目标值**,
/// 一 setState 就立刻是终点色 —— 那样永远看不出颜色是渐变还是瞬间跳。这里读
/// render object,拿的是这一帧真正画在屏幕上的颜色。
Color? toggleTrackColor(WidgetTester tester) {
  final box = tester.renderObject<RenderDecoratedBox>(
    find.descendant(of: saveToggle, matching: find.byType(DecoratedBox)).first,
  );
  return (box.decoration as BoxDecoration?)?.color;
}

/// 挂一个能开弹窗的宿主;`result` 由回调写入。
Future<void> pumpHost(
  WidgetTester tester,
  void Function(CaptureExitChoice?) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const ValueKey<String>('open'),
              onPressed: () async => onResult(await showCaptureExitDialog(ctx)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> openDialog(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('open')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认态:标题居中,开关为绿(保存)', (tester) async {
    await pumpHost(tester, (_) {});
    await openDialog(tester);

    final title = tester.widget<Text>(find.text('退出拍摄？'));
    expect(
      title.textAlign,
      TextAlign.center,
      reason: '标题必须居中(2026-08-22 签决,原来是左对齐)',
    );

    expect(find.text('是否保存照片，方便下次补拍'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 旧版控件必须彻底消失,不能新旧并存。
    expect(find.text('继续拍摄'), findsNothing);
    expect(find.text('退出并保存照片'), findsNothing);
    expect(find.text('退出并不保存照片'), findsNothing);

    expect(
      toggleTrackColor(tester),
      kCaptureExitSaveGreen,
      reason: '默认必须是"保存"(绿)—— 与文案"方便下次补拍"一致',
    );
  });

  testWidgets('默认态点"确定" ⇒ saveExit', (tester) async {
    CaptureExitChoice? result;
    var closed = false;
    await pumpHost(tester, (r) {
      result = r;
      closed = true;
    });
    await openDialog(tester);
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(result, CaptureExitChoice.saveExit);
  });

  testWidgets('拨开关 ⇒ 变红且弹窗不关;再点"确定" ⇒ discardExit', (tester) async {
    CaptureExitChoice? result;
    await pumpHost(tester, (r) => result = r);
    await openDialog(tester);

    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    expect(
      toggleTrackColor(tester),
      kCaptureExitDangerRed,
      reason: '关 = 不保存,必须是破坏性红',
    );
    // 拨开关本身不执行 —— 弹窗还在。
    expect(find.byType(CaptureExitDialog), findsOneWidget);
    expect(result, isNull);

    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();
    expect(result, CaptureExitChoice.discardExit);
  });

  testWidgets('开关可以拨回来:红 → 绿 ⇒ 又是 saveExit', (tester) async {
    CaptureExitChoice? result;
    await pumpHost(tester, (r) => result = r);
    await openDialog(tester);

    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    expect(toggleTrackColor(tester), kCaptureExitDangerRed);
    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    expect(toggleTrackColor(tester), kCaptureExitSaveGreen);

    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();
    expect(result, CaptureExitChoice.saveExit);
  });

  testWidgets('"取消"与点弹窗外 ⇒ 返回 null(回拍摄)', (tester) async {
    CaptureExitChoice? result = CaptureExitChoice.discardExit;
    await pumpHost(tester, (r) => result = r);

    await openDialog(tester);
    await tester.tap(cancelBtn);
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '"取消"应返回 null');

    result = CaptureExitChoice.discardExit;
    await openDialog(tester);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(result, isNull, reason: '点弹窗外应自动返回拍摄(null)');
  });

  testWidgets('拨到红之后点"取消" ⇒ 仍是 null,不会误丢照片', (tester) async {
    CaptureExitChoice? result = CaptureExitChoice.saveExit;
    await pumpHost(tester, (r) => result = r);
    await openDialog(tester);
    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    await tester.tap(cancelBtn);
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  // ⚠️ 这是 08-09 那版"滑过去再点"安全性质的继任者:破坏性出路必须是**两个**
  // 刻意动作。穷举默认态下的每一个可点位置,证明没有任何单次手势能拿到
  // discardExit。
  testWidgets('单次手势拿不到 discardExit(默认态穷举)', (tester) async {
    for (final probe in <(String, Future<void> Function(WidgetTester))>[
      ('点确定', (t) async => t.tap(confirmBtn)),
      ('点取消', (t) async => t.tap(cancelBtn)),
      ('点开关', (t) async => t.tap(saveToggle)),
      ('点标签', (t) async => t.tap(find.text('是否保存照片，方便下次补拍'))),
      ('点标题', (t) async => t.tap(find.text('退出拍摄？'))),
      ('点弹窗外', (t) async => t.tapAt(const Offset(5, 5))),
      (
        '在开关上横拖',
        (t) async {
          final r = t.getRect(saveToggle);
          await t.dragFrom(r.centerLeft, Offset(r.width * 2, 0));
        },
      ),
    ]) {
      CaptureExitChoice? result;
      await pumpHost(tester, (r) => result = r);
      await openDialog(tester);
      // 每一轮都必须是**真的**开了一个新弹窗 —— 否则后面几个 probe 会在
      // "根本没弹窗"的空树上空跑而假绿。
      expect(
        find.byType(CaptureExitDialog),
        findsOneWidget,
        reason: '"${probe.$1}"这一轮没开出弹窗,断言会是假的',
      );
      await probe.$2(tester);
      await tester.pumpAndSettle();
      expect(
        result,
        isNot(CaptureExitChoice.discardExit),
        reason: '默认态下"${probe.$1}"这一个动作就丢照片 = 破坏了两步确认',
      );
      // 探针若没关掉弹窗(拨开关/点标签/点标题都不关),这里收干净,
      // 否则残留的模态路由会盖住下一轮的 open 按钮。
      if (find.byType(CaptureExitDialog).evaluate().isNotEmpty) {
        await tester.tap(cancelBtn);
        await tester.pumpAndSettle();
      }
    }
  });

  // ⚠️ 双生子铁律:成对的属性,**两半都要钉**。这颗开关只有两个信号 —— 轨道
  // 颜色 和 滑纽位置。颜色上面已经钉了;位置如果不钉,把
  // `alignment: _save ? centerRight : centerLeft` 左右对调,整套测试照样全绿,
  // 而用户看到的开关语义已经反了。
  //
  // 量的是**滑纽相对轨道的真实几何**,不是把 alignment 属性读回来 ——
  // 读属性等于把实现原样抄一遍,对调实现时断言会跟着一起调,永远抓不到。
  testWidgets('滑纽位置:保存时在右、不保存时在左(量真实几何)', (tester) async {
    await pumpHost(tester, (_) {});
    await openDialog(tester);

    final track = tester.getRect(saveToggle);

    // 保存(默认,绿)⇒ 滑纽必须靠**右**。
    var knob = tester.getRect(saveKnob);
    expect(
      knob.center.dx,
      greaterThan(track.center.dx),
      reason: '保存态滑纽必须在轨道右半边(iOS 开关"开"在右)',
    );
    expect(
      track.right - knob.right,
      closeTo(2.0, 0.01),
      reason: '保存态滑纽应抵到轨道右内沿(_knobInset = 2)',
    );
    expect(knob.left, greaterThanOrEqualTo(track.left - 0.01));
    expect(knob.width, 27.0, reason: '滑纽直径 = 31 - 2×2');

    // 不保存(红)⇒ 滑纽必须靠**左**。
    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    knob = tester.getRect(saveKnob);
    expect(
      knob.center.dx,
      lessThan(track.center.dx),
      reason: '不保存态滑纽必须在轨道左半边',
    );
    expect(
      knob.left - track.left,
      closeTo(2.0, 0.01),
      reason: '不保存态滑纽应抵到轨道左内沿',
    );
    expect(knob.right, lessThanOrEqualTo(track.right + 0.01));
    expect(knob.width, 27.0);

    // 拨回去必须真的回到右边(不是单向卡死)。
    await tester.tap(saveToggle);
    await tester.pumpAndSettle();
    expect(tester.getRect(saveKnob).center.dx, greaterThan(track.center.dx));
  });

  // ⚠️ 阈值必须卡在**两个停靠位之间**,不能拿滑纽中心去比轨道边沿:滑纽中心
  // 在最左位也有 track.left + 15.5,永远大于 track.left + 2 —— 负向对照实测,
  // 把 duration 改成 Duration.zero 那版断言照样全绿。
  testWidgets('滑纽是滑过去的,不是瞬间跳(动画中途严格在两个停靠位之间)', (
    tester,
  ) async {
    await pumpHost(tester, (_) {});
    await openDialog(tester);
    final track = tester.getRect(saveToggle);
    // 两个停靠位的滑纽中心:内沿 2 + 半径 13.5 = 15.5。
    final rightEnd = track.right - 15.5;
    final leftEnd = track.left + 15.5;
    expect(tester.getRect(saveKnob).center.dx, closeTo(rightEnd, 0.01));

    await tester.tap(saveToggle);
    await tester.pump(); // 起帧
    await tester.pump(const Duration(milliseconds: 30)); // 180ms 里的早期一帧
    final midX = tester.getRect(saveKnob).center.dx;
    expect(
      midX,
      lessThan(rightEnd - 0.5),
      reason: '30ms 时应该已经离开右停靠位',
    );
    expect(
      midX,
      greaterThan(leftEnd + 0.5),
      reason: '30ms 就已经抵达左停靠位 = 根本没有动画(要求滑过去,不是 snap)',
    );
    // 位置和颜色是同一对双生子:滑纽在滑,轨道颜色也必须在渐变,不能一边滑
    // 一边瞬间变色。中途色必须既不是纯绿也不是纯红。
    final midColor = toggleTrackColor(tester);
    expect(
      midColor,
      isNot(kCaptureExitSaveGreen),
      reason: '轨道颜色在动画中途还停在绿 = 颜色没跟着动',
    );
    expect(
      midColor,
      isNot(kCaptureExitDangerRed),
      reason: '轨道颜色在动画中途已经是纯红 = 颜色是瞬间跳的,不是渐变',
    );

    await tester.pumpAndSettle();
    expect(tester.getRect(saveKnob).center.dx, closeTo(leftEnd, 0.01));
  });

  // ⚠️ 同一条双生子铁律,一层之上:"确定 / 取消"也是一对。用户**特意**把视觉
  // 权重倒置(实心黑那颗是取消,安全动作才该主导)。语义上面已经钉了,但样式
  // 和左右次序如果不钉,把两颗的样式对调、或把左右对调,整套测试照样全绿 ——
  // 而用户签决的那个"倒置"就被悄悄改回来了。(两条负向对照实测:M-A 样式对调、
  // M-B 左右对调,加这两个用例之前都是全绿。)
  testWidgets('确定=白底黑边黑字,取消=黑底白字(量渲染结果)', (tester) async {
    await pumpHost(tester, (_) {});
    await openDialog(tester);

    Material matOf(Finder f) => tester.widget<Material>(
      find.descendant(of: f, matching: find.byType(Material)),
    );
    Color? textColorOf(Finder f) =>
        (tester.renderObject(
                  find.descendant(of: f, matching: find.byType(RichText)),
                )
                as RenderParagraph)
            .text
            .style
            ?.color;

    final confirmMat = matOf(confirmBtn);
    expect(confirmMat.color, Colors.white, reason: '"确定"必须是白底');
    final side = (confirmMat.shape as OutlinedBorder?)?.side;
    expect(side?.color, Colors.black, reason: '"确定"必须有黑边');
    expect(side?.style, BorderStyle.solid);
    expect(side!.width, greaterThan(0));
    expect(textColorOf(confirmBtn), Colors.black, reason: '"确定"必须是黑字');

    final cancelMat = matOf(cancelBtn);
    expect(cancelMat.color, Colors.black, reason: '"取消"必须是黑底(实心那颗)');
    expect(textColorOf(cancelBtn), Colors.white, reason: '"取消"必须是白字');

    // 这一条是"倒置"本身:实心的那颗必须是取消,不是确定。
    expect(
      confirmMat.color == cancelMat.color,
      isFalse,
      reason: '两颗按钮不能同色,否则主次关系消失',
    );
  });

  testWidgets('按钮次序:确定在左,取消在右', (tester) async {
    await pumpHost(tester, (_) {});
    await openDialog(tester);
    final confirm = tester.getRect(confirmBtn);
    final cancel = tester.getRect(cancelBtn);
    expect(
      confirm.right,
      lessThanOrEqualTo(cancel.left + 0.01),
      reason: '"确定"必须整体在"取消"左边(用户给的顺序就是 确定 / 取消)',
    );
    expect(
      confirm.width,
      closeTo(cancel.width, 0.01),
      reason: '两颗等宽(各占一半),不能一颗被挤扁',
    );
  });

  // 393pt = iPhone 14 Pro 逻辑宽。标签 + 开关同一行很紧,这里量的是**真实布局
  // 矩形**。⚠️ 不能拿 `find.byType(CaptureExitDialog)` 当弹窗卡片:它的
  // RenderBox 是整屏 0..393,拿它做边界等于没做断言。真卡片是 Dialog 里那层
  // Material(insetPadding 40 ⇒ 40..353),内容列再内缩 20 ⇒ 60..333。
  testWidgets('393pt(iPhone 14 Pro):标签+开关一行放得下,开关不出卡片', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await pumpHost(tester, (_) {});
    await openDialog(tester);

    final card = tester.getRect(dialogCard);
    final toggle = tester.getRect(saveToggle);
    final label = tester.getRect(find.text('是否保存照片，方便下次补拍'));

    expect(card.width, 313.0, reason: '393 - 2×40(Dialog insetPadding)');
    expect(toggle.right, lessThanOrEqualTo(393.0), reason: '开关不能出屏');
    expect(
      toggle.right,
      lessThanOrEqualTo(card.right - 20 + 0.01),
      reason: '开关必须留在卡片 20pt 内边距里(内容右边界 333)',
    );
    expect(toggle.width, 51.0, reason: '开关不许被压扁');
    expect(
      label.right,
      lessThanOrEqualTo(toggle.left + 0.01),
      reason: '标签不能压到开关',
    );
    // 默认字号下这一行必须是**单行**(13 个汉字 @15pt ≈ 195pt,可用 210pt —— 
    // 只剩 15pt 余量,确实紧,但放得下)。行高 1.3 ⇒ 单行约 20pt。
    expect(
      label.height,
      lessThan(30.0),
      reason: '默认字号下标签应单行显示(高度 ~20);超过 30 说明已经折行了',
    );
    expect(tester.takeException(), isNull);
  });

  // 系统字号放大是这一行最可能溢出的场景:必须**折行**(标签是 Expanded),
  // 不能把开关挤出卡片,也不能压扁开关。
  testWidgets('393pt + 字号 1.6× ⇒ 标签折行,开关尺寸与位置不变', (tester) async {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        builder: (ctx, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 1.6,
          maxScaleFactor: 1.6,
          child: child!,
        ),
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const ValueKey<String>('open'),
                onPressed: () => showCaptureExitDialog(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await openDialog(tester);

    final card = tester.getRect(dialogCard);
    final toggle = tester.getRect(saveToggle);
    final label = tester.getRect(find.text('是否保存照片，方便下次补拍'));

    // ⚠️ 阈值要卡在"一行"和"两行"之间,不能只写 >30:1.6× 下**单行**高度就有
    // 15×1.6×1.3 ≈ 31.2pt,>30 会被一行拉长的文字蒙混过去(负向对照实测:
    // 把 Expanded 换成 softWrap:false 的 Flexible,>30 照样绿)。两行 ≈ 62pt。
    expect(
      label.height,
      greaterThan(40.0),
      reason: '1.6× 下必须折行成 ≥2 行(Expanded 兜住),而不是挤成一行',
    );
    expect(
      toggle.right,
      lessThanOrEqualTo(card.right - 20 + 0.01),
      reason: '放大字号也不能把开关挤出卡片',
    );
    expect(toggle.width, 51.0, reason: '开关不许被压扁');
    expect(label.right, lessThanOrEqualTo(toggle.left + 0.01));
    expect(tester.takeException(), isNull);
  });
}
