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

  /// 灰字 —— 张数够了,但这次拍摄没留下可续跑的重建数据(sfm_live.db 不在)。
  blockedNoResumableData,
}

/// 「开始训练」的闸。优先级(高→低):
///   1. 张数不足 → 补拍(用户签决:这一条最优先,它是唯一用户能自己解决的)。
///   2. 另有重建在跑 → 等待。
///   3. 无可续跑数据 → 无解。
///   4. 其余 → 可点。
///
/// [photoCount] 是**磁盘上实际的照片数**,不是保存时的快照 —— 见
/// me_page 的 _countCapturePhotos。用快照会在用户删过照片后偏大,偏大
/// 意味着这道闸会放行一个其实不足 20 张的项目。
TrainGate trainGateFor({
  required int photoCount,
  required bool hasResumableData,
  required bool anotherReconstructionActive,
}) {
  if (!officialCaptureCanFinish(acceptedFrameCount: photoCount)) {
    return TrainGate.blockedNeedMorePhotos;
  }
  if (anotherReconstructionActive) {
    return TrainGate.blockedAnotherReconstruction;
  }
  if (!hasResumableData) return TrainGate.blockedNoResumableData;
  return TrainGate.ready;
}

/// 还差几张才够开始训练;够了返回 0。
int photosStillNeededToTrain(int photoCount) {
  final remaining = kOfficialMinimumCaptureFrames - photoCount;
  return remaining > 0 ? remaining : 0;
}
