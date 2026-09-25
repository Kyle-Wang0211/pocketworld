// xrchain_pose_convention_test.dart —— [xr-recon-chain 2026-09-25] XRSLAM 相机位姿 → 产品 ABI cameraTransform。
// 期望值不是本文件自己算的:用离线 SfM agent 09-25 的 make_feeds.py 自己的 q2R / xr_to_ark(= prep_inputs.py 的式子,
// 已拿出货核跑过)在 numpy 下算出、原样抄进来(命令见 bench/arloopbench_own_snapshot 的 VERIFY 记录)。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/bench_xrchain/xrchain_pose_convention.dart';

void main() {
  const List<(List<double>, List<double>, List<double>)> cases = <(List<double>, List<double>, List<double>)>[
    (
      <double>[0.1, -0.2, 0.3, 0.9],
      <double>[0.5, -1.25, 2.0],
      <double>[0.7263157894736842, 0.4421052631578947, -0.5263157894736842, 0.0, 0.6105263157894737,
        -0.06315789473684214, 0.7894736842105263, 0.0, 0.31578947368421056, -0.8947368421052632,
        -0.3157894736842105, 0.0, 0.5, 2.0, 1.25, 1.0],
    ),
    (
      // 本测试机 dev yaml 的相机→body 外参旋转(q_cb)+ 平移,当作一个位姿:接近 90° 的轴置换
      <double>[-0.7071068, 0.7071068, 0.0, 0.0],
      <double>[0.03290364, -0.00696553, -0.00286231],
      <double>[-2.220446049250313e-16, 0.0, 1.0000000000000002, 0.0, 1.0000000000000002, 0.0,
        -2.220446049250313e-16, 0.0, 0.0, 1.0000000000000004, 0.0, 0.0, 0.03290364, -0.00286231, 0.00696553, 1.0],
    ),
    (
      <double>[0.2, 0.4, -0.1, -0.8],
      <double>[-3.0, 0.25, 1.5],
      <double>[0.6, 0.7058823529411764, -0.3764705882352941, 0.0, 0.0, 0.47058823529411764, 0.8823529411764706,
        0.0, 0.8, -0.5294117647058824, 0.2823529411764706, 0.0, -3.0, 1.5, -0.25, 1.0],
    ),
  ];

  test('与 make_feeds.py xr_to_ark(prep_inputs.py 同式)逐元素一致(1e-12)', () {
    for (final (List<double> q, List<double> c, List<double> want) in cases) {
      final List<double> got = xrslamCameraPoseToArkitCameraTransform(q, c);
      expect(got.length, 16);
      for (int i = 0; i < 16; i++) {
        expect(got[i], closeTo(want[i], 1e-12), reason: 'q=$q c=$c 第 $i 个');
      }
    }
  });

  test('可信 ⇒ normal;不可信 ⇒ limited_xrchain_<原因>(词表里非 normal 一律不可信)', () {
    expect(xrChainTrackerStateName(trusted: true, reasonBits: 0), 'normal');
    expect(xrChainTrackerStateName(trusted: false, reasonBits: 1), 'limited_xrchain_timeout');
    expect(xrChainTrackerStateName(trusted: false, reasonBits: 2 | 4),
        'limited_xrchain_extrapolation_too_long+not_tracking_at_photo');
    expect(xrChainTrackerStateName(trusted: false, reasonBits: 16 | 32),
        'limited_xrchain_propagate_failed+no_backend_frame');
  });
}
