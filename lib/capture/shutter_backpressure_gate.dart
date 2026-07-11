// shutter_backpressure_gate.dart — ③ 快门背压闸(纯 Dart 状态机)。
//
// 背景(45 号相机冻结案):DSP 修复后单帧匹配变重(910→1676ms),SfM 队列
// 堆到 11-12 深(+700MB),thermal serious 下 GPU 持续满载 ~2min → Metal 丢
// command buffer → 相机预览与提取/匹配共用 GPU 同源停摆。旧快门门控只看
// `_capturing`(单张在途),对 queue/thermal 完全无感 —— 用户可以在设备
// 已经烧红、队列已经积压时继续以最快手速加压。
//
// 本闸只做**配速**,数据侧无损:任何已拍的照片都会被处理;它只是在系统
// 已经积压/过热时温和拉长快门的最小间隔,极端积压时暂时置灰快门。
//
//   soft(节奏放慢):队列深度 ≥ [kPaceSoftQueue],或 thermal=serious 且
//         队列 ≥ [kPaceSoftQueueHot] → 快门最小间隔拉长到
//         [kPaceSoftMinIntervalMs](4s;正常时无最小间隔,快门只受单张
//         在途约束)。横幅克制提示"放慢节奏"。
//   hard(硬闸):队列 ≥ [kPaceHardQueue] → 快门置灰 + "处理中"提示,
//         队列回落(滞回,≤ [kPaceHardExitQueue])自动恢复。
//
// 滞回:队列深度按 worker 消化速度(~1-2s/帧)缓慢变化,enter/exit 阈值
// 分离防止在阈值附近来回闪烁。零 Flutter 依赖 ——
// tool/shutter_backpressure_check.dart 用纯 Dart VM 断言状态迁移与间隔判定。

/// 快门配速档位。
enum ShutterPace { normal, soft, hard }

/// soft 档进入阈:队列深度 ≥ 6(任意热态)。
const int kPaceSoftQueue = 6;

/// soft 档进入阈(热):thermal ≥ serious(2)时队列 ≥ 4 即进入。
const int kPaceSoftQueueHot = 4;

/// soft 档退出阈(滞回):队列 ≤ 4(冷)/ ≤ 2(热)才回 normal。
const int kPaceSoftExitQueue = 4;
const int kPaceSoftExitQueueHot = 2;

/// hard 档进入阈:队列深度 ≥ 10(45 号实测 11-12 深即出事)。
const int kPaceHardQueue = 10;

/// hard 档退出阈(滞回):队列 ≤ 8 才降回 soft/normal 评估。
const int kPaceHardExitQueue = 8;

/// soft 档下快门最小间隔(ms)。normal 档无最小间隔(保持现状:只受
/// `_capturing` 单张在途约束,实测 ~1-2s/张)。
const int kPaceSoftMinIntervalMs = 4000;

/// 状态迁移(纯函数):由上一档位 + 当前队列深度 + thermal 桶(0..3,
/// <0 = 未知按冷处理)得出新档位。
ShutterPace shutterPaceNext({
  required ShutterPace previous,
  required int queueDepth,
  required int thermalState,
}) {
  final hot = thermalState >= 2;
  // hard:进入即置灰;退出走滞回(≤ kPaceHardExitQueue),退出后落到
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
    final stillSoft = queueDepth > kPaceSoftExitQueue ||
        (hot && queueDepth > kPaceSoftExitQueueHot);
    if (stillSoft) return ShutterPace.soft;
  }
  return ShutterPace.normal;
}

/// 快门点按判定(纯函数):在 [pace] 档位下,距上一次接受的快门
/// [sinceLastShutterMs] 毫秒的这次点按应否放行。hard 档一律拒
/// (UI 同时置灰,这里兜异步竞态);soft 档按最小间隔;normal 放行。
bool shutterTapAllowed({
  required ShutterPace pace,
  required int sinceLastShutterMs,
}) {
  switch (pace) {
    case ShutterPace.hard:
      return false;
    case ShutterPace.soft:
      return sinceLastShutterMs >= kPaceSoftMinIntervalMs;
    case ShutterPace.normal:
      return true;
  }
}
