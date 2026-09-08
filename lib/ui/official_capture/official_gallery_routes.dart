import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/sfm_resume.dart' as official_resume;
import '../scan_record.dart';
import 'ar_capture_page.dart';
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

/// [2026-09-08 追加拍摄] 往一个**已有项目**里补拍。
///
/// 复刻 RealityScan 的做法:新照片就是新照片,丢进同一个工程再跑一次对齐;
/// 坐标系不靠任何厂商 AR SDK 接续,由 SfM 按图像重新对齐(RS 官方文档
/// "will continue from the previous state")。这里只负责把已有的 captureDir
/// 递给采集页 —— 复用目录/照片续号在 CaptureSession 里,整组重建由现有的
/// 「开始训练」(resume)完成:worker 的 resume 分支本来就是照整个 db 重建的
/// (sfm_live_recon.dart:2295 注释:image_path 为空 ⇒ 全部状态来自 db)。
///
/// 返回是否真的补了照片(采集页 pop 回 true),调用方据此刷新卡片。
Future<bool> pushOfficialExtendRoute(
  BuildContext context,
  ScanRecord record,
  String captureDir,
) async {
  final added = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => OfficialARCapturePage(extendCaptureDir: captureDir),
    ),
  );
  return added == true;
}
