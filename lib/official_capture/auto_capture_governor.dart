// auto_capture_governor.dart — 自动采集的决策谓词(纯函数,零 Flutter 依赖)。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何量由 auto_capture_geometry.dart 算好后传进来;编排在
// auto_capture_controller.dart。本文件不持有任何状态。
//
// 生产入口只有 [autoCaptureDecideMotion]：距离、固定 0.28×深度和“位移 OR
// 转角”旧判据已经删除，避免迁移完成后被误接回去。

import 'live_sfm_publish_policy.dart' show kOfficialMaximumCaptureFrames;
import '../official_quality/frame_quality_constants.dart';
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 单次自动采集的时间上限(秒)。依据两条独立吻合:Scaniverse 官方
/// 每次扫描硬上限 5 分钟；它与照片间隔是独立的热天花板。
const double kAutoCaptureTimeLimitSec = 300.0;

// ─── stella_vslam 常数(逐字,stella-cv/stella_vslam)─────────────────────
// 出处: src/stella_vslam/module/keyframe_inserter.{h,cc}
// 许可: BSD 2-Clause —— LICENSE.original(Copyright (c) 2019, National
//       Institute of Advanced Industrial Science and Technology (AIST))+
//       LICENSE.fork(Copyright (c) 2022, stella-cv)。允许逐字复刻。
//
//   keyframe_inserter(max_interval = 1.0, min_interval = 0.1,
//                     max_distance = -1.0, min_distance = -1.0,
//                     lms_ratio_thr_almost_all_lms_are_tracked = 0.9,
//                     lms_ratio_thr_view_changed = 0.8,
//                     enough_lms_thr = 100, ...)
//   constexpr unsigned int num_enough_keyfrms_thr = 5;
//   constexpr unsigned int num_tracked_lms_thr_unstable = 15;
//
// ⚠️ 上游的 YAML 构造把 lms_ratio_thr_view_changed 默认写成 0.5,与 C++ 构造
// 函数默认 0.8 不一致(上游自身的分歧,不是我们改的)。取 C++ 默认 0.8。
const double kStellaMaxIntervalSec = 1.0;
const double kStellaMinIntervalSec = 0.1;
const double kStellaMaxDistanceM = -1.0; // 上游默认:关闭
const double kStellaMinDistanceM = -1.0; // 上游默认:关闭
const double kStellaLmsRatioThrAlmostAllLmsAreTracked = 0.9;
const double kStellaLmsRatioThrViewChanged = 0.8;
const int kStellaEnoughLmsThr = 100;
const int kStellaNumEnoughKeyfrmsThr = 5;
const int kStellaNumTrackedLmsThrUnstable = 15;

// ─── min_distance 的取值:SVO 的关键帧间距判据 ───────────────────────────
// stella_vslam 把 min_distance 留给集成方(默认 -1 = 关闭),因为 SLAM 不在乎
// 照片重叠。我们在乎:每张 12MP 照片要 1.5 s GPU、拍下来删不掉,而且原地转头
// 拍出来的照片没有基线、三角化不出新的 3D 点(未命名(22) 的重叠病)。
//
// 取值出处:Forster、Pizzoli、Scaramuzza,《SVO: Fast Semi-Direct Monocular
// Visual Odometry》,ICRA 2014,Mapping 一节 —— 论文正文规定:新帧相对所有
// 关键帧的欧氏距离超过**平均场景深度的 12%** 时才选为关键帧。PTAM(Klein &
// Murray,ISMAR 2007)用同构判据:到最近关键帧的距离除以场景深度均值再比阈值。
// 两者都用"平移 ÷ 场景深度",因此离物体近要走得少、离得远要走得多。
//
// ⚠️ 许可:SVO 与 PTAM 的**实现**都是 GPL。这里只采用论文发表的规则与常数,
// 代码为独立编写,未复制任何上游源码文本(见 MEMORY 的 License 红线)。
// ⚠️ 与 SVO 的差异(写明):SVO 在相机坐标系下按 x/y/z 三轴分别比(y×0.8、
// z×1.3);stella 的 min_distance 是一个标量米数,所以这里只取它的各向同性
// 核心 0.12,不引入 SVO 的三轴权重 —— 不把两家的结构混在一起。
const double kSvoKeyframeMinDistanceSceneDepthRatio = 0.12;

