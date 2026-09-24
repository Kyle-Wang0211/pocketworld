// 把生成的 slam 配置钉在上游 `configs/iphone_slam.yaml` @4beb1a9 上。
//
// ══ 🔴 这个测试是拿一次真机无界发散换来的 ═══════════════════════════════
// 2026-09-20:生成的 slam 配置只写了 9 个键,其余靠引擎的**代码默认值**兜底。
// 我当时的假设是"没写 = 用上游的值"。**那是错的** —— 上游的 yaml 值与引擎的
// 代码默认值在好几处并不相同,漏写等于悄悄换了参数档:
//
//   rotation.misalignment_threshold   上游 0.02  vs 代码默认 0.1   (5×)
//   initializer.min_triangulation     上游 20    vs 代码默认 50
//
// 前者是 RD-VIO 的招牌闸(`map/frame.cpp:120-143`):用纯旋转模型拟合内点,
// 取残差角 70 分位,小于阈值就给该帧打 `FT_NO_TRANSLATION`。阈值放大 5 倍
// ⇒ 大量有平移的帧被判成"没平移" ⇒ 视觉不再约束平移 ⇒ 平移只剩 IMU 二次积分。
// 真机后果:位姿 45 秒跑到 1.6 km。
//
// ⇒ 判据不能是"我写的那几个键对不对",必须是"**上游写了的键,我一个都不能漏**"。
//
// 🔴 上游那份 yaml 不在本仓(它在 xrslam 上游树里),所以下表是**抄录**。
//    任何一行改动都必须回上游文件核对,不能凭印象改。
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/ffi/xrslam_config.dart';

/// 上游 `configs/iphone_slam.yaml` @4beb1a9 逐行抄录(去掉引擎不读的
/// `backend:` 段 —— `yaml_config.cpp` 里 "backend" 出现 0 次)。
const Map<String, String> kUpstreamIphoneSlam = <String, String>{
  'output.q_bo': '[ 0.0, 0.0, 0.0, 1.0 ]',
  'output.p_bo': '[ 0.0, 0.0, 0.0 ]',
  'sliding_window.size': '10',
  'sliding_window.subframe_size': '3',
  'sliding_window.force_keyframe_landmarks': '35',
  'feature_tracker.min_keypoint_distance': '25.0',
  'feature_tracker.max_keypoint_detection': '200',
  'feature_tracker.max_init_frames': '60',
  'feature_tracker.max_frames': '20',
  'feature_tracker.predict_keypoints': 'true',
  'feature_tracker.clahe_clip_limit': '6.0',
  'feature_tracker.clahe_width': '8',
  'feature_tracker.clahe_height': '8',
  'initializer.keyframe_num': '8',
  'initializer.keyframe_gap': '5',
  'initializer.min_matches': '50',
  'initializer.min_parallax': '10.0',
  'initializer.min_triangulation': '20',
  'initializer.min_landmarks': '30',
  'initializer.refine_imu': 'true',
  'solver.iteration_limit': '30',
  'solver.time_limit': '1.0e6',
  'rotation.misalignment_threshold': '0.02',
  'rotation.ransac_threshold': '10',
  'parsac.parsac_flag': 'false',
  'parsac.dynamic_probability': '0.15',
  'parsac.threshold': '1.0',
  'parsac.norm_scale': '1.0',
  'parsac.keyframe_check_size': '1',
};

/// **唯一允许偏离的键**,每一条都必须有实测依据(写在 value 里,进测试输出)。
/// 加第三条之前先拿数据。
const Map<String, String> kAllowedDeviations = <String, String>{
  'solver.iteration_limit':
      '端上预算 10 次 vs 上游离线档 30:首位姿 16.3s→3.5s,EuRoC 三档精度代价均值 +3.2%',
  'solver.time_limit':
      '端上预算 0.1s vs 上游离线档 1.0e6s:同上一条',
};

/// 极简 YAML 取值:只处理"两层缩进 + `key: value`",够覆盖这两份配置。
/// 不引 yaml 包 —— 这里要断言的是**文本里有没有那一行**,不是语义等价。
Map<String, String> flatten(String yaml) {
  final Map<String, String> out = <String, String>{};
  String section = '';
  for (final String raw in yaml.split('\n')) {
    final String line = raw.split('#').first.trimRight();
    if (line.trim().isEmpty) continue;
    if (!line.startsWith(' ')) {
      final int c = line.indexOf(':');
      if (c > 0) section = line.substring(0, c).trim();
      continue;
    }
    final int c = line.indexOf(':');
    if (c < 0) continue;
    final String k = line.substring(0, c).trim();
    final String v = line.substring(c + 1).trim();
    if (v.isEmpty) continue;
    out['$section.$k'] = v;
  }
  return out;
}

/// `10` / `10.0` / `1.0e6` 视作同一个数;其余按字符串比。
bool sameValue(String a, String b) {
  final double? x = double.tryParse(a);
  final double? y = double.tryParse(b);
  if (x != null && y != null) return x == y;
  return a.replaceAll(' ', '') == b.replaceAll(' ', '');
}

void main() {
  final String yaml = const XrslamConfigBuilder(
    intrinsics: CameraIntrinsics(
      fx: 1500,
      fy: 1500,
      cx: 960,
      cy: 720,
      resolutionWidth: 1920,
      resolutionHeight: 1440,
      provenance: FieldProvenance.deviceApi,
    ),
  ).buildSlamConfigYaml();
  final Map<String, String> got = flatten(yaml);

  test('上游写了的键,一个都不能漏', () {
    final List<String> missing = <String>[
      for (final String k in kUpstreamIphoneSlam.keys)
        if (!got.containsKey(k)) k,
    ];
    expect(
      missing,
      isEmpty,
      reason: '漏写的键会落到**引擎的代码默认值**,而那与上游 yaml 值并不相同。\n'
          'rotation.misalignment_threshold 漏写一次 = 真机位姿 45 秒跑到 1.6 km。',
    );
  });

  test('没有记录依据的偏离一律不许存在', () {
    final List<String> unjustified = <String>[];
    kUpstreamIphoneSlam.forEach((String k, String want) {
      final String? have = got[k];
      if (have == null) return; // 上一条测试管这个
      if (sameValue(have, want)) return;
      if (kAllowedDeviations.containsKey(k)) return;
      unjustified.add('$k: 上游=$want 我们=$have');
    });
    expect(unjustified, isEmpty,
        reason: '要么改回上游值,要么把依据加进 kAllowedDeviations。');
  });

  test('已记录的偏离确实还在偏离(否则该把它从白名单里删掉)', () {
    for (final String k in kAllowedDeviations.keys) {
      expect(kUpstreamIphoneSlam.containsKey(k), isTrue,
          reason: '$k 不在上游那份里,它不算"偏离"');
      expect(sameValue(got[k]!, kUpstreamIphoneSlam[k]!), isFalse,
          reason: '$k 已经和上游一致了,白名单条目是陈的:${kAllowedDeviations[k]}');
    }
  });

  test('图像明文外发的开关必须显式关死,不能靠默认值', () {
    expect(got['visual_localization.enable'], 'false');
  });
}
