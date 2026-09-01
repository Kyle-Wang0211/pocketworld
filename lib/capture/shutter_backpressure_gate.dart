// shutter_backpressure_gate.dart — 队列/热态拥塞的**遥测分级器**(纯 Dart)。
//
// ⚠️ 07-12 签决(快门彻底与后台解耦)后,本文件不再对快门做任何阻挡。
// 快门彻底不限流:无论多热、队列多深,快门永远立即可拍(队列不丢帧靠
// sfm_live_recon 的磁盘 spool 队列保证,不靠回压快门)。曾经的 soft 4s
// 配速 + hard 置灰(45 号冻结案③)已全部撤除——热保护改由 native 热调速器
// (K12→K6,只降后台 GPU 负载,不碰快门)透明承担。
//
// 保留下来的只有 [shutterPaceNext]:把「队列深度 + thermal 桶」压成一个
// 三级拥塞标签(normal/elevated/high),**纯观测用**——UI 记一行
// `shutter_pace` 遥测便于事后画积压曲线,绝不 gate 快门、不置灰、不弹
// 「请稍候」横幅。滞回只是为了让遥测标签别在阈值附近抖动刷屏。
// tool/shutter_backpressure_check.dart 用纯 Dart VM 断言分级迁移。

/// 拥塞遥测分级(**非快门档位**;不再驱动任何阻挡逻辑):
///   normal   = 队列浅、不热;
///   soft     = 中度拥塞(队列 ≥6,或热机队列 ≥4)——历史名保留,只作标签;
///   hard     = 高度拥塞(队列 ≥10)——历史名保留,只作标签。
enum ShutterPace { normal, soft, hard }

/// soft(中度拥塞)进入阈:队列深度 ≥ 6(任意热态)。
const int kPaceSoftQueue = 6;

/// soft(中度拥塞)进入阈(热):thermal ≥ serious(2)时队列 ≥ 4 即进入。
const int kPaceSoftQueueHot = 4;

/// soft 退出阈(滞回):队列 ≤ 4(冷)/ ≤ 2(热)才回 normal。
const int kPaceSoftExitQueue = 4;
const int kPaceSoftExitQueueHot = 2;

/// hard(高度拥塞)进入阈:队列深度 ≥ 10。
const int kPaceHardQueue = 10;

/// hard 退出阈(滞回):队列 ≤ 8 才降回 soft/normal 评估。
const int kPaceHardExitQueue = 8;

/// 拥塞分级迁移(纯函数):由上一档 + 当前队列深度 + thermal 桶(0..3,
/// <0 = 未知按冷处理)得出新标签。滞回防止遥测标签在阈值附近抖动。
/// **纯观测**:调用方只把它写进遥测,不用它阻挡快门。
ShutterPace shutterPaceNext({
  required ShutterPace previous,
  required int queueDepth,
  required int thermalState,
}) {
  final hot = thermalState >= 2;
  // hard:进入即标高拥塞;退出走滞回(≤ kPaceHardExitQueue),退出后落到
  // soft/normal 的常规评估(队列 8 深通常仍是 soft)。
  if (queueDepth >= kPaceHardQueue) return ShutterPace.hard;
  if (previous == ShutterPace.hard && queueDepth > kPaceHardExitQueue) {
    return ShutterPace.hard;
  }
  final softEnter =
      queueDepth >= kPaceSoftQueue || (hot && queueDepth >= kPaceSoftQueueHot);
  if (softEnter) return ShutterPace.soft;
  if (previous != ShutterPace.normal) {
    // 已在 soft(或刚从 hard 回落):滞回退出。
    final stillSoft =
        queueDepth > kPaceSoftExitQueue ||
        (hot && queueDepth > kPaceSoftExitQueueHot);
    if (stillSoft) return ShutterPace.soft;
  }
  return ShutterPace.normal;
}