/// stella_vslam 的 `min_distance`(米),按 SVO 的式子由场景深度给出。
/// 没有活体点云深度时返回上游默认 -1(即这道门关闭),不猜一个绝对米数。
double autoCaptureMinDistanceMetres(double? sceneDepthMetres) {
  if (sceneDepthMetres == null ||
      !sceneDepthMetres.isFinite ||
      sceneDepthMetres <= 0) {
    return kStellaMinDistanceM;
  }
  return kSvoKeyframeMinDistanceSceneDepthRatio * sceneDepthMetres;
}

enum AutoCaptureDecision {
  fire,
  skipNotMoved,
  skipPaced,

  /// A spatial candidate arrived on a pose-only tick. Auto capture waits for
  /// the next cross-platform grayscale sample instead of guessing from VIO.
  skipNoVisualEvidence,

  /// The current 16×16 grayscale signature is too similar to the last photo
  /// that actually entered the shutter queue (Aether3D threshold: 0.92).
  skipRedundant,

  /// 运动已够格开火，但当前画面未通过 Aether3D 的原版帧级清晰度硬门。
  ///
  /// 判据逐字复用 [FrameQualityConstants.blurThresholdLaplacian] (=200)：
  /// 128×128 灰度缩略图由平台桥搬运，Laplacian variance 在 Dart 统一计算。
  /// AliceVision 的段内相对锐度只用于候选排序，不能当作客观模糊硬门；
  /// Apple Object Capture 的 movingTooFast 同样会暂停自动拍摄而非超时放行。
  skipBlurry,
  skipTracking,
  skipCapped,
  skipTimeLimit,

  /// 环境过暗,自动拍停止选帧(拍都不拍,所以没有快门声、没有销毁)。
  /// 复刻 Apple ObjectCaptureSession 的文档口径(API docs,逐字):
  ///   .environmentTooDark:  "…too dark to proceed. Auto-capture will stop…"
  ///   .environmentLowLight: "…Auto-capture still proceeds but reconstruction
  ///                          quality may suffer."
  /// 两级:lowLight 不设闸(照拍,质量理由只记遥测);tooDark 才停在这里。
  skipTooDark,

  /// 上一枪已入队但照片还没真正拍成(快门事务 0.27–0.74 s):下一张的基准
  /// 与流量起点都要用**实拍瞬间**,基准未知就不判定。这不是时间地板,是
  /// "没有基准就没有决策"。(2026-09-06 未命名(15) 定罪:请求时刻的基准在
  /// 快扫时过期 ⇒ 背靠背两张同一画面。)
  skipAwaitingCapture,

  /// 建图模块暂停/请求暂停(上游 `mapper_->is_paused() || pause_is_requested()`)。
  /// 我们:快门队列不接受(重建收尾/暂停)。
  skipMapperStopped,

  /// 建图模块正在跳过 local BA,也就是后端已经追不上(上游
  /// `mapper_is_skipping_localBA`)。我们:SfM 工作线程还有帧排队/在途。
  /// 未命名(22) 队列堆到 16 的根治就在这一条。
  skipMapperBusy,

  /// 相对上一张照片的行进距离没到 `min_distance`(上游 `min_distance_traveled`)。
  /// 上游默认 -1 = 关闭,我们照抄默认 ⇒ 这一条默认不会出现。
  skipMinDistance,
}

/// 正常档只保留防重复触发的 250 ms 去抖，不把秒数冒充摄影测量参数。
/// RealityScan 与 Polycam 的公开口径都是“按检测到的运动拍”；Meshroom 的
/// 视频关键帧窗口也按帧数而非固定秒数表达。是否值得拍由几何/重叠决定，
/// 真实吞吐上限继续交给现役 ShutterPace 背压。
const double kAutoCaptureNormalIntervalSec = 0.25;

/// 所有角色共同守住的 250 ms 防连击地板。队列压力与热态只记遥测，
/// 不得改变这个值；否则是用后台吞吐能力代替摄影测量取帧判定。
const double kAutoCaptureSafetyDebounceSec = 0.25;

