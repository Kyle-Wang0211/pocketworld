// 置顶栏:16:9 + 可翻页。
//
// [2026-08-24 用户签决] 用户圈出想要的大小,说「至少达到我画红圈的大小,
// 而且需要可以翻页」,并点名「去看看网易云音乐或者其他 app 的置顶栏」。
//
// 查到的行业口径:移动端 banner 主流 750×300(2.5:1);Material 建议比例集
// 是 16:9 / 3:2 / 4:3 / 1:1。用户画的红框约 840×450 ≈ 1.87:1,比 2.5:1 高
// 得多 —— 既然是"至少",取 16:9。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/design_system.dart';
import 'package:pocketworld_flutter/ui/vault_page.dart';

void main() {
  // 把测试画布设成 iPhone 14 Pro 的逻辑尺寸、dpr=1,于是上面所有断言里的
  // 数字直接就是 pt —— 不用再在注释里做一遍换算,也就不会算错。
  setUp(() {
    final v = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    v.physicalSize = const Size(393, 852);
    v.devicePixelRatio = 1.0;
    addTearDown(() {
      v.resetPhysicalSize();
      v.resetDevicePixelRatio();
    });
  });

  Future<void> pump(WidgetTester t, {bool autoPlay = false}) async {
    await t.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          // 复刻真实列表:整宽减去 ListView 左右各 16。
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AetherSpacing.lg),
            child: TopicCard(autoPlay: autoPlay),
          ),
        ),
      ),
    ));
    await t.pump(const Duration(milliseconds: 32));
  }

  group('尺寸(测试窗口已设成真机 393×852 @1x,下面的数字就是真 pt)', () {
    testWidgets('比例锁在 2.5:1 —— 用户看过真实尺寸后选的', (t) async {
      await pump(t);
      final s = t.getSize(find.byType(TopicCard));
      expect(s.width, closeTo(361, 0.5), reason: '393 减去左右各 16');
      expect(s.width / s.height, closeTo(2.5, 0.01));
      expect(kTopicCardAspect, 2.5);
    });

    testWidgets('361pt 宽下高 144pt', (t) async {
      await pump(t);
      expect(t.getSize(find.byType(TopicCard)).height, closeTo(144.4, 0.5));
    });

    testWidgets('比改之前的内容自适应高度明显更高', (t) async {
      await pump(t);
      // 改之前:padding 16×2 + 一行标题 + 8 + 两行 13/1.4 正文 ≈ 99pt。
      expect(
        t.getSize(find.byType(TopicCard)).height,
        greaterThan(120),
        reason: '原来约 99pt,用户嫌小',
      );
    });
  });

  // ⚠️ 这里**不再断言"不小于用户圈的红框(1.87:1)"**。
  //
  // 那条线来自隔着截图估出来的意向。四个候选按真实尺寸画成一页、用户在手机上
  // 看完之后选的是 2.5:1 —— 比他自己圈的那块还矮 49pt。看到实物后的判断,
  // 优先于看截图时的意向。

  group('144pt 的盒子装得下三页文案(中英都要)', () {
    for (final loc in ['zh', 'en']) {
      testWidgets('$loc:三页逐页翻过去,一次溢出都不许有', (t) async {
        await t.pumpWidget(MaterialApp(
          locale: Locale(loc),
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: AetherSpacing.lg),
                child: TopicCard(),
              ),
            ),
          ),
        ));
        await t.pump(const Duration(milliseconds: 32));

        for (var i = 0; i < 3; i++) {
          // RenderFlex 溢出会走 FlutterError.onError,被 tester 记成异常。
          expect(
            t.takeException(),
            isNull,
            reason: '第 ${i + 1} 页在 144pt 高的盒子里溢出了',
          );
          if (i < 2) {
            await t.drag(find.byType(PageView), const Offset(-400, 0));
            await t.pumpAndSettle();
          }
        }
      });
    }
  });

  group('翻页', () {
    testWidgets('有多页,且左滑能翻到下一页', (t) async {
      await pump(t);
      expect(find.text('本周精选'), findsOneWidget);

      await t.drag(find.byType(PageView), const Offset(-400, 0));
      await t.pumpAndSettle();

      expect(find.text('本周精选'), findsNothing);
      expect(find.text('怎么扫得更好'), findsOneWidget);
    });

    testWidgets('页数 ≥ 2 才画圆点,且圆点数 = 页数', (t) async {
      await pump(t);
      final dots = t.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(TopicCard),
          matching: find.byType(AnimatedContainer),
        ),
      );
      expect(dots.length, 3, reason: '当前三页');
    });

    testWidgets('当前页的圆点被拉长 —— 不然看不出在第几页', (t) async {
      await pump(t);
      List<double> widths() => t
          .widgetList<AnimatedContainer>(find.descendant(
            of: find.byType(TopicCard),
            matching: find.byType(AnimatedContainer),
          ))
          .map((c) => c.constraints!.maxWidth)
          .toList();

      expect(widths()[0], greaterThan(widths()[1]));

      await t.drag(find.byType(PageView), const Offset(-400, 0));
      await t.pumpAndSettle();
      expect(widths()[1], greaterThan(widths()[0]));
    });
  });

  group('自动翻页接热闸', () {
    testWidgets('autoPlay 默认 false —— 时间过去了也不翻', (t) async {
      // ⚠️ 这条原本写成"pumpAndSettle 不超时就算没 ticker",变异测试当场证明
      // 它是摆设:把默认改成 true、甚至把 `if (!autoPlay) return;` 整句删掉,
      // 它都照样过。两个原因 ——
      //   ① 裸的 Timer.periodic **不排帧**,pumpAndSettle 根本不等它;
      //   ② 测试结束拆 widget 树时 dispose 已经 cancel 了它,
      //      "A Timer is still pending" 也不会响。
      // 只有把时间真推过去、看页面动没动,才测得到。
      // ⚠️ 这里**不能用 pump() 辅助函数** —— 它总是显式传 autoPlay:,
      // 构造器的默认值就永远走不到。变异测试证明过:把默认改成 true,
      // 走 pump() 的版本照样全绿。测默认值就必须真的不传这个参数。
      await t.pumpWidget(MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AetherSpacing.lg),
              child: TopicCard(), // ← 不传 autoPlay
            ),
          ),
        ),
      ));
      await t.pump(const Duration(milliseconds: 32));
      await t.pump(kTopicAutoPlayInterval * 2);
      await t.pump(const Duration(milliseconds: 400));
      expect(
        find.text('本周精选'),
        findsOneWidget,
        reason: '默认不该自己翻 —— 自动轮播是叠在 live viewer 之上的第二个'
            '常驻 ticker,开不开必须由调用方接热闸决定',
      );
    });

    testWidgets('autoPlay=true 时到点自己翻页', (t) async {
      await pump(t, autoPlay: true);
      expect(find.text('本周精选'), findsOneWidget);

      await t.pump(kTopicAutoPlayInterval);
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('怎么扫得更好'), findsOneWidget);

      // 收尾:关掉自动翻页,否则测试体结束时报 Pending timers。
      await t.pumpWidget(const SizedBox.shrink());
    });
  });
}
