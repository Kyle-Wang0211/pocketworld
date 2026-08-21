// capture_preview_rect.dart — 采集页取景矩形的几何单一事实源。
//
// 这里同时定义:底部常驻控件条的高度构成、取景矩形的位置、以及承载它的
// widget。三方共用(预览层、取景准星、布局守门测试),所以必须是同一份数字;
// 底部控件条的每个尺寸都从这里的常量取,widget 里不再手写魔数 —— 常量与真实
// 渲染高度脱钩过一次(160 vs 136),不能再来第二次。
//
// 单独成文件而不是塞进 capture_format.dart:那个文件自述是"E24 会话视频格式
// 的单一事实源",纯 Dart 语义,不该被 dart:ui / widgets 依赖污染。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../official_capture/capture_format.dart' show pwPreviewAspect;

// ─── 底部常驻控件条的尺寸构成 ────────────────────────────────────────
// 两图标灰底面板:上下内边距 8 + 开关按钮 44 = 60。
const double kCaptureIconPanelPadV = 8;
const double kCaptureToggleButtonSize = 44;
const double kCaptureIconPanelHeight =
    kCaptureIconPanelPadV * 2 + kCaptureToggleButtonSize;

/// 模式切换胶囊(手动 / 自动)的宽度。
///
/// [2026-08-21] 从 50 的单图标胶囊改成"两图标 + 滑块"的分段控件,必须变宽。
/// 68 不是随手取的:快门行两端各一个 [kCaptureShutterRowSideSlot] 槽、中间
/// 快门 [kCaptureShutterDiameter],剩下的空间被两个等权 Expanded 平分,
/// 左半再让出 4pt 右内边距 —— 14 Pro(393)剩 78.5,SE 2/3(375)剩 69.5。
/// 取 68 是"两台主力机型上都不触发 FittedBox 缩放"的最大整数,高度因此
/// 恒等于 [kCaptureToggleButtonSize],不会被缩成 40。
const double kCaptureModeToggleWidth = 68;

// 快门行:Row 的高度由最高子项决定,快门是三者里最高的那个。
// (kCaptureShutterRowHeight 必须 == 三者最大值,有测试盯着。)
const double kCaptureShutterDiameter = 76;

/// 相册徽章整体等比缩放系数。
///
/// [2026-08-21 用户] "等比例缩小" —— 所以徽章里**每一个**尺寸都由它乘出来:
/// 外框、圆角、描边、进度环线宽与起笔、两级字号、斜杠长度与粗细、以及数字
/// 的锚点内边距。单独压外框会把版式撑破,而且下次改比例又要重挑一遍数字。
const double kCaptureAlbumThumbScale = 0.8;
const double kCaptureAlbumThumbBaseSize = 60;
const double kCaptureAlbumThumbSize =
    kCaptureAlbumThumbBaseSize * kCaptureAlbumThumbScale;

/// 徽章圆角。进度环沿的就是这条圆角矩形边框,所以两处必须同源
/// —— 环的起笔偏移也是这个半径。
const double kCaptureAlbumThumbRadius = 14 * kCaptureAlbumThumbScale;

const double kCaptureFinishButtonSize = 56;
const double kCaptureShutterRowHeight = kCaptureShutterDiameter;

/// 快门行**两端等宽**的槽位:左槽装相册徽章、右槽装完成键。
///
/// 两槽必须等宽,否则中间那两个等权 Expanded 撑出来的快门就不在整排正中。
/// 取两者里更大的那个 —— 槽只需刚好装下自己的按钮,多出来的宽度是白白从
/// 模式切换胶囊嘴里抢走的空间(旧值写死 72,把胶囊的可用宽压到 62.5)。
const double kCaptureShutterRowSideSlot =
    kCaptureAlbumThumbSize > kCaptureFinishButtonSize
    ? kCaptureAlbumThumbSize
    : kCaptureFinishButtonSize;

