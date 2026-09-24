import 'package:flutter/material.dart';

import '../../dense/dense_work_state.dart';
import '../../l10n/app_localizations.dart';
import '../../official_capture/sfm_resume.dart' as official_resume;
import '../../official_util/device_log.dart';
import '../scan_record.dart';
import 'ar_capture_page.dart';
import 'sparse_cloud_viewer_page.dart';

/// [174] User 2026-09-24 「当用户点击下一步的时候，数据采集阶段就正式结束了」: once a work entered
/// the dense stage (dense_work_state.dart), no route back to capture or sparse reconstruction opens —
/// the gallery hides the entries; this is the backstop for any caller that still asks.
bool _refuseRecapture(String what, String captureDir) {
  final why = recaptureBlockedReason(captureDir);
  if (why == null) return false;
  DeviceLog.log('OfficialGalleryRoutes', '$what refused for $captureDir: $why');
  return true;
}

/// Opens the physically separate official resume route.
///
/// This deliberately mirrors the self-developed confirmation contract while
/// keeping every execution dependency inside the official capture stack. An
/// already-running official resume skips the confirmation and reattaches to
/// the same idempotent future in the reconstruct-only capture page.
Future<void> pushOfficialResumeRoute(
  BuildContext context,
  ScanRecord record,
  String captureDir, {
  required bool regenerate,
}) async {
  if (_refuseRecapture('resume/regenerate', captureDir)) return;
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
  await _pushReconstructOnly(context, captureDir);
}

/// [2026-09-11 用户裁决]「开始训练」进的就是**平时拍摄完那张页面**。
///
/// 原先进的是 SfmResumeWaitPage —— 一张只有转圈和一行字的黑页,和收尾那套
/// (进度 → 点云 → 选区 → 「完成」)完全两套东西。用户:「点击开始训练那就跟
/// 平时拍摄完进入的页面一样不就行了吗」。于是这里改推采集页的「只重建」档:
/// 不开相机,进来就跑重建,浮层/取色/持久化/封面全部与收尾逐字同路。
/// 续跑还是全量重喂由采集页用**与长按菜单同一对纯函数**自己判,不在这里重复。
Future<void> _pushReconstructOnly(BuildContext context, String captureDir) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          OfficialARCapturePage(reconstructOnlyCaptureDir: captureDir),
    ),
  );
}

/// [2026-09-08]「从存档照片重建」—— db 已经死透时的那条路。
///
/// 与 [pushOfficialResumeRoute] 是**同一个等待页、不同的腿**:确认文案和进度
/// 文案都必须换掉,因为"从已保存的重建数据恢复"对一个 db 只剩 4096 字节残骸
/// 的项目是句假话;这条路是把 photos_highres 里的存档照片重新喂一遍。
/// 耗时也不是一个量级(要重新提特征+匹配),所以文案里明说会更久。
Future<void> pushOfficialRebuildFromPhotosRoute(
  BuildContext context,
  ScanRecord record,
  String captureDir, {
  required int photoCount,
}) async {
  if (_refuseRecapture('rebuild-from-photos', captureDir)) return;
  if (!official_resume.isResumeInFlight(captureDir)) {
    final name = record.name.isEmpty ? '这次拍摄' : '「${record.name}」';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('从照片重建？'),
        content: Text(
          '$name的重建数据已经损坏，无法从中断处继续。\n\n'
          '但 $photoCount 张照片和每张的拍摄位置都完整保留着，'
          '可以用它们重新重建，无需重拍。\n'
          '这会比继续重建慢一些。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(AppL10n.of(dialogContext).meActionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('从照片重建'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
  }
  if (!context.mounted) return;
  await _pushReconstructOnly(context, captureDir);
}

/// Opens the official sparse-cloud viewer without a self-pipeline fallback.
Future<void> pushOfficialViewerRoute(
  BuildContext context,
  ScanRecord record,
  String plyPath,
) {
  // [SAME-PAGE 2026-09-15 用户签决] 再进入走**同一个页面**(拍完那页的查看
  // 模式):稀疏云 + 编辑 / 下一步 / 保存草稿,稠密在跑就看到它的进度。
  // 没有项目目录(老记录)才退回只读的 PLY 查看器。
  final dir = record.captureDir;
  if (dir != null && dir.isNotEmpty) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OfficialARCapturePage(reviewCaptureDir: dir),
      ),
    );
  }
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
  if (_refuseRecapture('extend (补拍)', captureDir)) return false;
  final added = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => OfficialARCapturePage(extendCaptureDir: captureDir),
    ),
  );
  return added == true;
}
