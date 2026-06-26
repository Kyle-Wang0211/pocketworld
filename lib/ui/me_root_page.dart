// MeRootPage — V1 (工具阶段) root: just the personal page + a bottom-right
// capture FAB. No bottom tab bar, no community feed.
//
// V1 product scope is Create + (your own) works only. The community feed
// (VaultPage) and the two-tab shell (AetherAppShell) stay in the codebase
// for V2 but are no longer routed to. After sign-in the user lands straight
// on MePage; the black "+" sphere (relocated from the old nav center to a
// bottom-right FAB) goes straight into AR capture.

import 'package:flutter/material.dart';

import 'capture/ar_capture_page.dart';
import 'design_system.dart';
import 'me_page.dart';

class MeRootPage extends StatefulWidget {
  const MeRootPage({super.key});

  @override
  State<MeRootPage> createState() => _MeRootPageState();
}

class _MeRootPageState extends State<MeRootPage> {
  // Nudges MePage to surface the freshly-created draft card after a capture.
  final ValueNotifier<int> _showDraftsSignal = ValueNotifier<int>(0);

  @override
  void dispose() {
    _showDraftsSignal.dispose();
    super.dispose();
  }

  /// Black "+" FAB → straight into AR capture (no 拍摄/上传 chooser sheet).
  /// ARCapturePage returns `true` when a scan kicked off → bump the signal so
  /// MePage shows the new draft right away.
  Future<void> _openCapture() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const ARCapturePage()),
    );
    if (!mounted) return;
    if (created == true) _showDraftsSignal.value += 1;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Stack(
      children: [
        Positioned.fill(
          child: MePage(showDraftsSignal: _showDraftsSignal),
        ),
        Positioned(
          right: 20,
          bottom: 24 + bottomInset,
          child: _CaptureFab(onTap: _openCapture),
        ),
      ],
    );
  }
}

/// The black spherical "+" capture button — same look as the old bottom-nav
/// center button, relocated to a bottom-right FAB and sized up as the V1
/// primary action.
class _CaptureFab extends StatelessWidget {
  final VoidCallback onTap;
  const _CaptureFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: AetherColors.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Icon(Icons.add_rounded, color: Colors.white, size: 30),
      ),
    );
  }
}