/// 快门行下沿到屏幕物理底边的**最小总余量**。
///
/// 刘海机由 `SafeArea(top: false)` 让开的 34pt 就已满足,所以额外内边距是 0
/// —— 整排贴到 SafeArea 上沿,这正是用户要的"整排向下平移"。
/// 但 Home 键机型(iPhone SE 2/3)竖屏 `MediaQuery.padding.bottom == 0`,
/// SafeArea 让开的也是 **0pt**;[2026-07-27 UI-2] 把底部内边距 24→0 之后,
/// 这类机型上快门圆会贴死屏幕物理底边(实测快门下沿 y == 667 == 屏高),
/// 所以要自己补齐到这个余量。
///
/// 取 10 而不是更大:SE 2/3(375×667)上余量 >11 就会让画面贴不住面板顶边
/// (31 - margin ≥ safeTop 20 ⇒ margin ≤ 11),10 是同时保住"有余量"和
/// "贴底"的取值。有测试逐台盯着这两条。
const double kCaptureMinBottomClearance = 10;

/// 快门行的底部内边距 = 补齐 [kCaptureMinBottomClearance] 还差的那部分。
double captureShutterRowBottomPadding(double safeBottom) =>
    math.max(0, kCaptureMinBottomClearance - safeBottom);

/// 三层之间的分隔间距(画面 ↔ 灰底面板、灰底面板 ↔ 快门行,各一道)。
///
/// [2026-07-27 UI-3 签决] UI-2 让画面底边**紧贴**面板顶边、面板底边又紧贴
/// 快门圆,三层严丝合缝地叠在一起 —— 加上当时面板还是 90% 半透明
/// (`0xE6`),画面从面板顶部透出来,用户看到的就是"重叠"。现在:面板改全
/// 不透明,且三层之间留出确定的黑色间隔,任何两层都不再相接。
const double kCaptureSeparatorGap = 10;

/// 实际用的间距。空间不够时**先牺牲间距**(它只是装饰),而不是压窄画面、
/// 也不是让面板盖住画面 —— 优先级:画面尺寸 > 不重叠 > 间距。
double captureSeparatorGap({
  required Size screen,
  required double safeTop,
  required double safeBottom,
}) {
  final slack =
      screen.height -
      safeTop -
      safeBottom -
      captureShutterRowBottomPadding(safeBottom) -
      kCaptureShutterRowHeight -
      kCaptureIconPanelHeight -
      screen.width / pwPreviewAspect;
  if (slack <= 0) return 0;
  return math.min(kCaptureSeparatorGap, slack / 2);
}

/// 底部常驻控件条总高(灰底面板 + 层间距 + 快门行 + 该机型的底部内边距)。
/// 不含 Home 条安全区本身 —— 那部分由 SafeArea 另外让开。
double captureBottomControlsHeight({
  required Size screen,
  required double safeTop,
  required double safeBottom,
}) =>
    kCaptureIconPanelHeight +
    captureSeparatorGap(
      screen: screen,
      safeTop: safeTop,
      safeBottom: safeBottom,
    ) +
    kCaptureShutterRowHeight +
    captureShutterRowBottomPadding(safeBottom);

/// 灰底面板的顶边。画面底边落在它**上方一个 [captureSeparatorGap]** 处,
/// 不再相接。
double capturePanelTop({
  required Size screen,
  required double safeTop,
  required double safeBottom,
}) =>
    screen.height -
    captureBottomControlsHeight(
      screen: screen,
      safeTop: safeTop,
      safeBottom: safeBottom,
    ) -
    safeBottom;

