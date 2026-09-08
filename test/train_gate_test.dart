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
        anotherReconstructionActive: false,
      ),
      TrainGate.ready,
    );
    expect(
      trainGateFor(
        photoCount: 300,
        hasResumableData: true,
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
        anotherReconstructionActive: true,
      ),
      TrainGate.blockedAnotherReconstruction,
    );
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: false,
        anotherReconstructionActive: false,
      ),
      TrainGate.blockedNoResumableData,
    );
    // 有别的重建在跑时 hasResumableData 恒为 false(me_page 根本不去解析),
    // 这一组必须报"等待"而不是"无解" —— 否则用户会以为数据丢了。
    expect(
      trainGateFor(
        photoCount: 25,
        hasResumableData: false,
        anotherReconstructionActive: true,
      ),
      TrainGate.blockedAnotherReconstruction,
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
