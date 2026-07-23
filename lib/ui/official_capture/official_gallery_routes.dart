import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/sfm_resume.dart' as official_resume;
import '../scan_record.dart';
import 'sfm_resume_wait_page.dart';
import 'sparse_cloud_viewer_page.dart';

/// Opens the physically separate official resume route.
///
/// This deliberately mirrors the self-developed confirmation contract while
/// keeping every execution dependency inside the official capture stack. An
/// already-running official resume skips the confirmation and reattaches to
/// the same idempotent future in [SfmResumeWaitPage].
Future<void> pushOfficialResumeRoute(
  BuildContext context,
  ScanRecord record,
  String captureDir, {
  required bool regenerate,
}) async {
  if (!official_resume.isResumeInFlight(captureDir)) {
    final name = record.name.isEmpty ? '这次拍摄' : '「${record.name}」';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(regenerate ? '重新重建？' : '继续重建？'),
        content: Text(
          regenerate
              ? '将用$name已保存的重建数据重新生成点云，完成后覆盖现有点云，无需重拍。'
              : '$name的点云还没有生成。拍摄数据已完整保存，可以从中断处继续重建，无需重拍。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppL10n.of(dialogContext).meActionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(regenerate ? '重新重建' : '继续重建'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          SfmResumeWaitPage(captureDir: captureDir, title: record.name),
    ),
  );
}

/// Opens the official sparse-cloud viewer without a self-pipeline fallback.
Future<void> pushOfficialViewerRoute(
  BuildContext context,
  ScanRecord record,
  String plyPath,
) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SparseCloudViewerPage(
        plyPath: plyPath,
        title: record.name.isEmpty ? '稀疏点云' : record.name,
      ),
    ),
  );
}
