// official_capture_preview_layout_test.dart
//
// [2026-07-27 UI-2] 采集页取景矩形的几何守门。
//
// ⚠️ 这个文件的第一版是**假守门**:断言写成 `previewHeight == width * 4/3`,
// 而 previewHeight 本身就是 `width / pwPreviewAspect` 算出来的 —— 恒真式,
// 任何实现都不会让它变红。它因此完整放过了当时代码里真实存在的压窄 bug
// (Align + AspectRatio 在可用高不足时会 `height = maxHeight;
// width = height * aspectRatio`,把画面缩窄)。
//
// 所以现在一律 pumpWidget 真渲染,断言**实际渲染出来的矩形**:
//   1. 画面永远满宽、永远 3:4 —— native 卡片几何按 UIScreen.width×4/3 硬算,
//      预览被压窄 = WYSIWYG 静默失效。这条在任何屏幕形态下都不许破。
//   2. 空间够时,画面底边**恰好等于**灰底面板顶边(不重叠、不留缝)。
//   3. 画面顶边不进状态栏。
//   4. 快门行下沿:刘海机贴 SafeArea 上沿(整排下移到位),Home 键机型保留
//      最小外边距(不贴死屏幕物理底边)。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/capture_format.dart';
import 'package:pocketworld_flutter/ui/official_capture/capture_preview_rect.dart';

class _Device {
  const _Device(this.name, this.size, this.safeTop, this.safeBottom);
  final String name;
  final Size size;
  final double safeTop;
  final double safeBottom;

  EdgeInsets get padding => EdgeInsets.only(top: safeTop, bottom: safeBottom);
}

/// 空间充裕、能吃满整个分隔间距的现役 iPhone(竖屏)。
const kRoomy = <_Device>[
  _Device('iPhone 14 Pro', Size(393, 852), 59, 34),
  _Device('iPhone XR/11', Size(414, 896), 44, 34),
  _Device('iPhone 13 mini', Size(375, 812), 50, 34),
  _Device('iPhone 16 Pro Max', Size(440, 956), 62, 34),
];

/// 装得下但余量极窄的机型:SE 2/3 全屏只剩 1pt 富余,间距会被自动让到 0.5。
/// 要求仍然是**不重叠**(用户原话),只是那道缝小到看不见 —— 物理上限,
/// 再多就得压窄画面(绝对禁止)或让面板盖住画面。
const kTight = <_Device>[_Device('iPhone SE 2/3', Size(375, 667), 20, 0)];

const kFits = <_Device>[...kRoomy, ...kTight];

/// 贴不下、必须走兜底分支的形态。这里只要求"绝不压窄",允许底部被盖。
/// iPad 是**声明支持**的机型(TARGETED_DEVICE_FAMILY = "1,2"),不是假想。
const kOverflows = <_Device>[
  _Device('iPad 9.7/Air 竖屏', Size(768, 1024), 20, 0),
  _Device('iPad Pro 12.9 竖屏', Size(1024, 1366), 24, 20),
  _Device('iPhone SE Display Zoom', Size(320, 568), 20, 0),
  _Device('iPhone 14 Pro 横屏', Size(852, 393), 0, 21),
];

const _probeKey = ValueKey<String>('preview-rect-probe');

Future<Rect> _pumpPreviewRect(WidgetTester tester, _Device d) async {
  tester.view.physicalSize = d.size * tester.view.devicePixelRatio;
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = d.size;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: d.size, padding: d.padding),
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: CapturePreviewRect(
                child: ColoredBox(color: Color(0xFF00FF00), key: _probeKey),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  return tester.getRect(find.byKey(_probeKey));
}

