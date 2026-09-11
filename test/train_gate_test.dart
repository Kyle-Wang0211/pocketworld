// 作品页「开始训练」闸的穷举断言。
//
// [2026-09-07] 这道闸补的是一条已经在真机上发生过的漏:20 张的判定此前只挂在
// 拍摄页「结束任务」按钮上,而"未完成"卡片按定义就是没走那条出口的,于是不足
// 20 张的项目在作品页照样能开始重建。

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/me/train_gate.dart';
import 'package:pocketworld_flutter/official_capture/live_sfm_publish_policy.dart';

void main() {
  test('张数闸与拍摄页同源,20 是唯一阈值', () {
    expect(kOfficialMinimumCaptureFrames, 20);
    // 19 关、20 开 —— 边界和拍摄页 officialCaptureCanFinish 逐值一致。
    for (var n = 0; n < 20; n++) {
      expect(
        trainGateFor(
          photoCount: n,
          hasResumableData: true,
          canRebuildFromPhotos: false,
          anotherReconstructionActive: false,
        ),
        TrainGate.blockedNeedMorePhotos,
        reason: '$n 张不该放行',
      );
    }
    expect(
      trainGateFor(
        photoCount: 20,
        hasResumableData: true,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: false,
      ),
      TrainGate.ready,
    );
    expect(
      trainGateFor(
        photoCount: 300,
        hasResumableData: true,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: false,
      ),
      TrainGate.ready,
    );
  });

  test('张数不足优先于其它一切原因 —— 它是唯一用户能自己解决的', () {
    // 三个条件全坏时仍然报"去补拍",因为补拍是用户下一步唯一能做的动作。
    expect(
      trainGateFor(
        photoCount: 3,
        hasResumableData: false,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: true,
      ),
      TrainGate.blockedNeedMorePhotos,
    );
  });

  test('张数够了之后,两个 blocked 各自可达且互不吞没', () {
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: true,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: true,
      ),
      TrainGate.blockedAnotherReconstruction,
    );
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: false,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: false,
      ),
      TrainGate.blockedNoResumableData,
      reason: 'db 坏了 + 一张照片都没有 = 真的无解',
    );
    // 🔴 [2026-09-08] db 坏了但照片还在 ⇒ **可点**,走"从照片重建"。
    // 这一条是真机逼出来的:被杀的 db 只剩 4096 字节残骸,而照片和每张的
    // ARKit 位姿完好(Mac 台架同一批照片 12/12 注册、14151 点)。
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: false,
        canRebuildFromPhotos: true,
        anotherReconstructionActive: false,
      ),
      TrainGate.ready,
    );
    // 有别的重建在跑时 hasResumableData 恒为 false(me_page 根本不去解析),
    // 这一组必须报"等待"而不是"无解" —— 否则用户会以为数据丢了。
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: false,
        canRebuildFromPhotos: false,
        anotherReconstructionActive: true,
      ),
      TrainGate.blockedAnotherReconstruction,
    );
  });

  test('路由:db 可用就续跑,不可用就重喂存档照片', () {
    expect(
      trainRouteFor(hasResumableData: true, dbCoversAllPhotos: true),
      TrainRoute.resumeFromDb,
    );
    expect(
      trainRouteFor(hasResumableData: false, dbCoversAllPhotos: true),
      TrainRoute.rebuildFromArchivedPhotos,
    );
    // 两条路必须是两个值 —— 合并成一条就等于"db 坏了也去续跑",那正是
    // 09-08 那个 errDb 红弹窗的成因。
    expect(TrainRoute.values.length, 2);
  });

  test('照片够但 db 坏时,闸放行 + 路由指向重喂 —— 两者必须一致', () {
    const photoCount = 25;
    final gate = trainGateFor(
      photoCount: photoCount,
      hasResumableData: false,
      canRebuildFromPhotos: true,
      anotherReconstructionActive: false,
    );
    expect(gate, TrainGate.ready);
    expect(
      trainRouteFor(hasResumableData: false, dbCoversAllPhotos: true),
      TrainRoute.rebuildFromArchivedPhotos,
      reason: '闸放行却把用户送去续跑,就是把红弹窗换了个地方出',
    );
  });

  test('🔴db 打得开但只装了一部分照片 ⇒ 也必须走全量重喂', () {
    // 真机未命名(8):补拍之后 db 头完全自洽(3032 页对 3032 页),
    // 第一条判据一路放行,但里面只有 6 张而盘上有 26 张。只问"打不开吗"
    // 会交付一朵缺 20 张素材的云,而且它每次都"成功"。
    expect(
      trainRouteFor(hasResumableData: true, dbCoversAllPhotos: false),
      TrainRoute.rebuildFromArchivedPhotos,
    );
    // 阴性对照:两条都满足才续跑 —— 否则这条断言用"永远重喂"也能通过。
    expect(
      trainRouteFor(hasResumableData: true, dbCoversAllPhotos: true),
      TrainRoute.resumeFromDb,
    );
  });

  test('还差几张:够了是 0,不足是差额', () {
    expect(photosStillNeededToTrain(0), 20);
    expect(photosStillNeededToTrain(19), 1);
    expect(photosStillNeededToTrain(20), 0);
    expect(photosStillNeededToTrain(999), 0);
  });

  test('每个 blocked 都有独立枚举值 —— 不允许合并成一个笼统的 blocked', () {
    expect(TrainGate.values.length, 4);
    expect(TrainGate.values.toSet().length, 4);
  });
}
