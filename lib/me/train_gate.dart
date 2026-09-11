// train_gate.dart — 作品页「开始训练」的闸(纯函数)。
//
// 从 me_page.dart 的 _showRecordActions 提纯出来,理由和 draft_card_action.dart
// 完全一样:判定本身就是产品契约,必须能被纯 Dart VM 穷举断言,不依赖 widget
// 树、不依赖真机、不依赖磁盘。
//
// [2026-09-07 用户签决] 起因是一次实机指认:「未命名(24)」是"未完成"状态、
// 照片不足 20 张,却照样能点「继续重建」。查下来 20 张的判定**全 app 只有
// 一处** —— 拍摄页「结束任务」按钮上的 officialCaptureCanFinish。而"未完成"
// 卡片按定义就是没走那条出口的(闪退/被杀/中途退出 → 孤儿恢复捡回来,恢复
// 门槛只有 photos.isEmpty,1 张也会变成一张卡)。异常路径绕过唯一的闸、作品页
// 又不复查,于是不足 20 张的项目可以正常开始重建。
//
// 阈值**不在本文件定义**:直接调用拍摄页那同一个 officialCaptureCanFinish。
// 常数只有 kOfficialMinimumCaptureFrames 一处,两个入口同源 —— 将来改 20
// 不会漏掉其中一边。复制一份阈值过来就是在制造第二个真相。

import '../official_capture/live_sfm_publish_policy.dart';

/// 「开始训练」这一栏此刻的状态。
///
/// 三个 blocked 分开而不是合并成一个 `blocked`:置灰时必须说清是哪一个,
/// 因为用户下一步该做什么完全取决于原因(补拍 / 等待 / 无解)。一个点不动
/// 又不解释的按钮就是静默出口,这条在本项目上复发过太多次。
enum TrainGate {
  /// 黑字可点 —— 够 20 张,且真的有东西可跑。
  ready,

  /// 灰字 —— 张数不足。点击提示还差几张,让用户去补拍。
  blockedNeedMorePhotos,

  /// 灰字 —— 另一个项目正在重建。两个原生 SfM 会话并发会把内存/热推过
  /// 真机上限(与 draft_card_action 的续跑门同一规矩)。
  blockedAnotherReconstruction,

  /// 灰字 —— 张数够了,但这次拍摄既没有可用的 db,也没有能重喂的存档照片。
  blockedNoResumableData,
}

/// 「开始训练」点下去之后走哪条路。
///
/// [2026-09-08] 这条分叉是被实机数据逼出来的:拍摄被杀时 db 只落了一个
/// 4096 字节的残骸(头声称 3025 页、文件只有 1 页 ⇒ sqlite 报 malformed),
/// 续跑那条路必然 errDb。但照片和每张的 ARKit 位姿都完好,重新喂一遍能救回来
/// (Mac 台架实测同一批照片 12/12 注册、14151 点)。
/// 所以 db 坏掉不再等于"无解",而是**换一条路**。
enum TrainRoute {
  /// db 可用 —— 直接照 db 续跑(不需要照片,最快)。
  resumeFromDb,

  /// db 已不可用 —— 把 photos_highres 里的存档照片重新喂一遍。
  rebuildFromArchivedPhotos,
}

/// 「开始训练」的闸。优先级(高→低):
///   1. 张数不足 → 补拍(用户签决:这一条最优先,它是唯一用户能自己解决的)。
///   2. 另有重建在跑 → 等待。
///   3. 无可续跑数据 → 无解。
///   4. 其余 → 可点。
///
/// [hasResumableData] = **db 可用**(存在 且 打得开,见 sqlite_db_health.dart);
/// [canRebuildFromPhotos] = 盘上还有存档照片,可以重新喂一遍。
///
/// [photoCount] 是**磁盘上实际的照片数**,不是保存时的快照 —— 见
/// me_page 的 _countCapturePhotos。用快照会在用户删过照片后偏大,偏大
/// 意味着这道闸会放行一个其实不足 20 张的项目。
TrainGate trainGateFor({
  required int photoCount,
  required bool hasResumableData,
  required bool canRebuildFromPhotos,
  required bool anotherReconstructionActive,
}) {
  if (!officialCaptureCanFinish(acceptedFrameCount: photoCount)) {
    return TrainGate.blockedNeedMorePhotos;
  }
  if (anotherReconstructionActive) {
    return TrainGate.blockedAnotherReconstruction;
  }
  // db 坏了不再是死路:存档照片还在就能重喂。两条都没有才是真的无解。
  if (!hasResumableData && !canRebuildFromPhotos) {
    return TrainGate.blockedNoResumableData;
  }
  return TrainGate.ready;
}

/// 闸放行之后走哪条路。
///
/// 单独一个函数而不是塞进 [TrainGate]:闸回答"能不能点",路回答"点了干什么",
/// 混在一起会让"db 坏但能重建"这种状态在枚举里无处安放。
///
/// 两个条件**都**满足才续跑:
///  · [hasResumableData] —— db 打得开(sqlite_db_health.dart 的结构性判据);
///  · [dbCoversAllPhotos] —— db 里装的就是盘上全部照片
///    (archived_photo_rebuild.dart 的 projectCoverageFrom)。
///
/// [2026-09-11] 第二条是被真机逼出来的。未命名(8):补拍之后 db **头完全自洽**
/// (3032 页对 3032 页,第一条判据一路放行),但里面只有 6 张,而盘上有 26 张。
/// 只问"打不开吗"会把这种项目送去续跑,交付一朵缺了 20 张素材的云 ——
/// 而且一次比一次更像"本来就该这样",因为它每次都成功。
TrainRoute trainRouteFor({
  required bool hasResumableData,
  required bool dbCoversAllPhotos,
}) =>
    (hasResumableData && dbCoversAllPhotos)
    ? TrainRoute.resumeFromDb
    : TrainRoute.rebuildFromArchivedPhotos;

/// 还差几张才够开始训练;够了返回 0。
int photosStillNeededToTrain(int photoCount) {
  final remaining = kOfficialMinimumCaptureFrames - photoCount;
  return remaining > 0 ? remaining : 0;
}
