// thermal_tier.dart — 跨端统一的热档位(纯 Dart,无 Flutter 依赖)。
//
// 设计依据(一手证据,不是推测):
//   ARCore 工程师 inio 在 google-ar/arcore-android-sdk issue #604 里写道
//   "our visual-inertial-odometry only updates around 10 times per second and
//    the live pose is forward-integrated based on the IMU readings",
//   并且 "We've experimented with running 60FPS but it introduces problems
//    with increased device heating"。
//   ⇒ ARKit/ARCore 的低发热不是靠专用硬件,是靠**把视觉更新降到 ~10Hz、
//     中间用 IMU 前向积分补足**。所以 10Hz 在这里是**上限**,不是"满血档",
//     我们不是从 30Hz 往下降级,而是从一开始就按 10Hz 设计。
//
// 两端各写一套档位映射会造出"结构性不同的算法"(XRSLAM_IOS 宏的教训),
// 所以档位判定**只在 Dart 这一份**做,平台侧只上报原始信号。

/// 跨端统一档位。取 iOS 的四级(较粗的那一端)作为公共分母,
/// Android 的七级向下折叠 —— 折叠方向永远是"就高不就低"。
enum ThermalTier {
  /// 无节流。
  nominal,

  /// 轻度:系统已经开始压,但性能影响不显著。
  fair,

  /// 严重:性能已被明显压制(Android SEVERE / iOS serious)。
  serious,

  /// 危急:Apple 官方建议 "Consider stopping use of camera and other
  /// peripherals";Android 已进入 CRITICAL 及以上。
  critical,
}

/// 档位序(用于取 max / 比较),0..3。
int thermalTierRank(ThermalTier t) => t.index;

ThermalTier thermalTierFromRank(int rank) {
  final clamped = rank < 0 ? 0 : (rank > 3 ? 3 : rank);
  return ThermalTier.values[clamped];
}

/// 取两档中更热的一档。
ThermalTier hotterTier(ThermalTier a, ThermalTier b) =>
    a.index >= b.index ? a : b;

// ---------------------------------------------------------------------------
// 平台原始值 → 统一档位
// ---------------------------------------------------------------------------

/// iOS:`NSProcessInfoThermalState`(Foundation/NSProcessInfo.h,iOS 11.0+)
///   0 = Nominal, 1 = Fair, 2 = Serious, 3 = Critical。
/// 未知/不支持时 Apple 文档明确返回 Nominal,所以越界一律按 nominal。
ThermalTier tierFromIosThermalState(int raw) {
  if (raw < 0 || raw > 3) return ThermalTier.nominal;
  return ThermalTier.values[raw];
}

/// Android:`PowerManager.THERMAL_STATUS_*`(NDK `AThermalStatus` 同值)
///   -1 ERROR, 0 NONE, 1 LIGHT, 2 MODERATE, 3 SEVERE,
///    4 CRITICAL, 5 EMERGENCY, 6 SHUTDOWN。
/// 折叠口径:LIGHT/MODERATE 官方描述都是 "no significant impact on
/// performance" ⇒ fair;SEVERE 是官方定义的"显著影响性能"起点,也正是
/// getThermalHeadroom==1.0 对应的阈 ⇒ serious;CRITICAL 及以上 ⇒ critical。
/// ERROR(-1) 不可当成 NONE —— 那是"读不到",按 nominal 但调用方应记 unknown。
ThermalTier tierFromAndroidThermalStatus(int raw) {
  if (raw <= 0) return ThermalTier.nominal; // ERROR(-1) 与 NONE(0)
  if (raw <= 2) return ThermalTier.fair; // LIGHT, MODERATE
  if (raw == 3) return ThermalTier.serious; // SEVERE
  return ThermalTier.critical; // CRITICAL, EMERGENCY, SHUTDOWN
}

// ---------------------------------------------------------------------------
// thermal headroom(仅 Android,API 30+)
// ---------------------------------------------------------------------------

/// ADPF 官方启发式:>0.85 可能已在轻度节流,应开始降频。
const double kHeadroomWarn = 0.85;

/// ADPF 官方启发式:>0.95 可能已在中度节流,应立即降载。
/// (headroom 1.0 == THERMAL_STATUS_SEVERE 阈,所以 >0.95 折成 serious 自洽。)
const double kHeadroomShed = 0.95;

/// headroom 只能**向上抬**档位,永远不能把 status 报出来的热档往下压。
/// headroom 为 null(iOS 无此 API / Android <30 / 返回 NaN)时原样返回。
ThermalTier escalateWithHeadroom(ThermalTier base, double? headroom) {
  if (headroom == null || headroom.isNaN) return base;
  if (headroom > kHeadroomShed) return hotterTier(base, ThermalTier.serious);
  if (headroom > kHeadroomWarn) return hotterTier(base, ThermalTier.fair);
  return base;
}

// ---------------------------------------------------------------------------
// 每档的视觉更新率
// ---------------------------------------------------------------------------

/// nominal 档的视觉更新率 = 10Hz,直接对齐 ARCore 自述的设计点。
const double kVisualHzNominal = 10.0;
const double kVisualHzFair = 7.5;
const double kVisualHzSerious = 5.0;
const double kVisualHzCritical = 3.0;

/// 初始化(bootstrap)期的视觉更新率。
/// ⚠️ 这一档是**工程策略,不是实测结论** —— VIO 未完成初始化前需要更密的视觉
/// 观测才能把尺度/零偏收敛出来。仅在 nominal/fair 生效;serious 及以上不抬。
const double kBootstrapVisualHz = 15.0;

double visualHzForTier(ThermalTier tier) {
  switch (tier) {
    case ThermalTier.nominal:
      return kVisualHzNominal;
    case ThermalTier.fair:
      return kVisualHzFair;
    case ThermalTier.serious:
      return kVisualHzSerious;
    case ThermalTier.critical:
      return kVisualHzCritical;
  }
}

/// 结合 bootstrap 状态得到目标视觉更新率。
double visualHzFor({required ThermalTier tier, required bool initialized}) {
  final base = visualHzForTier(tier);
  if (initialized) return base;
  if (tier == ThermalTier.serious || tier == ThermalTier.critical) return base;
  return kBootstrapVisualHz;
}
