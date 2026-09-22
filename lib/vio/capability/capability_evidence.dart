// capability_evidence.dart — 运行期自证的**输入事实**(Blocker 04)。
// 纯 Dart,零 Flutter 依赖(与 lib/vio/quality/ 下的既有文件同口径)。
//
// ── 为什么存在 ──────────────────────────────────────────────────────────
// XRSLAM 的设计前提是逐机型 yaml:上游 18 个逐机型 iPhone yaml、Android 侧 0 个,
// 而且 `iPhone 16e.yaml` 与 `iPhone 14 Pro.yaml` **逐字节相同**(占位拷贝,从未标定)。
// 商汤自家 xrapi 的 SLAM 只支持 4 台安卓机;它的 default 与 huawei/p40 之间
// time_offset 0.0278s vs 0.00642s、readout 1.55×、内参差 14%、p_bc 差 12mm。
// ARCore 团队原话:标定 "often change for each model number of a phone",而且
// "we can't do the above on just one device. We need to calibrate across many
// units of a device, taking an average"。
//
// 我们的硬需求是**绝不逐机型实测**。所以不猜机型 —— 会话开始时把设备**当场量一遍**,
// 量不出来就降级。本文件定义「量到了什么」,不做任何判定;判定在 capability_probe.dart。
//
// ── 三层内参来源(层级即可信度)────────────────────────────────────────
//   1. [IntrinsicsSource.perFrameAttachment]  —— 每帧随图像下发的真内参。
//      iOS: AVCaptureConnection.cameraIntrinsicMatrixDeliveryEnabled ⇒
//           kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix (CFData, matrix_float3x3)。
//      Android: 无对应物(Android 的内参是静态 characteristic,不随帧下发)。
//   2. [IntrinsicsSource.platformTracker] —— 平台跟踪器自报。
//      iOS: ARCamera.intrinsics (simd_float3x3) + ARCamera.imageResolution (CGSize)。
//   3. [IntrinsicsSource.staticCharacteristics] —— 静态标定表。
//      Android: CameraCharacteristics.LENS_INTRINSIC_CALIBRATION = [f_x,f_y,c_x,c_y,s],
//      单位是 SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE 坐标系的像素。
//      🔴 AOSP 原文:「Optional - The value for this key may be null on some devices.」
//   4. [IntrinsicsSource.fieldOfViewFallback] —— 只有视场角,反推 f。最后一档。
//      iOS: AVCaptureDevice.activeFormat.videoFieldOfView(float,**水平**视场角,度;
//      「If field of view is unknown, a value of 0 is returned.」)。
//      ⚠️ 这一档拿不到主点,只能假设在画面正中 —— 是**假设**不是测量,所以它单独成档。
//   5. [IntrinsicsSource.none] —— 什么都没有。
//
// ── 🔴 Apple 亲口说的两条硬约束(iPhoneOS26.2.sdk 头文件原文)────────────
// AVCaptureSession.h(cameraIntrinsicMatrixDeliverySupported):
//   「Note that if video stabilization is enabled (preferredVideoStabilizationMode is
//    set to something other than AVCaptureVideoStabilizationModeOff), camera intrinsic
//    matrix delivery is not supported.」
// AVCaptureDevice.h:2311:
//   「Note that if you enable video stabilization ..., the pixels in stabilized video
//    frames no longer match the relative extrinsicMatrix from one device to another due
//    to warping. The extrinsicMatrix and camera intrinsics should only be used when
//    video stabilization is disabled.」
// ⇒ 防抖开着的时候,画面像素与 IMU 的物理位姿**不再对应**。这不是我们的推测,
//   是 Apple 自己写在头文件里的。所以 EIS/OIS 检出即致命,且**与用不用自研核无关**
//   (歪掉的像素同样毒化后面的 SfM/MVS)。

import 'dart:math' as math;

// ═══════════════════════════════════════════════════════════════════════
// 时间基
// ═══════════════════════════════════════════════════════════════════════

