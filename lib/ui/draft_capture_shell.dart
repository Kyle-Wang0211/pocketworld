import 'dart:async';

import 'package:flutter/material.dart';

import 'design_system.dart';

/// Shared chrome for every page that presents the user's Drafts.
///
/// The capture action is always visible. Its owner decides whether a tap opens
/// the capture chooser or reports that an existing reconstruction still owns
/// the single reconstruction slot.
class DraftCaptureShell extends StatefulWidget {
  const DraftCaptureShell({
    super.key,
    required this.child,
    required this.onCaptureTap,
    this.blockedMessage,
  });

  final Widget child;
  final VoidCallback onCaptureTap;
  final String? blockedMessage;

  @override
  State<DraftCaptureShell> createState() => _DraftCaptureShellState();
}

class _DraftCaptureShellState extends State<DraftCaptureShell> {
  Timer? _noticeTimer;
  bool _showBlockedNotice = false;

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }

  void _onCaptureTap() {
    if (widget.blockedMessage == null) {
      widget.onCaptureTap();
      return;
    }
    _noticeTimer?.cancel();
    setState(() => _showBlockedNotice = true);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _showBlockedNotice = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Stack(
      children: [
        Positioned.fill(child: widget.child),
        if (_showBlockedNotice)
          Positioned(
            left: 24,
            right: 24,
            bottom: 104 + bottomInset,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  key: const ValueKey<String>('draft-capture-blocked-notice'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    widget.blockedMessage!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          right: 20,
          bottom: 24 + bottomInset,
          child: _DraftCaptureFab(onTap: _onCaptureTap),
        ),
      ],
    );
  }
}

class _DraftCaptureFab extends StatelessWidget {
  const _DraftCaptureFab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey<String>('draft-capture-fab'),
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
