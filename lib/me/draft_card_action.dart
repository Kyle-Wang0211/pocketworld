// draft_card_action.dart — 草稿/项目任务卡点击的路由决策(纯函数)。
//
// 从 me_page.dart 的 _onTap 提纯出来,原因:
//   1. 契约(handoff §0:9)"finalize 进行中点同一任务卡必须回原等待页,
//      不得启动第二个重建"在真机上踩坏过一次 —— 决策必须可被纯 Dart VM
//      断言脚本(tool/draft_reentry_check.dart)穷举验证,不依赖 widget 树。
//   2. 决策优先级本身就是产品契约,集中一处防止将来散落回 if 链。
//
// 零 Flutter 依赖:入参全部是调用方(me_page)已经算好的布尔/字符串,
// 文件系统探测(sfm_sparse.ply / sfm_live.db 是否存在)留在调用方。

/// 点击一张任务卡后应发生什么(按契约优先级判定,见 [draftCardActionFor])。
enum DraftCardAction {
  /// 这张卡就是当前正在重建的 capture —— 回到原等待页看进度。
  /// 绝不启动第二个重建,绝不打开半成品 PLY。
  reopenActiveReconstruction,

  /// 已有完成的 GLB 成品 —— 打开作品详情页。
  openWorkDetail,

  /// 已持久化最终稀疏点云 —— 打开点云查看器(成品)。
  openSparseCloud,

  /// 无成品但留有 sfm_live.db(重建被打断)—— 弹"继续重建"确认,
  /// 用户确认后才从 db 断点续跑。绝不自动起后台任务。
  offerResume,

  /// 什么都不做(无成品、无可恢复数据;原底部 SnackBar 提示已按用户
  /// 要求删除)。
  none,
}

/// 任务卡点击决策。优先级(高→低):
///   1. 活跃重建同卡 → 回原等待页(必须最先判,哪怕磁盘上已有部分产物)。
///   2. GLB 成品 → 作品详情。
///   3. sfm_sparse.ply → 点云查看器。
///   4. sfm_live.db 且当前没有别的重建在跑 → 提供断点续跑。
///   5. 其余 → none。
///
/// [activeReconstructionCaptureDir] 非空表示有一个重建正在进行(等待页
/// route 活着);此时对**其他**卡不提供续跑入口 —— 两个原生 SfM 会话并发
/// 会把内存/热推过真机上限。
DraftCardAction draftCardActionFor({
  required String? recordCaptureDir,
  required bool hasArtifact,
  required bool sparsePlyExists,
  required bool sfmDbExists,
  required String? activeReconstructionCaptureDir,
  required bool hasActiveReconstructionCallback,
}) {
  final record = _normalizeDir(recordCaptureDir);
  final active = _normalizeDir(activeReconstructionCaptureDir);
  if (record != null &&
      active != null &&
      record == active &&
      hasActiveReconstructionCallback) {
    return DraftCardAction.reopenActiveReconstruction;
  }
  if (hasArtifact) return DraftCardAction.openWorkDetail;
  if (sparsePlyExists) return DraftCardAction.openSparseCloud;
  if (sfmDbExists && active == null) return DraftCardAction.offerResume;
  return DraftCardAction.none;
}

/// 目录路径归一:去尾部斜杠,空串视为 null。防止"同一目录、字符串不等"
/// 导致重入守卫静默失败。
String? _normalizeDir(String? dir) {
  if (dir == null) return null;
  var d = dir.trim();
  while (d.length > 1 && d.endsWith('/')) {
    d = d.substring(0, d.length - 1);
  }
  return d.isEmpty ? null : d;
}
