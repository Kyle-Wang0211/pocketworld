// xrchain_pose_convention.dart —— 台架 XRSLAM → SfM 重建链:XRSLAM 相机位姿 → 产品喂核 ABI 的位姿口径。
// 纯 Dart,无平台依赖,四端同一份。只进台架(pocketworld bench/xr-recon-chain,镜像进 arloopbench)。
//
// ══ 为什么要换口径 ══════════════════════════════════════════════════════════════
// 产品喂核入口(SfmLiveRecon.offerFrame → pwofficial_add_jpeg_frame_v2)吃的是 ARKit 口径的
// camera-to-world(列主序 4×4,cameraTransform):**ARKit 相机轴**(x 右、y 上、z 朝后),**y 朝上的重力世界**;
// 它内部再取逆成 CamFromWorld,核里的重力对齐式 R_w = R_arkᵀ·C·R_col 自带 C = diag(1,−1,−1)
// (sfm_live_recon.dart「07-28 勘误」段)。XRSLAM 的相机位姿是 **OpenCV 相机轴**(x 右、y 下、z 朝前)、
// **z 朝上的重力世界**(重力 (0,0,−g))。
//
// ══ 换法:照抄,不自研 ═══════════════════════════════════════════════════════════
// 逐式照抄 09-23 的 prep_inputs.py(研究仓 data/vio-session-archive-20260923 …/sfmB/tools/prep_inputs.py),
// 离线 SfM agent 09-25 的 make_feeds.py `xr_to_ark` 用的是同一式,并已拿出货核跑过:
//   R_wc_ark = M · R_wc_cv · F,  C' = M · C,  F = diag(1,−1,−1),  M = Rx90ᵀ(Rx90 = [[1,0,0],[0,0,−1],[0,1,0]])
// 四元数 → 旋转矩阵同 prep_inputs.py q2R(先归一化)。输出按 vector_math Matrix4.fromList 的列主序排
// (生产 offerFrame 就用它读 cameraTransform)。

import 'dart:math' as math;

/// XRSLAM 相机位姿(world_from_camera):四元数 [x, y, z, w] + 相机中心 [x, y, z](XRSLAM world)。
/// 返回产品 ABI 的 cameraTransform(ARKit 口径 camera-to-world,列主序 16 个数)。
List<double> xrslamCameraPoseToArkitCameraTransform(List<double> qXyzw, List<double> center) {
  assert(qXyzw.length == 4 && center.length == 3);
  final List<List<double>> r = _q2R(qXyzw[3], qXyzw[0], qXyzw[1], qXyzw[2]);
  // M = Rx90ᵀ = [[1,0,0],[0,0,1],[0,-1,0]];F = diag(1,-1,-1)。
  const List<List<double>> m = <List<double>>[
    <double>[1, 0, 0],
    <double>[0, 0, 1],
    <double>[0, -1, 0],
  ];
  const List<double> f = <double>[1, -1, -1];
  final List<List<double>> mr = _mul(m, r);
  final List<List<double>> ark = <List<double>>[
    for (int i = 0; i < 3; i++) <double>[for (int j = 0; j < 3; j++) mr[i][j] * f[j]],
  ];
  final List<double> c = <double>[
    for (int i = 0; i < 3; i++) m[i][0] * center[0] + m[i][1] * center[1] + m[i][2] * center[2],
  ];
  return <double>[
    ark[0][0], ark[1][0], ark[2][0], 0,
    ark[0][1], ark[1][1], ark[2][1], 0,
    ark[0][2], ark[1][2], ark[2][2], 0,
    c[0], c[1], c[2], 1,
  ];
}

/// prep_inputs.py q2R 原样(先归一化)。
List<List<double>> _q2R(double w, double x, double y, double z) {
  final double n = math.sqrt(w * w + x * x + y * y + z * z);
  w /= n;
  x /= n;
  y /= n;
  z /= n;
  return <List<double>>[
    <double>[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
    <double>[2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
    <double>[2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
  ];
}

List<List<double>> _mul(List<List<double>> a, List<List<double>> b) => <List<double>>[
      for (int i = 0; i < 3; i++)
        <double>[for (int j = 0; j < 3; j++) a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j]],
    ];

/// 链路核心的不可信原因位(PwXrReconChainCore.h PW_XRCHAIN_UNTRUSTED_*)→ 名字。
const Map<int, String> kXrChainUntrustedReasonNames = <int, String>{
  1: 'timeout',
  2: 'extrapolation_too_long',
  4: 'not_tracking_at_photo',
  8: 'no_state_at_photo',
  16: 'propagate_failed',
  32: 'no_backend_frame',
  64: 'not_in_close_window',
};

/// 位姿来源(PW_XRCHAIN_SOURCE_*)→ 名字。
const Map<int, String> kXrChainSourceNames = <int, String>{
  0: 'pending',
  1: 'final',
  2: 'window_at_close',
  3: 'timeout',
  4: 'no_backend_frame',
};

List<String> xrChainReasonNames(int bits) => <String>[
      for (final MapEntry<int, String> e in kXrChainUntrustedReasonNames.entries)
        if (bits & e.key != 0) e.value,
    ];

/// 链路的可信判决 → 产品 DevicePoseTrust 的跨端词表(device_pose_trust.dart):
/// 可信 ⇒ "normal";不可信 ⇒ "limited_xrchain_<原因…>"(词表里「非 normal 一律不可信」)。
String xrChainTrackerStateName({required bool trusted, required int reasonBits}) {
  if (trusted) return 'normal';
  final List<String> names = xrChainReasonNames(reasonBits);
  return 'limited_xrchain_${names.isEmpty ? 'untrusted' : names.join('+')}';
}
