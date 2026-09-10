// AetherAppShell — 3-element bottom nav: Community (9-grid icon) ·
// CREATE button (filled black circle, fully inside the bar) · Me
// (person icon).
//
// "Create" — placeholder while we port Aether3D's capture pipeline
// (ARKit + DomeCoverageMap + FrameAnalyzer quality detection + A100
// remote pipeline) into Flutter. The previous Dawn-backed CapturePage
// + CaptureModeSelectionPage have been removed (2026-04-29).
//
// Cross-platform: pure Flutter widgets, no native code. Bottom nav is
// the same 76 px tall on iOS / Android / HarmonyOS / Web.

import 'package:flutter/material.dart';

import 'design_system.dart';
import 'me_page.dart';
import 'official_capture/ar_capture_page.dart';
import 'official_capture/official_gallery_routes.dart';
import 'vault_page.dart';

// 2026-04-28 IA reshape: bottom nav simplified to two tabs — Community
// (public feed of everyone's works) and Me (Instagram-style profile that
// includes the user's own works grid). The "Vault" tab is gone; own
// works live under Me, public works live under Community.
enum AetherRootTab { community, me }

extension _TabMeta on AetherRootTab {
  // Tab labels removed in 2026-04-29 redesign — bottom nav is icons-only
  // to mirror Polycam / Instagram. Localized strings still live in
  // AppL10n.tabCommunity / .tabMe in case we need them on the Me page
  // header or for accessibility.

  IconData get icon {
    switch (this) {
      case AetherRootTab.community:
        return Icons.apps_rounded; // 9-grid (community grid view)
      case AetherRootTab.me:
        return Icons.person_outline_rounded;
    }
  }

  IconData get iconFilled {
    switch (this) {
      case AetherRootTab.community:
        return Icons.apps_rounded; // same shape; selected state via color
      case AetherRootTab.me:
        return Icons.person_rounded;
    }
  }
}

class AetherAppShell extends StatefulWidget {
  const AetherAppShell({super.key});

  @override
  State<AetherAppShell> createState() => _AetherAppShellState();
}

class _AetherAppShellState extends State<AetherAppShell> {
  AetherRootTab _tab = AetherRootTab.community;
  final ValueNotifier<int> _showDraftsSignal = ValueNotifier<int>(0);

  @override
  void dispose() {
    _showDraftsSignal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      extendBody: true,
      body: IndexedStack(
        index: AetherRootTab.values.indexOf(_tab),
        children: [
          const VaultPage(),
          // [2026-08-17 实机] 这两条路由**必须**传,否则「我的」页里所有
          // 官方采集的作品点下去都毫无反应:
          //   MePage → dispatchSparseCloudViewerForPipeline
          //     case official: if (openOfficial == null) return false;  ← 静默
          //
          // 漏接的来历:MeRootPage(V1 工具阶段的 root)传了这两条,而它头上
          // 写着"两 tab shell (AetherAppShell) 留给 V2 但不再被路由到"。产品
          // 回到两 tab 形态后,MeRootPage 变成没人用的死代码,它接的线也就跟着
          // 断了 —— AetherAppShell 这边从来没补上。
          MePage(
            showDraftsSignal: _showDraftsSignal,
            officialResumeRoute: pushOfficialResumeRoute,
            officialRebuildFromPhotosRoute:
                pushOfficialRebuildFromPhotosRoute,
            officialViewerRoute: pushOfficialViewerRoute,
            officialExtendRoute: pushOfficialExtendRoute,
          ),
        ],
      ),
      bottomNavigationBar: _BottomTabBar(
        current: _tab,
        onChange: (t) => setState(() => _tab = t),
        onCreate: _openCapture,
      ),
    );
  }

  /// 底部栏的「+」**直接**进采集页。
  ///
  /// [2026-08-21 用户签决] 原先「+」先弹一张 拍摄 / 上传 的底部选单;上传
  /// 那条腿(GLB 导入,`_importGlb` → [ImportGlbCoordinator])连同选单一起
  /// 撤掉了 —— 创作只有拍摄一条路,少一次点击。
  ///
  /// ⚠️ 撤的是**入口**,不是读路径:历史上导入过的 GLB 作品照旧要能打开 ——
  /// `lib/ui/me/my_work_detail_page.dart` 的 legacy 分支原样留着,它读的是
  /// 记录里已持久化的 `artifactPath`,不依赖任何运行时协调器。
  ///
  /// [2026-08-22] `lib/me/import_glb_coordinator.dart` 已删除:入口撤掉后它
  /// 的调用点归零,而它只是当初**写入** artifactPath 的人,读路径不经过它。
  Future<void> _openCapture() async {
    // CapturePage returns `true` when the user tapped Stop and the
    // upload kicked off — that's our cue to flip the bottom nav to
    // Me so the freshly-created scan card is visible right away.
    final shouldShowMe = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const OfficialARCapturePage()),
    );
    if (!mounted) return;
    if (shouldShowMe == true) {
      if (_tab != AetherRootTab.me) {
        setState(() => _tab = AetherRootTab.me);
      }
      _showDraftsSignal.value += 1;
    }
  }
}

class _BottomTabBar extends StatelessWidget {
  final AetherRootTab current;
  final ValueChanged<AetherRootTab> onChange;
  final VoidCallback onCreate;

  const _BottomTabBar({
    required this.current,
    required this.onChange,
    required this.onCreate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas.withValues(alpha: 0.96),
        border: const Border(
          top: BorderSide(color: AetherColors.border, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        bottom: true,
        child: SizedBox(
          // Taller bar (2026-06-24): icon row 56→72 + bottom safe-area inset.
          // The old 56px compact bar sat flush against the home indicator and
          // was too thin — easy to miss the tab icons and mis-tap the feed
          // content above. Bigger tap targets + proper iOS home-indicator
          // padding.
          height: 72,
          child: Row(
            children: [
              Expanded(
                child: _TabItem(
                  tab: AetherRootTab.community,
                  selected: current == AetherRootTab.community,
                  onTap: () => onChange(AetherRootTab.community),
                ),
              ),
              _CenterCreateButton(onTap: onCreate),
              Expanded(
                child: _TabItem(
                  tab: AetherRootTab.me,
                  selected: current == AetherRootTab.me,
                  onTap: () => onChange(AetherRootTab.me),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterCreateButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CenterCreateButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AetherColors.primary,
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final AetherRootTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AetherColors.primary : AetherColors.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: Icon(
          selected ? tab.iconFilled : tab.icon,
          size: 26,
          color: color,
        ),
      ),
    );
  }
}