/// 取景矩形顶边的位置(整屏坐标)。
///
/// [2026-07-27 UI-3 签决] 画面底边落在灰底面板顶边**上方一个间距**处 ——
/// 与面板不相接、更不重叠。
///
/// 位移沿革(基线别混):
/// - UI-1(整屏居中 + 控件条 160):14 Pro 画面顶边 96.5,底下空 37.5pt 黑缝。
/// - UI-2(贴底):顶边 158、底边 682 == 面板顶边,三层严丝合缝叠在一起。
/// - UI-3(本版,留间隔 + 面板转全不透明):顶边 138、底边 662,面板顶边 672
///   —— 画面上移 20pt、面板上移 10pt、快门行原地不动。
///
/// 兜底:垂直空间不够时先把间距让掉(见 [captureSeparatorGap]);还不够就把
/// 画面钉在状态栏下沿、让面板重新盖住画面底部 —— **绝不缩尺寸**
/// (见 [CapturePreviewRect])。已知会走到兜底分支的形态:iPad 竖屏
/// (声明支持:TARGETED_DEVICE_FAMILY = "1,2")、SE 2/3 开 Display Zoom
/// (320×568)、以及任何横屏(全仓没有 orientation lock,而 native 把
/// `.portrait` 写死进投影矩阵 —— 横屏是既有塌陷面,不是本次引入)。
double capturePreviewTop({
  required Size screen,
  required double safeTop,
  required double safeBottom,
}) {
  final previewHeight = screen.width / pwPreviewAspect; // 满宽 3:4
  final previewBottom =
      capturePanelTop(
        screen: screen,
        safeTop: safeTop,
        safeBottom: safeBottom,
      ) -
      captureSeparatorGap(
        screen: screen,
        safeTop: safeTop,
        safeBottom: safeBottom,
      );
  return math.max(safeTop, previewBottom - previewHeight);
}

/// 把 [child] 摆进取景矩形:**永远满宽、永远 3:4,任何情况下都不缩尺寸**。
///
/// 两条约束的分量不一样,别搞混(2026-07-27 多智能体复核纠正过一次口径):
///
/// - **3:4 画幅是硬约束**。native 的照片卡片几何按
///   `UIScreen.main.bounds.width × 4/3` 的视口算
///   (OfficialAetherARKitPlugin.swift `videoFormatMode == "hires43"` 分支,
///   [WYSIWYG 2026-07-19]),但它喂的是
///   `camera.projectionMatrix(for:viewportSize:)` —— 投影映射到 NDC,只由
///   **宽高比**决定,与视口绝对尺寸无关。所以画幅一旦不是 3:4,卡片才真的
///   与画面错位、所见即所得失效,且没有任何报错。
/// - **满宽是产品要求**(用满屏幕、左右不留黑边)。等比缩小虽然不会让卡片
///   错位,但会让画面莫名变窄、两侧多出黑边。
///
/// 实现上必须用 [Positioned] 的显式 width/height 给**紧约束**。
/// 曾用过 `Align + AspectRatio`,那是错的:`RenderAspectRatio` 在
/// `height > constraints.maxHeight` 时会 `height = maxHeight;
/// width = height * aspectRatio` —— 先缩高再**缩宽**(iPad 9.7 竖屏实测
/// 753 宽 vs 满宽 768,12.9 竖屏 1006.5 vs 1024)。注意 `SizedBox` 修不好
/// 这个(`RenderConstrainedBox` 会 `enforce(constraints)`,高度照样被夹),
/// 必须是 Stack + Positioned 这种能给出超出父约束的紧约束的组合。
/// 垂直放不下时正确的行为是溢出后被 [Stack] 裁掉 / 被底部控件条盖住,
/// 而不是把画面缩窄。
class CapturePreviewRect extends StatelessWidget {
  const CapturePreviewRect({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final width = screen.width;
    final height = width / pwPreviewAspect;
    final top = capturePreviewTop(
      screen: screen,
      safeTop: safe.top,
      safeBottom: safe.bottom,
    );
    return Stack(
      // 放不下就裁掉,不缩尺寸。
      clipBehavior: Clip.hardEdge,
      children: [
        Positioned(
          top: top,
          left: 0,
          width: width,
          height: height,
          child: child,
        ),
      ],
    );
  }
}
