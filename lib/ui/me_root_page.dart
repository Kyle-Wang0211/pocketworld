// MeRootPage — V1 (工具阶段) root: just the personal page + a bottom-right
// capture FAB. No bottom tab bar, no community feed.
//
// V1 product scope is Create + (your own) works only. The community feed
// (VaultPage) and the two-tab shell (AetherAppShell) stay in the codebase
// for V2 but are no longer routed to. After sign-in the user lands straight
// on MePage; the black "+" sphere (relocated from the old nav center to a
// bottom-right FAB) goes straight into AR capture.

import 'package:flutter/material.dart';

import 'draft_capture_shell.dart';
import 'me_page.dart';
import 'official_capture/ar_capture_page.dart';
import 'official_capture/official_gallery_routes.dart';
import 'scan_record.dart';

Future<void> _pushOfficialResumeRoute(
  BuildContext context,
  ScanRecord record,
  String captureDir, {
  required bool regenerate,
}) {
  return pushOfficialResumeRoute(
    context,
    record,
    captureDir,
    regenerate: regenerate,
  );
}

Future<void> _pushOfficialViewerRoute(
  BuildContext context,
  ScanRecord record,
  String plyPath,
) {
  return pushOfficialViewerRoute(context, record, plyPath);
}

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

  /// Black "+" FAB → the single production capture route.
  Future<void> _openCapture() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const OfficialARCapturePage()),
    );
    if (!mounted) return;
    if (created == true) _showDraftsSignal.value += 1;
  }

  @override
  Widget build(BuildContext context) {
    return DraftCaptureShell(
      onCaptureTap: _openCapture,
      child: MePage(
        showDraftsSignal: _showDraftsSignal,
        officialResumeRoute: _pushOfficialResumeRoute,
        officialViewerRoute: _pushOfficialViewerRoute,
      ),
    );
  }
}
