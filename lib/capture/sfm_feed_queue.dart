// sfm_feed_queue.dart — 拍摄期喂帧队列的纯调度谓词(零 Flutter 依赖)。
//
// 背景(07-12 签决:快门彻底与后台解耦)= 三角约束:
//   ① 快门彻底不限流:无论多热、队列多深,快门永远立即可拍;
//   ② 队列不丢帧:每一张拍下的帧最终都进 finalize(一个不少);
//   ③ 不降质:不靠降分辨率/丢帧/降采样消化积压。
//
// 队列架构(实现在 SfmLiveRecon.offerFrame/_pump/_maybeSendFinalize):
//   - worker 最多同时在途 [kSfmFeedMaxInFlight] 个 add_frame;
//   - 满了就把该帧的 gray 平面**溢写到磁盘文件**、只在内存里排一个路径条目
//     (RAM 与队列深度**无关**,这是 ② 不爆内存的关键:队列存路径不存字节);
//   - slot 一空,pump 就按**到达顺序**喂下一个磁盘帧(FIFO,不乱序、不丢);
//   - finalize 延后到队列**彻底排空**(spool 空 + 在途为 0)才下发,
//     所以每一个 offered 帧都先进了重建 → finalize 帧数 == 拍摄帧数。
//
// 快门永不因队列深度/热态被阻挡:背压只作用在**后台消费侧**(worker 何时
// 收下一帧),绝不回压到快门。这些谓词把上面的调度决策抽成纯函数,便于
// host 断言(tool/sfm_feed_queue_check.dart:狂喂 N 帧证明零丢帧、内存
// bounded、finalize==offered、顺序保持)。

import '../capture/capture_format.dart';

/// worker 同时在途 add_frame 的上限。超过即溢写磁盘排队(不阻塞、不丢帧)。
/// 值 2 = 与旧内联实现逐字一致(offerFrame 的 `_inFlight < 2`)。
/// [E24 OOM 修复 2026-07-19] photo43(12MP)降为 1:两路并发 12MP 提取的
/// 金字塔瞬态(~2×300MB)是 2282MB jetsam 死亡曲线的主成分之一;spool
/// 架构保证零丢帧,只是消化排队变慢——稳定性优先(热稳定铁律)。
const int kSfmFeedMaxInFlight = pwPhoto43 ? 1 : 2;

/// 这一帧是否该**溢写磁盘排队**(而非直接送 worker)。
/// true = worker 忙(在途已满)或前面还有排队帧(必须保序,不能插队)。
/// 契约:与 offerFrame 的直送条件 `inFlight < max && spool 空` 严格互补。
bool sfmFeedShouldSpool({required int inFlight, required int spoolDepth}) {
  return inFlight >= kSfmFeedMaxInFlight || spoolDepth > 0;
}

/// pump 现在是否可以把队首的磁盘帧喂给 worker。
/// true = worker 有空位(在途未满)且队列非空。
bool sfmFeedCanPumpNext({required int inFlight, required int spoolDepth}) {
  return inFlight < kSfmFeedMaxInFlight && spoolDepth > 0;
}

/// 是否可以下发延后的 finalize:必须已请求完成、尚未下发、且队列
/// **彻底排空**(spool 空 + 在途为 0)。这是 ②「一个不少」的强制点——
/// 队列没排空绝不 finalize,保证所有 offered 帧都已进重建。
bool sfmFeedCanSendFinalize({
  required bool finalizeRequested,
  required bool finalizeSent,
  required int spoolDepth,
  required int inFlight,
}) {
  return finalizeRequested && !finalizeSent && spoolDepth == 0 && inFlight == 0;
}