void main() {
  for (final d in [...kFits, ...kOverflows]) {
    testWidgets('${d.name}: 渲染出来的画面永远满宽 3:4(绝不压窄)', (tester) async {
      final rect = await _pumpPreviewRect(tester, d);

      // 不变量 1 —— 这次是对**真实渲染尺寸**断言,不是恒真式。
      expect(
        rect.width,
        closeTo(d.size.width, 0.01),
        reason:
            '${d.name}: 画面被压窄到 ${rect.width},native 卡片仍按 '
            '${d.size.width} 算 → WYSIWYG 失效',
      );
      expect(
        rect.height,
        closeTo(d.size.width / pwPreviewAspect, 0.01),
        reason: '${d.name}: 画幅不再是 3:4',
      );
      // 不变量 3
      expect(rect.top, greaterThanOrEqualTo(d.safeTop - 0.01), reason: d.name);
      expect(rect.left, closeTo(0, 0.01), reason: d.name);
    });
  }

  for (final d in kFits) {
    testWidgets('${d.name}: 画面与灰底面板之间留出确定间隔,连相接都不许', (tester) async {
      final rect = await _pumpPreviewRect(tester, d);
      final panelTop = capturePanelTop(
        screen: d.size,
        safeTop: d.safeTop,
        safeBottom: d.safeBottom,
      );
      final gap = captureSeparatorGap(
        screen: d.size,
        safeTop: d.safeTop,
        safeBottom: d.safeBottom,
      );

      // 不变量 2([UI-3] 用户原话:不能再跟灰底栏有任何重叠)—— 不但不重叠,
      // 还隔着一个 gap,连"相接"都不允许(相接 + 半透明就是上一版被看成
      // "重叠"的根因)。
      expect(
        rect.bottom,
        closeTo(panelTop - gap, 0.01),
        reason: '${d.name}: 画面底边 ${rect.bottom} vs 面板顶边 $panelTop(应隔 $gap)',
      );
      expect(rect.bottom, lessThan(panelTop), reason: '${d.name}: 相接/重叠了');
      expect(gap, greaterThan(0), reason: '${d.name}: 间距被让光了');
      expect(rect.top, greaterThanOrEqualTo(d.safeTop), reason: d.name);
    });
  }

  for (final d in kRoomy) {
    test('${d.name}: 空间充裕,吃满整个分隔间距', () {
      expect(
        captureSeparatorGap(
          screen: d.size,
          safeTop: d.safeTop,
          safeBottom: d.safeBottom,
        ),
        kCaptureSeparatorGap,
        reason: d.name,
      );
    });
  }

  for (final d in kOverflows) {
    testWidgets('${d.name}: 放不下时先让间距、再钉状态栏,始终不压窄', (tester) async {
      final rect = await _pumpPreviewRect(tester, d);
      final panelTop = capturePanelTop(
        screen: d.size,
        safeTop: d.safeTop,
        safeBottom: d.safeBottom,
      );

      // 降级第一步:间距先被让光(它只是装饰,优先级最低)。
      expect(
        captureSeparatorGap(
          screen: d.size,
          safeTop: d.safeTop,
          safeBottom: d.safeBottom,
        ),
        0,
        reason: d.name,
      );
      // 降级第二步:钉在状态栏下沿,承认底部被面板盖住。
      expect(rect.top, closeTo(d.safeTop, 0.01), reason: d.name);
      expect(rect.bottom, greaterThan(panelTop), reason: d.name);
      // 但宽度一寸没让 —— 上面那组已逐台断言过。
    });
  }

  test('灰底面板必须全不透明', () {
    // [UI-3] 之前是 0xE6(90%),画面从面板顶部透出来 —— 用户看到的
    // "画面和灰底重叠"有一半是这个造成的,不是几何。
    const panelColor = Color(0xFF1C1C20);
    expect(panelColor.a, 1.0);
    expect(
      File('lib/ui/official_capture/ar_capture_page.dart').readAsStringSync(),
      contains('color: const Color(0xFF1C1C20)'),
    );
  });

  test('底部控件条高度由各部件常量算出,不是手抄的魔数', () {
    // 灰底面板 = 上下内边距 + 开关按钮。
    expect(
      kCaptureIconPanelHeight,
      kCaptureIconPanelPadV * 2 + kCaptureToggleButtonSize,
    );
    // 快门行高 = 行内最高子项。相册/完成任何一个长过快门,这里就会红,
    // 提醒同步改 —— 这是"常量与真实高度脱钩"那次事故的守门。
    expect(
      kCaptureShutterRowHeight,
      [
        kCaptureShutterDiameter,
        kCaptureAlbumThumbSize,
        kCaptureFinishButtonSize,
      ].reduce((a, b) => a > b ? a : b),
    );
    // 刘海机:SafeArea 的 34pt 已超过最小余量,额外内边距 0 —— 整排贴到
    // SafeArea 上沿,这就是 UI-2"向下平移"的位移来源。
    expect(captureShutterRowBottomPadding(34), 0);
    // Home 键机型:SafeArea 让开的是 0,必须自己补齐到最小余量,
    // 否则快门圆贴死屏幕物理底边。
    expect(captureShutterRowBottomPadding(0), kCaptureMinBottomClearance);
  });

  test('14 Pro 实数:快门行原地,灰底上移 10,画面上移 20', () {
    const d = _Device('iPhone 14 Pro', Size(393, 852), 59, 34);
    final gap = captureSeparatorGap(
      screen: d.size,
      safeTop: d.safeTop,
      safeBottom: d.safeBottom,
    );
    final panelTop = capturePanelTop(
      screen: d.size,
      safeTop: d.safeTop,
      safeBottom: d.safeBottom,
    );
    final top = capturePreviewTop(
      screen: d.size,
      safeTop: d.safeTop,
      safeBottom: d.safeBottom,
    );

    expect(gap, kCaptureSeparatorGap); // 10,空间充裕不需要让
    // 快门行下沿仍贴 SafeArea 上沿(UI-2 那次的下移保持不动)。
    expect(d.size.height - d.safeBottom, 818);
    // 灰底面板:UI-2 是 682,现在被间隔顶上去 10 → 672。
    expect(panelTop, closeTo(672, 0.01));
    // 画面:UI-2 是 158/682,现在 138/662,底边距面板顶边正好 10。
    expect(top, closeTo(138, 0.01));
    expect(top + d.size.width / pwPreviewAspect, closeTo(662, 0.01));
    expect(
      panelTop - (top + d.size.width / pwPreviewAspect),
      closeTo(10, 0.01),
    );
  });
}