/// 图像时间戳与 IMU 时间戳的关系。
enum TimebaseRelation {
  /// 同一时钟基,直接可比。
  /// Android: CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE == REALTIME
  ///          (SensorEvent.timestamp 本来就是 BOOTTIME)。该 key「available on all devices」。
  /// iOS:     相机 PTS 与独立原始 accel/gyro 时间戳的关系未由 Apple 保证;
  ///          必须由 Dart 消费三明治时钟实测证据，不能写死为同域。
  unified,

  /// 不同基,但偏移已被当场测出(见 android_ready 的 ClockOffset:Cristian 最小往返法)。
  offsetMeasured,

  /// 不同基且没测出来。图像与 IMU **无法融合**。
  /// Android: SENSOR_INFO_TIMESTAMP_SOURCE == UNKNOWN 且 ClockOffset 探测失败。
  unrelatedUnmeasured,
}

/// 时间基事实。
class TimebaseFacts {
  const TimebaseFacts({required this.relation, this.offsetUncertaintyNs});

  const TimebaseFacts.unified()
    : relation = TimebaseRelation.unified,
      offsetUncertaintyNs = 0;

  final TimebaseRelation relation;

  /// 偏移估计的**硬误差界**(不是标准差):真值一定落在 ±uncertainty 内。
  /// ClockOffset 的定义 = (monoAfter - monoBefore) / 2。
  /// [relation] == offsetMeasured 时必须给出;unified 时为 0;unmeasured 时为 null。
  final int? offsetUncertaintyNs;