/// tooDark 档的亮度下界。不是新造的数:与质量策略的 minMeanLuma
/// (photo_bundle_quality_service.dart,60.0)和 TargetPoints 的亮度带
/// (60–200)同一常数 —— 预览均亮低于它,连质量策略自己都会判
/// mean_luma_dark,拍了也是废片,不如不选。
const double kAutoCaptureTooDarkMeanLuma = 60.0;

/// thermal 桶(ProcessInfo 四档:0 nominal · 1 fair · 2 serious · 3 critical;
/// **<0 = 未知,按冷处理** —— 与 `shutterPaceNext` 的降级口径逐字相同)。
/// 阈值 2 与既有的 `kPaceSoftQueueHot`(那里的"热"也是 `thermalState >= 2`)
/// 同源,不新造分界。
const int kAutoCaptureThermalSerious = 2;
const int kAutoCaptureThermalCritical = 3;

/// stella_vslam `module::keyframe_inserter::new_keyframe_is_needed()` 的逐条
/// 复刻(2026-09-07,用户令"整本抄一家、不自研")。
///
/// 上游返回式(BSD-2,可逐字):
///   return (max_interval_elapsed || max_distance_traveled || view_changed
///           || not_enough_lms)
///          && (!enough_keyfrms || (min_interval_elapsed && min_distance_traveled))
///          && !tracking_is_unstable
///          && !almost_all_lms_are_tracked
///          && !mapper_is_skipping_localBA;
///
/// 为什么这条式子正好是我们要的:强制项 `!almost_all_lms_are_tracked` 判的是
/// **画面内容有没有变**(还跟着参考帧 90% 以上的路标就不拍),而不是相机动没
/// 动。站着不动、原地转头、在一个区域里上下左右平移——只要看到的还是同一批
/// 东西,一律不拍(用户 2026-09-07:"没有新特征的移动也不算")。
///
/// 量的对应(唯一的换算,写明):
///  * `num_tracked_lms` / `num_reliable_lms` → 自上一张照片起仍在跟踪的 2D 轨迹
///    数(ContinuousFeatureTracks.commonTrackCount)。我们没有"被 N 个关键帧
///    观测过"的可靠性分层,两者取同一个量;
///  * `num_reliable_lms_ref` → 上一张照片上播种的轨迹数(seedTrackCount);
///  * `map_db->get_num_keyframes()` → 本场已拍张数;
///  * `last_inserted_keyfrm->timestamp_` → 上一张照片的时刻;
///  * `‖last_kf.get_trans_wc() − curr_frm.get_trans_wc()‖` → 相机世界位移(纯
///    平移,旋转不计入),米;
///  * `mapper_->is_paused() || pause_is_requested()` → 快门队列不接受;
///  * `mapper_->is_skipping_localBA()` → SfM 工作线程还有帧排队/在途。
///
/// ⚠️ 密度错配,写明不缩放:`enough_lms_thr = 100` 是按上游 ORB 特征密度(每帧
/// 上千)定的;我们的 128×128 预览上限 150 条轨迹
/// (kVinsFrontEndMaxFeatureCount)。于是:播种 ≥125 时 view_changed(0.8)先
/// 命中、not_enough_lms 不改变行为;播种 <125 时 not_enough_lms 反而先命中,
/// 播种 <100 时它恒真 ⇒ 触发子句恒成立,实际把关的只剩强制子句
/// (almost_all 0.9 + min_distance + mapper 空闲)。常数照抄,不缩放;
/// 这一段是提醒读者:低纹理场景下本规则会退化成"只看强制子句"。
///
/// 产品闸(张数上限、时限、ARKit 跟踪、Apple 过暗、等实拍基准、糊片)不属上游,
/// 原位保留在前后。
AutoCaptureDecision stellaVslamNewKeyframeIsNeeded({
  // ── 产品闸(不属上游)──
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required bool tooDark,
  required bool awaitingCaptureBaseline,
  required bool blurry,
  required bool initialized,
  // ── 上游输入 ──
  required bool mapperAccepting,
  required bool mapperSkippingLocalBA,
  required bool hasTrackEvidence,
  required int numTrackedLms,
  required int numReliableLms,
  required int numReliableLmsRef,
  required double? sinceLastKeyframeSec,
  required double? distanceTraveledM,
  double maxIntervalSec = kStellaMaxIntervalSec,
  double minIntervalSec = kStellaMinIntervalSec,
  double maxDistanceM = kStellaMaxDistanceM,
  double minDistanceM = kStellaMinDistanceM,
}) {
  if (capturedCount >= kOfficialMaximumCaptureFrames) {
    return AutoCaptureDecision.skipCapped;
  }
  if (elapsedSec >= kAutoCaptureTimeLimitSec) {
    return AutoCaptureDecision.skipTimeLimit;
  }
  if (!trackingNormal) return AutoCaptureDecision.skipTracking;
  if (tooDark) return AutoCaptureDecision.skipTooDark;
  if (awaitingCaptureBaseline) return AutoCaptureDecision.skipAwaitingCapture;
  // 上游第一条:建图模块停了就一张也不插。
  if (!mapperAccepting) return AutoCaptureDecision.skipMapperStopped;
  // 还没有第一张照片(上游 last_inserted_keyfrm == nullptr)⇒ 交给起跑锚。
  if (!initialized) return AutoCaptureDecision.skipNotMoved;
  if (!hasTrackEvidence) return AutoCaptureDecision.skipNoVisualEvidence;

  final bool enoughKeyfrms = capturedCount > kStellaNumEnoughKeyfrmsThr;

  bool maxIntervalElapsed = false;
  if (maxIntervalSec > 0.0) {
    maxIntervalElapsed =
        sinceLastKeyframeSec != null && sinceLastKeyframeSec >= maxIntervalSec;
  }
  bool minIntervalElapsed = true;
  if (minIntervalSec > 0.0) {
    minIntervalElapsed =
        sinceLastKeyframeSec == null || sinceLastKeyframeSec >= minIntervalSec;
  }
  bool maxDistanceTraveled = false;
  if (maxDistanceM > 0.0) {
    maxDistanceTraveled =
        distanceTraveledM != null && distanceTraveledM > maxDistanceM;
  }
  bool minDistanceTraveled = true;
  if (minDistanceM > 0.0) {
    minDistanceTraveled =
        distanceTraveledM == null || distanceTraveledM > minDistanceM;
  }
  bool viewChanged = false;
  if (kStellaLmsRatioThrViewChanged > 0.0) {
    viewChanged =
        numReliableLms < numReliableLmsRef * kStellaLmsRatioThrViewChanged;
  }
  final bool notEnoughLms = numReliableLms < kStellaEnoughLmsThr;

  final bool trackingIsUnstable =
      numTrackedLms < kStellaNumTrackedLmsThrUnstable;
  bool almostAllLmsAreTracked = false;
  if (kStellaLmsRatioThrAlmostAllLmsAreTracked > 0.0) {
    almostAllLmsAreTracked =
        numReliableLms >
        numReliableLmsRef * kStellaLmsRatioThrAlmostAllLmsAreTracked;
  }

  // 按上游 return 式的合取顺序给出**具体**的阻挡理由;整体等价于
  //「上游为 true ⟺ 这里 fire」。
  if (trackingIsUnstable) return AutoCaptureDecision.skipTracking;
  // 「画面里还是同一批东西」⇒ 不拍。用户 2026-09-07 要的那一条就是它。
  if (almostAllLmsAreTracked) return AutoCaptureDecision.skipRedundant;
  if (mapperSkippingLocalBA) return AutoCaptureDecision.skipMapperBusy;
  if (!(maxIntervalElapsed ||
      maxDistanceTraveled ||
      viewChanged ||
      notEnoughLms)) {
    return AutoCaptureDecision.skipNotMoved;
  }
  if (enoughKeyfrms) {
    if (!minIntervalElapsed) return AutoCaptureDecision.skipPaced;
    if (!minDistanceTraveled) return AutoCaptureDecision.skipMinDistance;
  }
  if (blurry) return AutoCaptureDecision.skipBlurry;
  return AutoCaptureDecision.fire;
}

/// 自动拍两次开火之间只保留 250 ms 防连击地板。
///
/// [pace] 和 [thermalState] 刻意保留在函数签名中，以免破坏现有遥测接线；
/// 但它们只描述后台队列/设备状态，不是画面是否有新几何信息的证据。
/// 同行关键帧选择用共视、真实特征匹配、视差和清晰度；队列深度不参与。
double autoCaptureTickIntervalSec({
  required ShutterPace pace,
  required int thermalState,
}) {
  return kAutoCaptureSafetyDebounceSec;
}
