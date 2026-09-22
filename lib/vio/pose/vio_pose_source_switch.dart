// vio_pose_source_switch.dart —— 生产位姿源的**唯一**选择器。
//
// ══ 铁律先写在最上面 ═══════════════════════════════════════════════════════
// 「没全面持平/超越 ARKit 之前绝不上生产」。本文件存在的目的**不是**换源,
// 是把「契约与管线」接通,让换源这件事将来变成改一个值,而不是改一片代码。
// 因此:
//
//   · 默认值是**空字符串** ⇒ [PwVioPoseSource.arkit] ⇒ 与接线前逐位相同;
//   · 唯一能让它变成 xrslam 的途径是显式传 `--dart-define`(或测试里的
//     [PwVioPoseSourceSwitch.debugOverride]);
//   · 任何**无法识别**的值一律回落到 arkit,并在 debug 下打一行 ——
//     打错字绝不能悄悄把生产用户切到研究臂上。
//
// ══ 🔴 一个必须说清的事实:iOS 上 `--dart-define` 根本到不了 ═══════════════
// `lib/main.dart:183-192` 的注释(2026-08-09 真机实证)写着:
// 「`--dart-define` 不到这个工程的 iOS xcconfig 链」,所以后端地址才被改成
// 运行期解析。同一条结论对本开关成立 ——
// **出货 iOS 包里这个常量永远是默认值**,也就是永远 ARKit。
// 这不是缺陷,对「默认关闭」这条要求反而是**更强**的保证;但它也意味着:
// 想在真机上跑 ON 这条臂,`--dart-define` 是不够的,必须另配一条运行期开关
// (与 `EndpointConfigResolver` 同款)。那条路**本次没做**,见报告「缺什么」。
//
// ══ 抄的是仓里已有的形状,不是新发明 ═══════════════════════════════════════
// `lib/vio/diagnostics/vio_shadow_switch.dart`(`PW_VIO_SHADOW`)、
// `lib/vio/render/ar_minimal_loop_page.dart:493`(`PW_CAM_TD_MS`)、
// `lib/capture/capture_format.dart:10`(`PW_VIDEO_FORMAT`)是同一种写法。

import 'package:flutter/foundation.dart' show debugPrint;

/// 生产采集页实际使用的位姿源。
enum PwVioPoseSource {
  /// 平台 VIO(iOS = ARKit)。**唯一的生产值。**
  arkit,

  /// 自研臂:XRSLAM 活体会话(`PwXrslamLive` + `XrslamSession`)。
  /// 研究/台架用。选中它**不代表**它已经达标。
  xrslam,
}

/// `--dart-define=PW_VIO_POSE_SOURCE=xrslam` 打开自研臂。默认空 = ARKit。
const String kPwVioPoseSourceRaw = String.fromEnvironment(
  'PW_VIO_POSE_SOURCE',
  defaultValue: '',
);

abstract final class PwVioPoseSourceSwitch {
  /// 仅供测试/台架使用的运行期覆盖。生产代码**不要**写它。
  /// `null` = 不覆盖,按编译期常量走。
  static PwVioPoseSource? debugOverride;

  /// 当前生效的位姿源。
  static PwVioPoseSource get current => debugOverride ?? _fromRaw(kPwVioPoseSourceRaw);

  /// 是否走自研臂。生产出货包恒为 false。
  static bool get isSelfVio => current == PwVioPoseSource.xrslam;

  /// 把 `--dart-define` 的字符串翻成枚举。
  ///
  /// 🔴 **不认识的值回落到 arkit,不抛异常**:这个值来自构建命令行,
  /// 一个打错的字母不该让 app 起不来,更不该被当成「用户要求换源」。
  static PwVioPoseSource _fromRaw(String raw) {
    switch (raw.trim().toLowerCase()) {
      case '':
      case 'arkit':
      case 'platform':
        return PwVioPoseSource.arkit;
      case 'xrslam':
      case 'selfvio':
        return PwVioPoseSource.xrslam;
      default:
        assert(() {
          debugPrint(
            '[PwVioPoseSourceSwitch] 无法识别的 PW_VIO_POSE_SOURCE="$raw",'
            '已回落到 arkit',
          );
          return true;
        }());
        return PwVioPoseSource.arkit;
    }
  }

  /// 给测试用的直接解析入口(不读编译期常量)。
  static PwVioPoseSource parse(String raw) => _fromRaw(raw);

  /// `CapturedFrameSample.poseSource` / manifest 里用的标签。
  /// 🔴 `'arkit'` 这个字面量是**既有**取值,不能改 —— `capture_session.dart`
  /// 的闸、落盘的 manifest、以及 `test/` 里的断言都认它。
  static String labelOf(PwVioPoseSource source) {
    switch (source) {
      case PwVioPoseSource.arkit:
        return 'arkit';
      case PwVioPoseSource.xrslam:
        return 'xrslam';
    }
  }
}
