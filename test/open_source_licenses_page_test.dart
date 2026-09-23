import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/ui/legal/open_source_licenses_page.dart';

/// [OSS-NOTICE 2026-09-23] 这一组是**真读资产包**的闸,和
/// third_party_notice_coverage_test.dart 的文件检查互补。
///
/// 那一组查的是 pubspec 写没写对;这一组查的是写对了之后东西真的进得了包、
/// 页面真的渲染得出来。缺口本身就长这个样子 —— 声明在仓里躺得好好的,
/// 只是从来没到过设备上。flutter test 的 rootBundle 读的是
/// build/unit_test_assets/,那是 Flutter 按 pubspec 真打出来的一份。
Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: child,
    );

/// 泵到 [finder] 出现为止。
///
/// 两件事都得照顾到,所以不能用 pumpAndSettle,也不能只用 pump:
///   · 页面在等资产时显示 CircularProgressIndicator —— 那东西**永远不会
///     settle**,pumpAndSettle 必然超时;
///   · 资产读取是**真 IO**,而 testWidgets 的 pump 只推进 fake async,
///     推不动真 IO —— 只 pump 的话 future 永远不完成。
/// 所以每一轮先用 runAsync 把真事件循环放行一小段,再 pump 一帧。
/// [minMatches] 用来区分"新页面出来了"和"上一层还在树里":Navigator 不会
/// 拆掉被压在下面的路由,所以子页面出现时同类 widget 的**数量**会变,而不是
/// 从无到有。(别用 finder.at(n) 当等待条件 —— 数量不够时它直接抛
/// RangeError,不是返回空。)
Future<void> _pumpUntil(
  WidgetTester tester,
  Finder finder, {
  int minMatches = 1,
  int maxRounds = 60,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (finder.evaluate().length >= minMatches) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  fail('timed out waiting for $minMatches+ of $finder');
}

/// 首页"许可正文"那一行的副标题里带着清单的真实条数(来自 AssetManifest)。
/// 列表页是懒构建的,数不出总数,所以从这里读。
int _countFromSubtitle(WidgetTester tester, AppL10n l) {
  final title = find.text(l.legalOpenSourceLicenseTexts);
  expect(title, findsOneWidget);
  final subtitle = tester
      .widgetList<Text>(find.descendant(
        of: find.ancestor(of: title, matching: find.byType(Column)).first,
        matching: find.byType(Text),
      ))
      .map((t) => t.data ?? '')
      .firstWhere((d) => RegExp(r'\d').hasMatch(d), orElse: () => '');
  final digits = RegExp(r'\d+').firstMatch(subtitle);
  expect(digits, isNotNull, reason: 'subtitle carried no count: "$subtitle"');
  return int.parse(digits!.group(0)!);
}

void main() {
  // 资产读取走的是真 IO。testWidgets 里的 pump 只推进 fake async,推不动真
  // IO,所以未预热时 future 能不能在几帧内完成纯看运气 —— 第一次跑就是
  // 四条里一条侥幸过、三条超时。这里先在真事件循环上把要用到的资产全读一
  // 遍;rootBundle.loadString 默认带缓存,之后页面里的读取就能在微任务里
  // 立即完成,pump 推得动了。
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await rootBundle.loadString(kThirdPartyNoticesAsset);
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    for (final path in manifest.listAssets()) {
      if (kLicenseTextPrefixes.any(path.startsWith)) {
        await rootBundle.loadString(path);
      }
    }
  });

  testWidgets('声明索引真的在资产包里,并渲染出具名组件', (tester) async {
    await tester.pumpWidget(_wrap(const OpenSourceLicensesPage()));
    await _pumpUntil(tester, find.byType(SelectableText));

    // 索引原文渲染出来 = THIRD_PARTY_NOTICES 确实打进了包。
    // 挑的这几个都是"只有真读到内容才会出现"的串。
    final notices = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    final text = notices.data!;
    expect(text, contains('Thermion and Google Filament'));
    expect(text, contains('dee94b56db1518530a12de8fd7af1d3c05c3a680'));
    expect(text, contains('XRSLAM'));
    expect(text, contains('Potree'));
  });

  testWidgets('两条链的入口都在:pub 包声明 + 逐份许可正文', (tester) async {
    await tester.pumpWidget(_wrap(const OpenSourceLicensesPage()));
    await _pumpUntil(tester, find.byType(SelectableText));

    final l = AppL10n.of(
      tester.element(find.byType(OpenSourceLicensesPage)),
    );
    expect(find.text(l.legalOpenSourceFlutterPackages), findsOneWidget);
    expect(find.text(l.legalOpenSourceLicenseTexts), findsOneWidget);
  });

  testWidgets('pub 包那条链点得开 —— Flutter 内建的 LicensePage 真的弹出来',
      (tester) async {
    // ⚠️ 这条是负对照 NC-C 逼出来的。原本我在 coverage 测里用
    // `expect(page, contains('showLicensePage'))` 把关,结果把调用换成空实现
    // 之后测试照样通过 —— 因为文件头注里就写着 showLicensePage 这个词。
    // 字符串 contains 判不了"有没有真的调",得让它真的弹出来。
    await tester.pumpWidget(_wrap(const OpenSourceLicensesPage()));
    await _pumpUntil(tester, find.byType(SelectableText));

    final l = AppL10n.of(
      tester.element(find.byType(OpenSourceLicensesPage)),
    );
    await tester.tap(find.text(l.legalOpenSourceFlutterPackages));
    await _pumpUntil(tester, find.byType(LicensePage));

    expect(
      find.byType(LicensePage),
      findsOneWidget,
      reason: 'thermion 等全部 pub 包的许可只存在于 Flutter 生成的 NOTICES '
          'blob 里;不把 LicensePage 接出来,用户就永远读不到',
    );
  });

  testWidgets('许可正文清单非空,且每一份都点得开、读得到内容', (tester) async {
    await tester.pumpWidget(_wrap(const OpenSourceLicensesPage()));
    await _pumpUntil(tester, find.byType(SelectableText));

    final l = AppL10n.of(
      tester.element(find.byType(OpenSourceLicensesPage)),
    );
    final listedCount = _countFromSubtitle(tester, l);

    await tester.tap(find.text(l.legalOpenSourceLicenseTexts));
    await _pumpUntil(tester, find.byType(ListTile));

    // 清单从 AssetManifest 读。空清单意味着许可正文没进包 —— 那正是
    // 2026-09-23 之前 Filament 的处境,所以这里不能允许空。
    final tiles = find.byType(ListTile);
    expect(tiles, findsWidgets);

    // ⚠️ 不能数 ListTile:ListView.separated 是懒构建的,只建可见的那几个
    // (实测 8 个),数出来的是视口高度不是清单长度。真正的条数在首页那一行
    // 的副标题里,它来自 AssetManifest 的完整清单。
    expect(
      listedCount,
      greaterThanOrEqualTo(35),
      reason: 'assets/licenses/ 16 份 + JXL 5 + NativeCore 13 + lepton 4 + '
          'Zpaq 1,少于这个数说明有目录没进包',
    );

    // 随便点开第一份,必须真有正文。
    // 用 .last 不是 .first —— Navigator 把上一层路由留在树里,.first 会取到
    // 声明索引页那个 SelectableText。
    await tester.tap(tiles.first);
    await _pumpUntil(tester, find.byType(SelectableText), minMatches: 2);
    final body = tester.widget<SelectableText>(
      find.byType(SelectableText).last,
    );
    expect(body.data, isNotEmpty);
    expect(body.data!.length, greaterThan(100));
  });

  testWidgets('Filament 的许可正文点得开,且是 Apache-2.0 原文', (tester) async {
    await tester.pumpWidget(_wrap(const OpenSourceLicensesPage()));
    await _pumpUntil(tester, find.byType(SelectableText));

    final l = AppL10n.of(
      tester.element(find.byType(OpenSourceLicensesPage)),
    );
    await tester.tap(find.text(l.legalOpenSourceLicenseTexts));
    await _pumpUntil(tester, find.byType(ListTile));

    final filament = find.text('filament-LICENSE');
    expect(filament, findsOneWidget);
    await tester.tap(filament);
    await _pumpUntil(tester, find.byType(SelectableText), minMatches: 2);

    final body = tester.widget<SelectableText>(
      find.byType(SelectableText).last,
    );
    expect(body.data, contains('Apache License'));
    expect(body.data, contains('The Android Open Source Project'));
  });
}