  /// 融合前必须知道的总时间不确定度。unmeasured 时为 null(= 不可知,不是 0)。
  int? get effectiveUncertaintyNs {
    switch (relation) {
      case TimebaseRelation.unified:
        return 0;
      case TimebaseRelation.offsetMeasured:
        return offsetUncertaintyNs;
      case TimebaseRelation.unrelatedUnmeasured:
        return null;
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
// 内参
// ═══════════════════════════════════════════════════════════════════════

enum IntrinsicsSource {
  none,
  fieldOfViewFallback,
  staticCharacteristics,
  platformTracker,
  perFrameAttachment,
}

/// 来源的可信度序(越大越可信)。判定里用它,不用字符串比较。
int intrinsicsSourceRank(IntrinsicsSource s) => s.index;

/// 参考坐标系里的裁剪矩形(像素)。zoom / crop / 分辨率切换都归到这一个表达。
class CropRect {
  const CropRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  bool get isPositive => width > 0 && height > 0;
}

/// 针孔内参 + 它所参照的分辨率。
///
/// 🔴 内参**没有分辨率就没有意义**。Apple 用 `intrinsicMatrixReferenceDimensions`
///    显式携带它;Android 的 LENS_INTRINSIC_CALIBRATION 参照的是
///    `SENSOR_INFO_PRE_CORRECTION_ACTIVE_ARRAY_SIZE`。两边都必须原样带过来,
///    否则「拿到内参了」是假的 —— 数值对不上实际出图分辨率。
class IntrinsicsFacts {
  const IntrinsicsFacts({
    required this.source,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.referenceWidth,
    required this.referenceHeight,
    this.skew = 0.0,
  });

  const IntrinsicsFacts.absent()
    : source = IntrinsicsSource.none,
      fx = 0,
      fy = 0,
      cx = 0,
      cy = 0,
      referenceWidth = 0,
      referenceHeight = 0,
      skew = 0;

  /// 从水平视场角反推。**最后一档**:主点只能假设在正中,是假设不是测量。
  ///
  ///     fx = (W / 2) / tan(hfov / 2)
  ///
  /// fy 由**像素方形**假设给出(fy = fx)。这在现代手机上基本成立,但仍是假设,
  /// 所以本构造器打的标签是 [IntrinsicsSource.fieldOfViewFallback]。
  factory IntrinsicsFacts.fromHorizontalFov({
    required double fovDegrees,
    required int width,
    required int height,
  }) {
    final double half = fovDegrees * math.pi / 360.0;
    final double f = (width / 2.0) / math.tan(half);
    return IntrinsicsFacts(
      source: IntrinsicsSource.fieldOfViewFallback,
      fx: f,
      fy: f,
      cx: width / 2.0,
      cy: height / 2.0,
      referenceWidth: width,
      referenceHeight: height,
    );
  }

  final IntrinsicsSource source;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final double skew;
  final int referenceWidth;
  final int referenceHeight;

  bool get isPresent =>
      source != IntrinsicsSource.none &&
      fx > 0 &&
      fy > 0 &&
      referenceWidth > 0 &&
      referenceHeight > 0;

  /// 把内参搬到另一个出图口径。
  ///
  /// [cropInReference] 是参考坐标系里实际被读出的矩形(zoom / 裁切 / ROI),
  /// [outWidth]×[outHeight] 是它被缩放到的输出尺寸。完整变换是
  ///
  ///     sx = outWidth / crop.width      sy = outHeight / crop.height
  ///     fx' = fx * sx                   fy' = fy * sy
  ///     cx' = (cx - crop.x) * sx        cy' = (cy - crop.y) * sy
  ///     s'  = skew * sx
  ///
  /// 平移必须**先减后乘**:主点是参考系里的绝对坐标,裁切改变原点,缩放改变尺度。
  /// 顺序反了会在非中心裁切时错开 crop.x*(sx-1) 个像素 —— 恰好是 zoom 时最常见的错。
  ///
  /// 恒等裁切(crop 覆盖全图且输出尺寸不变)必须是 no-op;两次 remap 必须等于
  /// 一次合成后的 remap。这两条在单测里当不变量校验。
  IntrinsicsFacts remap({
    required CropRect cropInReference,
    required int outWidth,
    required int outHeight,
  }) {
    if (!isPresent ||
        !cropInReference.isPositive ||
        outWidth <= 0 ||
        outHeight <= 0) {
      return const IntrinsicsFacts.absent();
    }
    final double sx = outWidth / cropInReference.width;
    final double sy = outHeight / cropInReference.height;
    return IntrinsicsFacts(
      source: source,
      fx: fx * sx,
      fy: fy * sy,
      cx: (cx - cropInReference.x) * sx,
      cy: (cy - cropInReference.y) * sy,
      skew: skew * sx,
      referenceWidth: outWidth,
      referenceHeight: outHeight,
    );
  }

  /// 主点是否落在画面内。落在画面外 = 参考分辨率带错了(最常见的静默错)。
  bool get principalPointPlausible =>
      cx > 0 && cx < referenceWidth && cy > 0 && cy < referenceHeight;

  /// 水平视场角(度)。用于与 videoFieldOfView 交叉校验 —— 两条独立来源对不上,
  /// 就说明其中一条的参考分辨率错了。
  double get horizontalFovDegrees => fx > 0
      ? 2.0 * math.atan((referenceWidth / 2.0) / fx) * 180.0 / math.pi
      : 0.0;

  @override
  String toString() =>
      'Intrinsics(${source.name}, f=(${fx.toStringAsFixed(1)},'
      '${fy.toStringAsFixed(1)}), c=(${cx.toStringAsFixed(1)},${cy.toStringAsFixed(1)}), '
      'ref=${referenceWidth}x$referenceHeight)';
}

// ═══════════════════════════════════════════════════════════════════════
// 防抖(OIS / EIS)
// ═══════════════════════════════════════════════════════════════════════

enum StabilizationState {
  /// 已确认关闭 —— 读回来的**实际**状态,不是我们请求的状态。
  off,

  /// 已确认开启。
  on,

  /// 查不到 / 平台不提供读回。**不等于 off**。
  unknown,

  /// 该平台上这一路防抖不存在(例如某机型无 OIS 硬件)。等价于 off,但保留区分。
  absent,
}

/// 防抖事实。请求值与**读回值**分开记 —— 请求只是请求。
///
/// iOS:
///   EIS: AVCaptureConnection.preferredVideoStabilizationMode = .off(请求),
///        AVCaptureConnection.activeVideoStabilizationMode(读回,KVO 可观测,
///        「This property never returns AVCaptureVideoStabilizationModeAuto」)。
///   OIS: 🔴 **iOS 26.2 SDK 里不存在任何公开的 OIS 符号**(全 SDK
///        grep -ri "opticalImageStabilization" 命中 0,同一条 grep 对
///        "preferredVideoStabilizationMode" 命中 4 个文件作为阳性对照)。
///        ⇒ iOS 上 OIS **既不可查也不可关**,只能记为 [StabilizationState.unknown]。
/// Android:
///   EIS: CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE = OFF
///        (CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES「OFF will always be listed」,
///         该 characteristic「available on all devices」)⇒ EIS 总是可关。
///   OIS: CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE = OFF,
///        受 LENS_INFO_AVAILABLE_OPTICAL_STABILIZATION 约束
///        (「If OIS is not supported ..., this list will contain only OFF」,
///         Optional / LIMITED 级以上才保证存在)。
///   两者都必须在 **CaptureResult** 里读回确认。
class StabilizationFacts {
  const StabilizationFacts({
    required this.electronic,
    required this.optical,
    this.electronicControllable = false,
    this.opticalControllable = false,
  });

  const StabilizationFacts.allUnknown()
    : electronic = StabilizationState.unknown,
      optical = StabilizationState.unknown,
      electronicControllable = false,
      opticalControllable = false;

  /// EIS / 数字防抖的**实际**状态。
  final StabilizationState electronic;

  /// OIS / 光学防抖的**实际**状态。
  final StabilizationState optical;

  /// 该平台是否给了关掉它的开关。
  final bool electronicControllable;
  final bool opticalControllable;

  bool _isOff(StabilizationState s) =>
      s == StabilizationState.off || s == StabilizationState.absent;

  /// 两路都确认关闭。
  bool get allConfirmedOff => _isOff(electronic) && _isOff(optical);

  /// 任一路确认开着 —— 画面已被 warp,像素与 IMU 物理位姿不再对应。
  bool get anyConfirmedOn =>
      electronic == StabilizationState.on || optical == StabilizationState.on;

  /// 有一路状态不可知。不是 off,也不是 on。
  bool get anyUnknown =>
      electronic == StabilizationState.unknown ||
      optical == StabilizationState.unknown;
}

// ═══════════════════════════════════════════════════════════════════════
// 帧时序
// ═══════════════════════════════════════════════════════════════════════

/// 实际帧耗时。热降频、过载都从这里露头(热稳定是硬约束)。
class FrameTimingFacts {
  const FrameTimingFacts({
    required this.frameCount,
    required this.medianIntervalNs,
    required this.p95IntervalNs,
  });

  const FrameTimingFacts.unmeasured()
    : frameCount = 0,
      medianIntervalNs = null,
      p95IntervalNs = null;

  final int frameCount;
  final int? medianIntervalNs;
  final int? p95IntervalNs;

  bool get isMeasured =>
      frameCount >= 2 && medianIntervalNs != null && medianIntervalNs! > 0;

  double? get hz => isMeasured ? 1e9 / medianIntervalNs! : null;

  /// p95/中位 —— 抖动比。1.0 = 完全等间隔。掉帧/热降频会把它顶上去。
  /// 用比值而不是绝对值,才能跨 30fps / 60fps 用同一个阈值。
  double? get intervalRatio => (isMeasured && p95IntervalNs != null)
      ? p95IntervalNs! / medianIntervalNs!
      : null;
}

// ═══════════════════════════════════════════════════════════════════════
// 卷帘
// ═══════════════════════════════════════════════════════════════════════

/// 卷帘读出时间。
/// Android: CaptureResult.SENSOR_ROLLING_SHUTTER_SKEW(纳秒,Optional,LIMITED 级以上)。
///   AOSP 原文:「For typical camera sensors that use rolling shutters, this is also
///   equivalent to the frame readout time.」以及必须按实际读出行数缩放:
///   「if your output covers N rows of the active array of height H, scale this value by N/H」。
/// iOS: **无对应 API**。只能记 [unknown]。
class RollingShutterFacts {
  const RollingShutterFacts({required this.readoutNs});

  const RollingShutterFacts.unknown() : readoutNs = null;

  final int? readoutNs;

  bool get isKnown => readoutNs != null && readoutNs! > 0;
}
